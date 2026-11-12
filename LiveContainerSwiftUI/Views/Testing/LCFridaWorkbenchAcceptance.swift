#if IOSVM_TESTING
import Foundation

/// Fixed self-owned fixture only; no user-selected app, script or deletion path is accepted.
enum LCFridaWorkbenchAcceptance {
    @MainActor static func run(_ model: LCAppModel, action: String) async {
        guard model.appInfo.relativeBundlePath == "dev.iosvm.debugcheck.app" else { return }
        let fm = FileManager.default
        let reportFolder = LCPath.docPath.appendingPathComponent("iOSVMUITests")
        let output = reportFolder.appendingPathComponent("debug-workbench.json")
        var report: [String: Any] = (try? Data(contentsOf: output)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        do {
            try fm.createDirectory(at: reportFolder, withIntermediateDirectories: true)
            if action == "sources-phone" {
                try await LCFridaSetup.prepare(model.appInfo)
                let a = try LCFridaScriptStore.save(name:"Source phone fixture",source:"console.log('IAPPVM_PHONE_ONLY'); send({fixture:'phone-send'}); const fixturePuts=new NativeFunction(Module.getGlobalExportByName('puts'),'int',['pointer']); fixturePuts(Memory.allocUtf8String('IAPPVM_PROCESS_NOISE'));")
                let b = try LCFridaScriptStore.save(name:"Source computer fixture",source:"console.log('IAPPVM_COMPUTER_ONLY'); rpc.exports={status(){return {source:'computer-fixture'};}};")
                let timer = try LCFridaScriptStore.save(name:"Source phone timer failure",source:"setTimeout(()=>{throw Error('IAPPVM_PHONE_TIMER_ERROR')},30);")
                let bad = try LCFridaScriptStore.save(name:"Source phone startup failure",source:"throw Error('IAPPVM_PHONE_STARTUP_ERROR');")
                var selection = try LCFridaScriptStore.selection(folder:LCFridaSetup.folder(for:model.appInfo)!)
                selection.automatic=true; selection.captureConsole=true; selection.scripts=[a.id,timer.id,bad.id]; selection.computerScripts=[b.id]
                try LCFridaScriptStore.apply(selection,folder:LCFridaSetup.folder(for:model.appInfo)!)
                model.uiTweakFolder=model.appInfo.tweakFolder
                try await IOSVMDeviceSigning.sign(model.appInfo)
                report=["state":"sources-phone","phoneScripts":[a.id.uuidString,timer.id.uuidString,bad.id.uuidString],"computerScripts":[b.id.uuidString],"pluginFolder":model.appInfo.tweakFolder!]
            } else if action == "sources-computer" {
                var selection = try LCFridaScriptStore.selection(folder:LCFridaSetup.folder(for:model.appInfo)!)
                selection.automatic=false
                try LCFridaScriptStore.apply(selection,folder:LCFridaSetup.folder(for:model.appInfo)!)
                let archive=try LCFridaConnectionPackage.create(app:model.appInfo)
                let fixtureArchive=reportFolder.appendingPathComponent("source-connection.zip")
                try Data(contentsOf:archive).write(to:fixtureArchive,options:.atomic)
                LCManagedDirectory.cleanup(archive.deletingLastPathComponent())
                report["connectionPackage"]=fixtureArchive.path; report["state"]="sources-computer"
            } else if action == "compatibility" {
                try await LCFridaSetup.prepare(model.appInfo)
                let plain = "\"use strict\"; const marker='plain'; console.log('IAPPVM_OBJC_PLAIN ' + ObjC.available + ' ' + ObjC.classes.NSString.stringWithString_('fixture').toString() + ' ' + Process.codeSigningPolicy);"
                let imported = "import ObjC from 'frida-objc-bridge'; const marker='import'; rpc.exports={init(){console.log('IAPPVM_OBJC_IMPORT ' + ObjC.available + ' ' + ObjC.classes.NSString.stringWithString_('fixture').toString());}};"
                let a = try LCFridaScriptStore.save(name: "Acceptance ObjC", source: plain)
                let file = reportFolder.appendingPathComponent("compatibility-import.js")
                try Data(imported.utf8).write(to:file,options:.atomic)
                let before = Set(try LCFridaScriptStore.list().map(\.id))
                let notes = try LCFridaScriptStore.importFile(file)
                guard let b = try LCFridaScriptStore.list().first(where:{!before.contains($0.id)}),
                      try LCFridaScriptStore.source(a) == plain, try LCFridaScriptStore.source(b) == imported else { throw "Source preservation failed" }
                var selection = try LCFridaScriptStore.selection(folder:LCFridaSetup.folder(for:model.appInfo)!)
                selection.automatic = true; selection.captureConsole = true; selection.scripts = [a.id,b.id]
                try LCFridaScriptStore.apply(selection,folder:LCFridaSetup.folder(for:model.appInfo)!)
                model.uiTweakFolder = model.appInfo.tweakFolder
                try await IOSVMDeviceSigning.sign(model.appInfo)
                report = ["state":"compatibility","scripts":[a.id.uuidString,b.id.uuidString],"pluginFolder":model.appInfo.tweakFolder!,"importNotes":notes,"originalsPreserved":true]
            } else if action == "setup" {
                try await LCFridaSetup.prepare(model.appInfo)
                let a = try LCFridaScriptStore.save(name: "Acceptance A", source: "const marker = 'A'; console.log('IOSVM_AUTO_A'); send({fixture:'A'});\n")
                let b = try LCFridaScriptStore.save(name: "Acceptance B", source: "const marker = 'B'; rpc.exports = { init() { console.log('IOSVM_AUTO_B_INIT'); } };\n")
                let bad = try LCFridaScriptStore.save(name: "Acceptance error", source: "throw new Error('IOSVM_AUTO_EXPECTED_FAILURE');\n")
                report = ["bundle":model.appInfo.relativeBundlePath!,"scripts":[a.id.uuidString,b.id.uuidString,bad.id.uuidString]]
                var selection = try LCFridaScriptStore.selection(folder: LCFridaSetup.folder(for:model.appInfo)!)
                selection.automatic = true; selection.captureConsole = true; selection.scripts = [a.id,b.id,bad.id]
                try LCFridaScriptStore.apply(selection, folder: LCFridaSetup.folder(for:model.appInfo)!)
                // Exercise imported-version storage + per-app switching with the known bundled binary.
                let source = try LCFridaVersions.library(LCFridaVersions.builtin)
                let before = Set(try LCFridaVersions.versions().map(\.id))
                try LCFridaVersions.importFile(source, version: LCFridaVersions.builtin.version)
                let imported = try LCFridaVersions.versions().first { !before.contains($0.id) }!
                report["importedVersion"] = imported.id
                try await LCFridaSetup.switchVersion(imported, app:model.appInfo)
                model.uiTweakFolder = model.appInfo.tweakFolder
                try await IOSVMDeviceSigning.sign(model.appInfo)
                let network = IOSVMGuestAccess.networkSettingsDirectory(documents: LCPath.docPath)
                try LCManagedDirectory.ensureWritable(network, inside: LCPath.docPath)
                try JSONSerialization.data(withJSONObject:["version":1,"capture":true,"bodies":false,"proxyType":"off","host":"","port":8080]).write(to:network.appendingPathComponent("dev.iosvm.debugcheck.app.json"),options:.atomic)
                report["pluginFolder"] = model.appInfo.tweakFolder!
                report["state"] = "setup"
            } else if action == "edit" {
                guard let ids = report["scripts"] as? [String], let first = ids.first, let id = UUID(uuidString:first),
                      let script = try LCFridaScriptStore.list().first(where:{$0.id == id && $0.name == "Acceptance A"}) else { throw "Fixture script missing" }
                try LCFridaScriptStore.save(id:script.id,name:script.name,source:"console.log('IOSVM_AUTO_A_EDITED');\n")
                report["state"] = "edited"
            } else if action == "listen" {
                let folder = LCFridaSetup.folder(for:model.appInfo)!
                var selection = try LCFridaScriptStore.selection(folder:folder)
                selection.automatic = false
                try LCFridaScriptStore.apply(selection,folder:folder)
                report["state"] = "listen"
            } else if action == "package" {
                let folder = LCFridaSetup.folder(for:model.appInfo)!
                var selection = try LCFridaScriptStore.selection(folder:folder)
                selection.automatic = false; selection.computerScripts = Array(selection.scripts.prefix(2))
                try LCFridaScriptStore.apply(selection,folder:folder)
                let archive = try LCFridaConnectionPackage.create(app:model.appInfo)
                report["connectionPackage"] = archive.path
                report["state"] = "package"
            } else if action == "proxy" {
                let diagnostic = LCProxyDiagnostic()
                var checks: [String:String] = [:]
                for (kind,port) in [("http",19191),("socks5",19192),("http",19193)] {
                    diagnostic.test(kind:kind,host:"192.168.5.34",port:port)
                    while diagnostic.running { try await Task.sleep(nanoseconds:50_000_000) }
                    checks[kind + String(port)] = diagnostic.result
                }
                report["proxyChecks"] = checks
                let network = IOSVMGuestAccess.networkSettingsDirectory(documents: LCPath.docPath)
                try JSONSerialization.data(withJSONObject:["version":1,"capture":true,"bodies":false,"proxyType":"http","host":"192.168.5.34","port":19191]).write(to:network.appendingPathComponent("dev.iosvm.debugcheck.app.json"),options:.atomic)
                report["state"] = "proxy"
            }
            report["gadgetVersion"] = try LCFridaScriptStore.selection(folder:LCFridaSetup.folder(for:model.appInfo)!).gadgetVersion
        } catch { report["error"] = error.localizedDescription; report["state"] = "failed" }
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
    }
}
#endif
