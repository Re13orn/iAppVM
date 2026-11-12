const fs=require('fs'),vm=require('vm'),assert=require('assert');
const files=new Map();let receiver;
function native(name){
  if(name==='sel_registerName')return x=>x;
  if(name==='NSHomeDirectory')return ()=> 'home';
  if(name==='objc_msgSend')return ()=>({readUtf8String:()=>'/own-fixture'});
  if(name==='mkdir')return ()=>0;
  if(name==='rename')return (from,to)=>{files.set(to,files.get(from));files.delete(from);return 0;};
  throw Error(name);
}
const context=vm.createContext({Module:{getGlobalExportByName:x=>x},NativeFunction:function(name){return native(name);},Memory:{allocUtf8String:x=>x},Process:{id:42},rpc:{exports:{}},recv:(name,fn)=>{receiver=fn;},File:function(path,mode){this.write=s=>files.set(path,(mode==='a'?(files.get(path)||''):'')+s);this.close=()=>{};}});
vm.runInContext(fs.readFileSync('TestTools/Frida/client-monitor.js','utf8'),context);
context.rpc.exports.heartbeat('17.7.3',[{id:'0',name:'desktop.js',state:'loaded'},{id:'1',name:'broken.js',state:'error'}]);
const path='/own-fixture/Library/iOSVM/Debug/client.json';
let receipt=JSON.parse(files.get(path));
assert.equal(receipt.source,'computer');assert.equal(receipt.pid,42);assert.equal(receipt.scripts.length,2);
assert.equal(receipt.scripts[1].state,'error');assert.equal(receipt.connected,true);
receiver({payload:{executionSource:'computer',source:'desktop.js',scriptID:'0',message:{type:'log',payload:'own-fixture-output'}}});
context.rpc.exports.disconnect();receipt=JSON.parse(files.get(path));assert.equal(receipt.connected,false);
const log=files.get('/own-fixture/Library/iOSVM/Debug/'+receipt.logFile).trim().split('\n').map(JSON.parse);
assert(log.every(e=>e.source==='computer'&&e.sessionID===receipt.sessionID&&e.pid===42));
assert(log.some(e=>e.message.event==='computer-script-state'));
assert(log.some(e=>e.message.source==='desktop.js'));
assert(log.some(e=>e.message.event==='computer-disconnected'));
console.log('PASS: computer receipt provenance, per-script states, script log identity and disconnection');
