/* Separate phone-agent console channel. No native hooks or target stdout filtering. */
function iappvmInstallPhoneLogger(options) {
  const original = {};
  const originalSend = globalThis.send;
  const originalTimers = {};
  for (const name of ['setTimeout','setInterval','setImmediate']) originalTimers[name] = globalThis[name];
  let logPath = null, statePath = null, commandPath = null, written = 0, failed = false;
  try {
    const address = Module.getGlobalExportByName ? Module.getGlobalExportByName('getenv') : Module.getExportByName(null, 'getenv');
    const getenv = new NativeFunction(address, 'pointer', ['pointer']);
    const pointer = getenv(Memory.allocUtf8String('IAPPVM_PHONE_SCRIPT_LOG_DIR'));
    if (!pointer.isNull()) {
      const directory = pointer.readUtf8String();
      if (directory && /^[-A-Fa-f0-9]{36}$/.test(options.id)) {
        logPath = directory + '/' + options.id + '.jsonl';
        statePath = directory + '/' + options.id + '.state.json';
        commandPath = directory + '/' + options.id + '.command.json';
      }
    }
  } catch (_) { /* Host metadata records whether separate capture was enabled. */ }
  function state(value) {
    if (!statePath) return;
    try {
      const file = new File(statePath, 'w');
      try { file.write(JSON.stringify({source:'phone',id:options.id,name:options.name,pid:Process.id,state:value,time:Date.now()/1000})); }
      finally { file.close(); }
    } catch (_) { /* A state receipt must not stop the target script. */ }
  }
  let emitted = 0;
  function emit(message) {
    if (!logPath) return;
    try {
      let encoded = JSON.stringify(message);
      const recordLimit=Math.max(512,Math.min(65536,Math.floor(options.limit/16)));
      if (encoded.length > recordLimit) encoded = JSON.stringify({type:'log',level:'warning',payload:encoded.slice(0,recordLimit),truncated:true});
      const line = JSON.stringify({source:'phone',pid:Process.id,script:options.name,scriptID:options.id,time:Date.now()/1000,message:JSON.parse(encoded)}) + '\n';
      // UTF-16 units * 4 is a conservative UTF-8 budget. One writer per agent file.
      if (written + line.length * 4 > options.limit) return;
      const file = new File(logPath, 'a');
      try { file.write(line); written += line.length * 4; emitted++; } finally { file.close(); }
    } catch (_) { /* Keep original console/send behavior even when capture fails. */ }
  }
  function describe(value) {
    if (typeof value === 'string') return value;
    try { const encoded=JSON.stringify(value); return encoded === undefined ? String(value) : encoded; }
    catch (_) { return String(value); }
  }
  function failure(error) {
    failed = true;
    state('error');
    emit({type:'error',description:String(error),stack:error && error.stack ? String(error.stack) : String(error)});
  }
  for (const level of ['log','info','debug','warn','error']) {
    if (typeof console[level] !== 'function') continue;
    original[level]=console[level];
    console[level]=function(...args) {
      try { emit({type:'log',level,payload:args.map(describe).join(' ')}); } catch (_) {}
      return original[level].apply(this,args);
    };
  }
  const bindings={};
  if (typeof originalSend === 'function') {
    bindings.send=function(payload,data) {
      emit({type:'send',payload});
      return originalSend.apply(this,arguments);
    };
  }
  for (const name of ['setTimeout','setInterval','setImmediate']) {
    const originalTimer=globalThis[name];
    if (typeof originalTimer !== 'function') continue;
    bindings[name]=function(callback,...args) {
      if (typeof callback !== 'function') return originalTimer.apply(this,arguments);
      return originalTimer.call(this,function(...values) {
        try { return callback.apply(this,values); } catch(e) { failure(e); throw e; }
      },...args);
    };
  }
  function readUTF8(path) {
    return File.readAllText(path);
  }
  let commandTimer = null, lastCommand = '';
  function startCommandChannel(execute) {
    if (!commandPath || commandTimer || typeof originalTimers.setInterval !== 'function') return false;
    commandTimer = originalTimers.setInterval(function () {
      let command;
      try { command = JSON.parse(readUTF8(commandPath)); }
      catch (_) { return; }
      if (!command || command.version !== 1 || typeof command.id !== 'string' ||
          !/^[A-Fa-f0-9-]{1,64}$/.test(command.id) || command.id === lastCommand ||
          typeof command.expression !== 'string' || command.expression.length === 0 ||
          command.expression.length > 16384) return;
      lastCommand = command.id;
      emit({type:'command',level:'info',commandID:command.id,payload:command.expression});
      const before = emitted;
      try {
        const value = execute(command.expression, command.id);
        state('loaded');
        const result = {type:'command-result',level:'info',commandID:command.id,returned:false};
        if (emitted === before && value !== undefined) {
          result.payload = describe(value);
          result.returned = true;
        }
        // Every command needs a terminal receipt, even when it only prints
        // output or returns undefined. The command event itself is not completion.
        emit(result);
      } catch (error) {
        emit({type:'error',description:String(error),stack:error && error.stack ? String(error.stack) : String(error),commandID:command.id});
      }
    }, 250);
    return true;
  }
  state('loading');
  return {
    bindings, failure, startCommandChannel,
    loaded() { if (!failed) state('loaded'); },
    wrapInit() {
      if (!rpc.exports || typeof rpc.exports.init !== 'function') return;
      const init=rpc.exports.init;
      rpc.exports.init=function(...args) {
        try {
          const result=init.apply(this,args);
          if (result && typeof result.then === 'function') return result.catch(e=>{failure(e);throw e;});
          return result;
        } catch(e) { failure(e); throw e; }
      };
    }
  };
}
