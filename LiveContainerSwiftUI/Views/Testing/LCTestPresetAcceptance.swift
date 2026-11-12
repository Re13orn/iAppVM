#if IOSVM_TESTING
import Foundation

enum LCTestPresetAcceptance {
    @MainActor static func run(_ model:LCAppModel,action:String) async {
        guard model.appInfo.relativeBundlePath == "dev.iosvm.debugcheck.app" else {return}
        let fm=FileManager.default,owner=model.appInfo.relativeBundlePath!
        let reportURL=LCPath.docPath.appendingPathComponent("iOSVMUITests/preset-acceptance.json")
        var report:[String:Any]=["state":"running","action":action]
        do {
            try fm.createDirectory(at:reportURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            if action=="setup" {
                await LCFridaWorkbenchAcceptance.run(model,action:"setup")
                report["state"]="setup"
            } else if action=="test" {
                guard !model.isAppRunning, let first=model.uiSelectedContainer else {throw "Start and stop the fixture once first"}
                let second=LCContainer(folderName:UUID().uuidString,name:"Preset fixture B",isShared:false)
                second.makeLCContainerInfoPlist(appIdentifier:model.appInfo.bundleIdentifier(),keychainGroupId:1)
                model.uiContainers.append(second);model.appInfo.containers=model.uiContainers
                var a=try LCTestPresetManager.capture(model,name:"自动脚本")
                a.container=first.folderName;try LCTestPresetStore.save(a)
                var b=a;b.id=UUID();b.name="网络分析";b.container=second.folderName;b.automatic=false;b.scripts=Array(a.scripts.prefix(1));b.network.capture=true;b.network.proxyType="http";b.network.host="127.0.0.1";b.network.port=19191
                try LCTestPresetStore.save(b)
                try await LCTestPresetManager.apply(b,model:model)
                guard model.uiSelectedContainer?.folderName==second.folderName,
                      try LCTestPresetManager.network(model)==b.network,
                      try LCFridaSetup.config(model.appInfo)["interaction"] as? [String:Any] != nil,
                      let folder=LCFridaSetup.folder(for:model.appInfo),
                      try LCFridaScriptStore.selection(folder:folder).automatic==false else {throw "Preset B mismatch"}
                var bad=a;bad.scripts=[UUID()]
                let oldFolder=model.uiTweakFolder
                do {try await LCTestPresetManager.apply(bad,model:model);throw NSError(domain:"UnexpectedSuccess",code:1)}
                catch let e as NSError {if e.domain=="UnexpectedSuccess"{throw e}}
                guard model.uiTweakFolder==oldFolder else {throw "Invalid preset changed config"}
                let networkFile=LCTestPresetManager.networkURL(model),oldNetwork=try Data(contentsOf:networkFile)
                var alternative=b.network;alternative.proxyType="off"
                let path="iOSVM/NetworkSettingsV2/"+owner+".json"
                let changes=[LCSettingsTransaction.Change(path:path,before:oldNetwork,after:try JSONEncoder().encode(alternative))]
                let journal=LCSettingsTransaction.Journal(owner:owner,changes:changes)
                try JSONEncoder().encode(journal).write(to:LCSettingsTransaction.url(owner:owner),options:.atomic)
                try changes[0].after.write(to:networkFile,options:.atomic)
                guard LCLaunchPreflight.check(model).contains(where:{$0.id=="transaction" && $0.blocking}) else {throw "Interrupted transaction not detected"}
                try LCSettingsTransaction.recover(owner:owner)
                guard try Data(contentsOf:networkFile)==oldNetwork else {throw "Recovery mismatch"}
                try await LCTestPresetManager.apply(a,model:model)
                let selectedFolder=LCFridaSetup.folder(for:model.appInfo)!
                let selection=try LCFridaScriptStore.selection(folder:selectedFolder)
                guard let id=selection.scripts.first, let script=try LCFridaScriptStore.list().first(where:{$0.id==id}) else {throw "Fixture script missing"}
                let source=try LCFridaScriptStore.source(script)
                try LCFridaScriptStore.remove(script)
                guard LCLaunchPreflight.check(model).contains(where:{$0.id=="scripts" && $0.blocking}) else {throw "Missing script not detected"}
                try LCFridaScriptStore.save(id:id,name:script.name,source:source)
                // Check the expiry metadata parser with synthetic data, without altering the real profile.
                let expired=try PropertyListSerialization.data(fromPropertyList:["ExpirationDate":Date(timeIntervalSince1970:1)],format:.xml,options:0)
                guard LCLaunchPreflight.profileExpiry(expired)==Date(timeIntervalSince1970:1) else {throw "Expiry parser mismatch"}
                report=["state":"tested","presets":[a.id.uuidString,b.id.uuidString],"containerA":first.folderName,"containerB":second.folderName,"active":a.id.uuidString,"fridaFolder":selectedFolder.lastPathComponent,
                        "checks":["coordinated-switch","invalid-script-rejected","interrupted-recovery","preflight-missing-script","expiry-parser"]]
            } else if action == "network" {
                guard let b = try LCTestPresetStore.list(owner:owner).first(where:{$0.name=="网络分析"}) else {throw "Missing fixture preset"}
                try await LCTestPresetManager.apply(b,model:model)
                report["state"]="network-applied"
            } else if action == "break" {
                guard let a = try LCTestPresetStore.list(owner:owner).first(where:{$0.name=="自动脚本"}) else {throw "Missing fixture preset"}
                try await LCTestPresetManager.apply(a,model:model)
                let script=try LCFridaScriptStore.list().first(where:{$0.id==a.scripts.first})!
                try LCFridaScriptStore.remove(script)
                report["state"]="broken"
            } else {throw "Unknown acceptance action"}
        } catch {report["state"]="failed";report["error"]=error.localizedDescription}
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL,options:.atomic)
    }
}
#endif
