const globalExport = name => Module.getGlobalExportByName ? Module.getGlobalExportByName(name) : Module.getExportByName(null, name);
// Companion receipt, loaded in its own context before user scripts. No Interceptor required.
const sel = new NativeFunction(globalExport('sel_registerName'), 'pointer', ['pointer']);
const msg = new NativeFunction(globalExport('objc_msgSend'), 'pointer', ['pointer', 'pointer']);
const home = new NativeFunction(globalExport('NSHomeDirectory'), 'pointer', []);
const root = msg(home(), sel(Memory.allocUtf8String('UTF8String'))).readUtf8String();
const rename = new NativeFunction(globalExport('rename'), 'int', ['pointer', 'pointer']);
const mkdir = new NativeFunction(globalExport('mkdir'), 'int', ['pointer', 'int']);
for (const part of ['/Library/iOSVM', '/Library/iOSVM/Debug']) mkdir(Memory.allocUtf8String(root + part), 0o700);
const destination = root + '/Library/iOSVM/Debug/client.json';
const startedAt = Date.now() / 1000;
const sessionID = Date.now() + '-' + Process.id + '-' + Math.random().toString(16).slice(2, 10);
const log = root + '/Library/iOSVM/Debug/client-' + sessionID + '.jsonl';
let bytes = 0;
let clientVersion = 'unknown';
let scriptStates;
let previousState = null;
function writeReceipt(connected) {
    const temporary = destination + '.tmp-' + Process.id;
    const file = new File(temporary, 'w');
    file.write(JSON.stringify({source: "computer", sessionID, logFile: log.split("/").pop(), startedAt, pid: Process.id, connected, clientVersion, scripts: scriptStates, heartbeat: Date.now() / 1000})); file.close();
    if (rename(Memory.allocUtf8String(temporary), Memory.allocUtf8String(destination)) !== 0) throw new Error('receipt rename failed');
}
function append(payload) {
    const encoded = JSON.stringify(payload);
    if (encoded.length > 16384) payload = {truncated: true, text: encoded.slice(0, 16384)};
    const line = JSON.stringify({source: 'computer', sessionID, pid: Process.id, time: Date.now() / 1000, message: payload}) + '\n';
    if (bytes + line.length * 4 <= 4 * 1024 * 1024) {
        const file = new File(log, 'a'); file.write(line); file.close(); bytes += line.length * 4;
    }
}
function collect(message) {
    try { append(message.payload); }
    finally { recv('iosvm-log', collect); }
}
recv('iosvm-log', collect);
rpc.exports = {
    heartbeat(version, states) {
        clientVersion = version;
        if (Array.isArray(states)) scriptStates = states.slice(0, 32).map(s => ({id: String(s.id).slice(0, 80), name: String(s.name).slice(0, 160), state: String(s.state).slice(0, 20)}));
        const state = JSON.stringify(scriptStates || []);
        if (state !== previousState) { append({event: 'computer-script-state', scripts: scriptStates || []}); previousState = state; }
        writeReceipt(true);
    },
    disconnect() { append({event: 'computer-disconnected'}); writeReceipt(false); }
};
