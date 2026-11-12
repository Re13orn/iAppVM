import Foundation
@main struct PhoneScriptLogTests {
    static func main() throws {
        let fm=FileManager.default, folder=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at:folder) }
        let root=folder.appendingPathComponent("phone-scripts")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let id=UUID().uuidString
        let session:[String:Any]=["pid":42,"phoneScriptLogs":["version":2,"commandProtocol":"file-v1","scripts":[["id":id,"name":"fixture.js","file":id+".jsonl","stateFile":id+".state.json"]]]]
        let good:[String:Any]=["source":"phone","pid":42,"scriptID":id,"script":"fixture.js","time":1,"message":["type":"log","payload":"[fixture] ready\n{\"success\":true}"]]
        var wrong=good;wrong["source"]="computer"
        var other=good;other["pid"]=43
        let commandLog:[String:Any]=["source":"phone","pid":42,"scriptID":id,"script":"fixture.js","time":2,"message":["type":"command","payload":"1 + 1"]]
        let commandResult:[String:Any]=["source":"phone","pid":42,"scriptID":id,"script":"fixture.js","time":3,"message":["type":"command-result","payload":"2"]]
        let lines=try [good,wrong,other,commandLog,commandResult].map{String(data:try JSONSerialization.data(withJSONObject:$0),encoding:.utf8)!}.joined(separator:"\n")+"\ninvalid-fragment\n"
        try Data(lines.utf8).write(to:root.appendingPathComponent(id+".jsonl"))
        try Data("IAPPVM_PROCESS_NOISE\nSSLHandshake failed\n".utf8).write(to:folder.appendingPathComponent("console.log"))
        let entries=try LCPhoneScriptLog.entries(folder:folder,session:session)
        precondition(entries.count==3)
        let text=LCPhoneScriptLog.text(entries,multiple:false)
        precondition(text=="[fixture] ready\n{\"success\":true}\n> 1 + 1\n=> 2" && !text.contains("SSLHandshake"))
        precondition(LCPhoneScriptLog.text(entries,multiple:true).hasPrefix("[fixture.js]"))
        let missingID=UUID().uuidString
        var clearedSession=session
        var metadata=clearedSession["phoneScriptLogs"] as! [String:Any]
        metadata["scripts"]=[["id":missingID,"name":"cleared.js","file":missingID+".jsonl","stateFile":missingID+".state.json"],(metadata["scripts"] as! [[String:Any]])[0]]
        clearedSession["phoneScriptLogs"]=metadata
        let entriesAfterClear=try LCPhoneScriptLog.entries(folder:folder,session:clearedSession)
        precondition(entriesAfterClear.count==3)
        let state:[String:Any]=["source":"phone","pid":42,"id":id,"state":"loaded"]
        try JSONSerialization.data(withJSONObject:state).write(to:root.appendingPathComponent(id+".state.json"))
        precondition(LCPhoneScriptLog.states(folder:folder,session:session).count==1)
        // Process-only sessions have no phone-scripts directory. A timeline
        // must skip them instead of failing before it can show console/network events.
        let processOnly = folder.appendingPathComponent("process-only", isDirectory: true)
        try fm.createDirectory(at: processOnly, withIntermediateDirectories: true)
        let enumerated = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent == "process-only" }!
        let noPhoneEntries = try LCPhoneScriptLog.entries(folder: enumerated, session: ["pid": 42])
        precondition(noPhoneEntries.isEmpty)
        precondition(LCPhoneScriptLog.descriptors([:]).isEmpty)
        precondition(LCPhoneScriptLog.supportsCommands(session))
        let expression = "console.log('中文命令');"
        let commandID = try LCPhoneScriptLog.sendCommand(folder:folder,session:session,scriptID:id,expression:expression)
        let commandURL = root.appendingPathComponent(id+".command.json")
        let command = try JSONSerialization.jsonObject(with:Data(contentsOf:commandURL)) as! [String:Any]
        precondition(command["version"] as? Int == 1 && command["id"] as? String == commandID.uuidString && command["expression"] as? String == expression)
        do { _ = try LCPhoneScriptLog.sendCommand(folder:folder,session:session,scriptID:id,expression:"1 + 1"); throw NSError(domain:"accepted-fast-overwrite",code:1) }
        catch let error as NSError { precondition(error.domain != "accepted-fast-overwrite") }
        try fm.setAttributes([.modificationDate:Date().addingTimeInterval(-3)], ofItemAtPath:commandURL.path)
        let nextID = try LCPhoneScriptLog.sendCommand(folder:folder,session:session,scriptID:id,expression:"1 + 1")
        precondition(nextID != commandID)
        do { _ = try LCPhoneScriptLog.sendCommand(folder:folder,session:session,scriptID:id,expression:"  "); throw NSError(domain:"accepted",code:1) }
        catch let error as NSError { precondition(error.domain == "IOSVMPhoneScripts") }
        print("PASS: isolated file routing, multiline script output, wrong-source/PID rejection and state receipts")
    }
}
