/*
 * iAppVM Guest Keychain inspector.
 *
 * Runs inside the target process, so access-group rewriting and the target's
 * Keychain entitlements are already active. Metadata is written automatically;
 * secret values are only queried when the user explicitly calls dump()/authDump().
 */
(function () {
  'use strict';

  if (!ObjC.available) throw new Error('ObjC bridge is required; select 自动检查 or 补齐 ObjC.');

  const pointerSize = Process.pointerSize;
  const getExport = Module.getGlobalExportByName
    ? Module.getGlobalExportByName.bind(Module)
    : (name) => Module.getExportByName(null, name);
  const secItemCopyMatching = new NativeFunction(
    getExport('SecItemCopyMatching'),
    'int',
    ['pointer', 'pointer']
  );
  let chmod = null;
  try {
    chmod = new NativeFunction(getExport('chmod'), 'int', ['pointer', 'int']);
  } catch (_) {
    // Fall back to NSFileManager below when chmod is not exported globally.
  }
  const constants = {};
  const authenticationBlocks = [];

  function constant(name) {
    if (!constants[name]) {
      const slot = getExport(name);
      constants[name] = new ObjC.Object(slot.readPointer());
    }
    return constants[name];
  }

  function nsString(value) {
    return ObjC.classes.NSString.stringWithString_(String(value));
  }

  function bool(value) {
    return ObjC.classes.NSNumber.numberWithBool_(value);
  }

  function objectValue(value, depth) {
    if (value === null || value === undefined || typeof value === 'string' ||
        typeof value === 'number' || typeof value === 'boolean') return value;
    if (!value || typeof value !== 'object' || typeof value.$className !== 'string') return String(value);
    if ((depth || 0) > 8) return '<depth-limit>';
    const className = value.$className || '';
    if (/Data/.test(className)) {
      try { return value.base64EncodedStringWithOptions_(0).toString(); }
      catch (_) { return '<binary-data>'; }
    }
    if (/Date/.test(className)) {
      try {
        const seconds = value.timeIntervalSince1970();
        return { unix: seconds, iso: new Date(seconds * 1000).toISOString() };
      } catch (_) { return value.toString(); }
    }
    if (/Dictionary/.test(className)) {
      const result = {};
      const keys = value.allKeys();
      for (let index = 0; index < keys.count(); index++) {
        const key = keys.objectAtIndex_(index);
        result[String(key)] = objectValue(value.objectForKey_(key), (depth || 0) + 1);
      }
      return result;
    }
    if (/Array/.test(className)) {
      const result = [];
      for (let index = 0; index < value.count(); index++) {
        result.push(objectValue(value.objectAtIndex_(index), (depth || 0) + 1));
      }
      return result;
    }
    try { return value.toString(); } catch (_) { return String(value); }
  }

  function currentAccessGroup() {
    const processInfo = ObjC.classes.NSProcessInfo.processInfo();
    const environment = processInfo.environment();
    const home = environment.objectForKey_('HOME').toString();
    const info = ObjC.classes.NSDictionary.dictionaryWithContentsOfFile_(home + '/LCContainerInfo.plist');
    if (!info) throw new Error('当前 Guest 缺少 LCContainerInfo.plist。');
    const rawGroup = info.objectForKey_('keychainGroupId');
    const groupId = rawGroup ? rawGroup.intValue() : 0;
    const team = ObjC.classes.LCSharedUtils.teamIdentifier();
    if (!team) throw new Error('无法取得宿主 Team ID。');
    const suffix = Number(groupId) === 0 ? '' : '.' + String(groupId);
    return {
      home: home,
      id: Number(groupId),
      name: String(team) + '.com.kdt.livecontainer.shared' + suffix
    };
  }

  const classes = [
    { title: '通用密码', className: 'kSecClassGenericPassword', secretData: true },
    { title: '互联网密码', className: 'kSecClassInternetPassword', secretData: true },
    { title: '证书', className: 'kSecClassCertificate', secretData: false },
    { title: '密钥', className: 'kSecClassKey', secretData: false },
    { title: '身份', className: 'kSecClassIdentity', secretData: false }
  ];

  function query(itemClass, accessGroup, includeValues, authenticationContext) {
    const dictionary = ObjC.classes.NSMutableDictionary.alloc().init();
    dictionary.setObject_forKey_(constant(itemClass.className), constant('kSecClass'));
    dictionary.setObject_forKey_(nsString(accessGroup), constant('kSecAttrAccessGroup'));
    dictionary.setObject_forKey_(constant('kSecAttrSynchronizableAny'), constant('kSecAttrSynchronizable'));
    dictionary.setObject_forKey_(bool(true), constant('kSecUseDataProtectionKeychain'));
    dictionary.setObject_forKey_(bool(true), constant('kSecReturnAttributes'));
    dictionary.setObject_forKey_(bool(true), constant('kSecReturnPersistentRef'));
    dictionary.setObject_forKey_(constant('kSecMatchLimitAll'), constant('kSecMatchLimit'));
    if (includeValues && itemClass.secretData) {
      dictionary.setObject_forKey_(bool(true), constant('kSecReturnData'));
    }
    if (authenticationContext) {
      dictionary.setObject_forKey_(authenticationContext, constant('kSecUseAuthenticationContext'));
    }

    const resultPointer = Memory.alloc(pointerSize);
    resultPointer.writePointer(ptr(0));
    const status = secItemCopyMatching(dictionary.handle, resultPointer);
    if (status === -25300) return { status: status, items: [] };
    if (status !== 0) return { status: status, items: [] };
    const rawPointer = resultPointer.readPointer();
    if (rawPointer.isNull()) return { status: status, items: [] };
    const value = objectValue(new ObjC.Object(rawPointer), 0);
    const values = Array.isArray(value) ? value : [value];
    return {
      status: status,
      items: values.map((entry) => {
        if (Array.isArray(entry)) return entry;
        if (entry && typeof entry === 'object') {
          const attributes = entry.r_Attributes || entry.attributes || entry;
          const data = entry.r_Data || entry.data;
          const persistent = entry.r_PersistentRef || entry.persistent;
          const output = Object.assign({}, attributes);
          if (data !== undefined) output._valueBase64 = data;
          if (persistent !== undefined) output._persistentRefBase64 = persistent;
          return output;
        }
        return { value: entry };
      }).filter(Boolean)
    };
  }

  function statusMessage(status) {
    return {
      '-25293': '设备锁定或 Keychain 暂不可访问',
      '-25300': '没有条目',
      '-25291': '系统暂时不可用',
      '-25299': '条目已存在',
      '-34018': '缺少 Keychain entitlement',
      '-50': '查询参数不被系统接受'
    }[String(status)] || ('OSStatus ' + status);
  }

  function inspect(includeValues, authenticationContext) {
    const scope = currentAccessGroup();
    const result = {
      version: 1,
      pid: Process.id,
      accessGroup: scope.name,
      group: scope.id,
      includeValues: !!includeValues,
      items: [],
      warnings: []
    };
    for (const itemClass of classes) {
      const response = query(itemClass, scope.name, !!includeValues, authenticationContext);
      if (response.status !== 0) {
        result.warnings.push({ type: itemClass.title, status: response.status, message: statusMessage(response.status) });
        continue;
      }
      for (const attributes of response.items) {
        if (attributes.agrp && String(attributes.agrp) !== scope.name) continue;
        const alias = attributes.alis ? String(attributes.alis) : '';
        if (alias && alias !== scope.home.split('/').pop()) continue;
        result.items.push(Object.assign({ _type: itemClass.title, _class: itemClass.className }, attributes));
      }
    }
    return result;
  }

  function logDirectory() {
    const getenv = new NativeFunction(getExport('getenv'), 'pointer', ['pointer']);
    const pointer = getenv(Memory.allocUtf8String('IAPPVM_PHONE_SCRIPT_LOG_DIR'));
    return pointer.isNull() ? null : pointer.readUtf8String();
  }

  function writeJSON(path, value) {
    const file = new File(path, 'w');
    try {
      file.write(JSON.stringify(value));
    } finally {
      file.close();
    }
    if (chmod) {
      chmod(Memory.allocUtf8String(path), 0x180);
    } else {
      const permissions = ObjC.classes.NSNumber.numberWithInt_(0x180);
      const attributes = ObjC.classes.NSDictionary.dictionaryWithObject_forKey_(
        permissions,
        'NSFilePosixPermissions'
      );
      ObjC.classes.NSFileManager.defaultManager().setAttributes_ofItemAtPath_error_(
        attributes,
        path,
        ptr(0)
      );
    }
  }

  function publishMetadata() {
    const result = inspect(false, null);
    const directory = logDirectory();
    if (directory) writeJSON(directory + '/keychain-index.json', result);
    return result;
  }

  function requestAuthentication(includeValues) {
    const context = ObjC.classes.LAContext.alloc().init();
    const errorPointer = Memory.alloc(pointerSize);
    errorPointer.writePointer(ptr(0));
    if (!context.canEvaluatePolicy_error_(1, errorPointer)) {
      throw new Error('设备所有者认证不可用。');
    }
    const block = new ObjC.Block({
      retType: 'void',
      argTypes: ['bool', 'object'],
      implementation: function (success) {
        if (!success) {
          send({ event: 'keychain-auth-failed' });
          return;
        }
        try {
          const result = inspect(includeValues, context);
          const directory = logDirectory();
          if (directory) {
            writeJSON(
              directory + (includeValues ? '/keychain-values-sensitive.json' : '/keychain-index-auth.json'),
              result
            );
          }
          send({
            event: includeValues ? 'keychain-sensitive-ready' : 'keychain-auth-index-ready',
            items: result.items.length,
            warnings: result.warnings.length
          });
        } catch (error) {
          send({
            event: includeValues ? 'keychain-sensitive-error' : 'keychain-auth-index-error',
            message: String(error)
          });
        }
      }
    });
    authenticationBlocks.push(block);
    context.evaluatePolicy_localizedReason_reply_(
      1,
      includeValues ? '验证身份后读取当前 Guest 的 Keychain' : '验证身份后刷新当前 Guest 的 Keychain 元数据',
      block
    );
    return 'authentication-requested';
  }

  const api = {
    inspect: function () { return inspect(false, null); },
    dump: function (includeValues) {
      const result = inspect(!!includeValues, null);
      const directory = logDirectory();
      if (directory) {
        writeJSON(
          directory + (includeValues ? '/keychain-values-sensitive.json' : '/keychain-index.json'),
          result
        );
      }
      return result;
    },
    authInspect: function () { return requestAuthentication(false); },
    authDump: function () { return requestAuthentication(true); }
  };
  globalThis.iappvmKeychain = api;
  rpc.exports = {
    inspect: api.inspect,
    dump: api.dump,
    authInspect: api.authInspect,
    authDump: api.authDump
  };

  try {
    const index = publishMetadata();
    console.log('[iAppVM Keychain] ready: ' + index.items.length + ' item(s), ' + index.warnings.length + ' warning(s)');
    console.log('[iAppVM Keychain] metadataOnly=iappvmKeychain.inspect(); authenticatedMetadata=iappvmKeychain.authInspect(); dumpValues=iappvmKeychain.dump(true); authenticatedDump=iappvmKeychain.authDump()');
    if (index.warnings.some((warning) => [-25293, -25291, -25292, -128].indexOf(warning.status) >= 0)) {
      console.warn('[iAppVM Keychain] protected metadata is locked; start with an unlocked device or explicitly call authInspect()/authDump().');
    }
  } catch (error) {
    console.error('[iAppVM Keychain] ' + String(error));
  }
})();
