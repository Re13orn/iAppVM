/* Static analysis only. Source text is parsed by Acorn, never evaluated. */
function iappvmAnalyze(source) {
  const result = { packaged: false, syntaxError: null, objc: false, swift: false, java: false,
    ownObjC: false, topObjC: false, hooks: false, dynamicCode: false, legacyAPI: false,
    modules: false, objcImports: [], directiveEnd: 0, hashbangEnd: 0 };
  if (source.trimStart().startsWith('📦')) { result.packaged = true; return JSON.stringify(result); }
  let ast, moduleMode = false;
  try { ast = acorn.parse(source, { ecmaVersion: 2022, sourceType: 'script', allowHashBang: true }); }
  catch (scriptError) {
    try { ast = acorn.parse(source, { ecmaVersion: 2022, sourceType: 'module', allowHashBang: true }); moduleMode = true; }
    catch (_) { result.syntaxError = 'JavaScript 解析失败，行 ' + (scriptError.loc ? scriptError.loc.line : '?') + '，列 ' + (scriptError.loc ? scriptError.loc.column + 1 : '?'); return JSON.stringify(result); }
  }
  if (source.startsWith('#!')) { const end = source.indexOf('\n'); result.hashbangEnd = end < 0 ? source.length : end + 1; }
  result.directiveEnd = result.hashbangEnd;
  for (const node of ast.body) {
    if (node.type === 'ExpressionStatement' && typeof node.directive === 'string') result.directiveEnd = node.end;
    else break;
  }
  function names(pattern) {
    if (!pattern) return [];
    switch (pattern.type) {
      case 'Identifier': return [pattern.name];
      case 'RestElement': return names(pattern.argument);
      case 'AssignmentPattern': return names(pattern.left);
      case 'ArrayPattern': return pattern.elements.flatMap(names);
      case 'ObjectPattern': return pattern.properties.flatMap(p => names(p.type === 'RestElement' ? p.argument : p.value));
      default: return [];
    }
  }
  const stack = [{ node: ast, parent: null, key: null, functionDepth: 0 }];
  while (stack.length) {
    const { node, parent, key, functionDepth } = stack.pop();
    const type = node.type;
    if (type === 'ImportDeclaration') {
      if (node.source.value === 'frida-objc-bridge' && node.specifiers.length === 1 &&
          node.specifiers[0].type === 'ImportDefaultSpecifier' && node.specifiers[0].local.name === 'ObjC') {
        result.objcImports.push({ start: node.start, end: node.end }); result.objc = true;
      } else result.modules = true;
    }
    if (type.startsWith('Export') || type === 'ImportExpression' || (type === 'MetaProperty' && node.meta.name === 'import') ||
        (functionDepth === 0 && (type === 'AwaitExpression' || (type === 'ForOfStatement' && node.await)))) result.modules = true;
    if (type === 'CallExpression' && node.callee.type === 'Identifier') {
      if (node.callee.name === 'require') result.modules = true;
      if (node.callee.name === 'eval' || node.callee.name === 'Function') result.dynamicCode = true;
    }
    if (type === 'NewExpression' && node.callee.type === 'Identifier' && node.callee.name === 'Function') result.dynamicCode = true;
    if (type === 'VariableDeclarator' || type === 'FunctionDeclaration' || type === 'ClassDeclaration') {
      if (names(node.id).includes('ObjC')) { result.ownObjC = true; if (functionDepth === 0) result.topObjC = true; }
    }
    if (/Function|ArrowFunction/.test(type) && node.params && node.params.some(p => names(p).includes('ObjC'))) result.ownObjC = true;
    if (type === 'CatchClause' && names(node.param).includes('ObjC')) result.ownObjC = true;
    let name = null;
    if (type === 'Identifier') {
      const property = parent && ((parent.type === 'MemberExpression' && key === 'property' && !parent.computed) ||
        ((parent.type === 'Property' || parent.type === 'MethodDefinition' || parent.type === 'PropertyDefinition') && key === 'key' && !parent.computed));
      if (!property) name = node.name;
    }
    if (type === 'MemberExpression') {
      const prop = !node.computed && node.property.type === 'Identifier' ? node.property.name :
        node.computed && node.property.type === 'Literal' ? node.property.value : null;
      if (node.object.type === 'Identifier' && node.object.name === 'globalThis') {
        name = prop;
        if (prop === 'ObjC' && parent && parent.type === 'AssignmentExpression' && key === 'left') result.ownObjC = true;
      }
      if (node.object.type === 'Identifier' && node.object.name === 'Module' &&
          ['findExportByName', 'getExportByName', 'findBaseAddress'].includes(prop)) result.legacyAPI = true;
    }
    if (name === 'ObjC') result.objc = true;
    if (name === 'Swift') result.swift = true;
    if (name === 'Java') result.java = true;
    if (name === 'Interceptor' || name === 'Stalker') result.hooks = true;
    const childDepth = functionDepth + ((/Function|ArrowFunction/.test(type) && node.params) ? 1 : 0);
    for (const childKey of Object.keys(node)) {
      const value = node[childKey];
      if (Array.isArray(value)) {
        for (const child of value) if (child && typeof child.type === 'string') stack.push({node: child, parent: node, key: childKey, functionDepth: childDepth});
      } else if (value && typeof value.type === 'string') stack.push({node: value, parent: node, key: childKey, functionDepth: childDepth});
    }
  }
  result.moduleStrict = moduleMode;
  return JSON.stringify(result);
}

// Capture direct global send/timer calls without overwriting Frida's read-only globals.
function iappvmRewritePhoneCalls(source, key) {
  let ast;
  try { ast=acorn.parse(source,{ecmaVersion:2022,sourceType:'script',allowHashBang:true}); }
  catch (_) { return source; }
  const targets=new Set(['send','setTimeout','setInterval','setImmediate']);
  const blocked=new Set(); const calls=[]; const nodes=[ast];
  function bind(pattern) {
    if(!pattern)return;
    if(pattern.type==='Identifier'){blocked.add(pattern.name);return;}
    if(pattern.type==='RestElement')return bind(pattern.argument);
    if(pattern.type==='AssignmentPattern')return bind(pattern.left);
    if(pattern.type==='ArrayPattern')return pattern.elements.forEach(bind);
    if(pattern.type==='ObjectPattern')return pattern.properties.forEach(p=>bind(p.type==='RestElement'?p.argument:p.value));
  }
  while(nodes.length) {
    const node=nodes.pop();
    if(node.type==='WithStatement')return source;
    if(['VariableDeclarator','FunctionDeclaration','ClassDeclaration'].includes(node.type))bind(node.id);
    if(node.params)node.params.forEach(bind);
    if(node.type==='CatchClause')bind(node.param);
    if(node.type==='CallExpression'&&node.callee.type==='Identifier'&&targets.has(node.callee.name))calls.push(node.callee);
    for(const value of Object.values(node)){
      if(Array.isArray(value)){for(const child of value)if(child&&typeof child.type==='string')nodes.push(child);}
      else if(value&&typeof value.type==='string')nodes.push(value);
    }
  }
  if(blocked.has('globalThis'))return source;
  for(const call of calls.sort((a,b)=>b.start-a.start))if(!blocked.has(call.name))source=source.slice(0,call.start)+'globalThis['+JSON.stringify(key)+'].'+call.name+source.slice(call.end);
  return source;
}
