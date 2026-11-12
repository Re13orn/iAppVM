// iAppVM smoke test: no Hook, network, file or application-data access.
'use strict';
let snapshot = null;
function diagnose(stage) {
  if (snapshot === null) {
    snapshot = {
      frida: Frida.version,
      pid: Process.id,
      arch: Process.arch,
      platform: Process.platform,
      signing: Process.codeSigningPolicy,
      runtime: Script.runtime
    };
    console.log('[iAppVM] ' + JSON.stringify(snapshot));
  }
  console.log('[iAppVM] lifecycle=' + stage);
}
rpc.exports = {
  init(stage, parameters) { diagnose(stage); },
  status() { return snapshot; }
};
diagnose('loaded');
