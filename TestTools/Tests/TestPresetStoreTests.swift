import Foundation

enum LCPath { static let docPath = FileManager.default.temporaryDirectory.appendingPathComponent("iosvm-presets-tests-"+UUID().uuidString) }
@main struct TestPresetStoreTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message:String) throws {
        if try !value() { throw NSError(domain:"PresetTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    static func rejected(_ operation:() throws -> Void) throws {
        do {try operation();throw NSError(domain:"UnexpectedSuccess",code:1)} catch let error as NSError {try require(error.domain != "UnexpectedSuccess","invalid state accepted")}
    }
    static func main() throws {
        let root=LCPath.docPath,fm=FileManager.default
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? fm.removeItem(at:root)}
        let script=UUID()
        var preset=LCTestPresetStore.Preset(owner:"AppA.app",name:"Network")
        preset.container="containerA";preset.gadgetID="builtin";preset.automatic=true;preset.scripts=[script]
        func validate(_ value:LCTestPresetStore.Preset,owner:String="AppA.app") throws {try LCTestPresetStore.validate(value,owner:owner,containers:["containerA"],scripts:[script],gadgets:["builtin"])}
        try validate(preset);try LCTestPresetStore.save(preset)
        try require(LCTestPresetStore.list(owner:"AppA.app")==[preset],"preset not persisted")
        try require(LCTestPresetStore.list(owner:"AppB.app").isEmpty,"another App sees this preset")
        try rejected{try validate(preset,owner:"AppB.app")}
        var invalid=preset;invalid.container="missing";try rejected{try validate(invalid)}
        invalid=preset;invalid.scripts=[UUID()];try rejected{try validate(invalid)}
        invalid=preset;invalid.gadgetID="missing";try rejected{try validate(invalid)}
        invalid=preset;invalid.network.proxyType="http";invalid.network.host="http://bad";try rejected{try validate(invalid)}
        for state in ["pending","signing","device-signing"] {
            let request = try JSONSerialization.data(withJSONObject:["state":state,"guest":"AppA.app"])
            try rejected{try LCTestPresetStore.requireIdleSigningRequest(request,owner:"AppA.app")}
        }
        try LCTestPresetStore.requireIdleSigningRequest(try JSONSerialization.data(withJSONObject:["state":"ready","guest":"AppA.app"]),owner:"AppA.app")
        print("PASS: signing-in-progress blocks configuration changes")
        print("PASS: per-App presets; reject foreign owner, missing container/script/Gadget and invalid proxy")
        let metadataPath="Applications/AppA.app/LCAppInfo.plist",networkPath="iOSVM/NetworkSettingsV2/AppA.app.json"
        let metadata=root.appendingPathComponent(metadataPath),network=root.appendingPathComponent(networkPath)
        for url in [metadata,network]{try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)}
        let before=Data("old".utf8),after=Data("new".utf8)
        try before.write(to:metadata)
        let changes=[LCSettingsTransaction.Change(path:networkPath,before:nil,after:after),LCSettingsTransaction.Change(path:metadataPath,before:before,after:after)]
        try LCSettingsTransaction.apply(owner:preset.owner,changes:changes)
        try require(Data(contentsOf:metadata)==after && Data(contentsOf:network)==after,"transaction not published")
        try require(!fm.fileExists(atPath:LCSettingsTransaction.url(owner:preset.owner).path),"successful transaction journal retained")
        // Emulate death after publishing the first of two files.
        try before.write(to:metadata);try fm.removeItem(at:network)
        let journal=LCSettingsTransaction.Journal(owner:preset.owner,changes:changes)
        let journalURL=LCSettingsTransaction.url(owner:preset.owner)
        try JSONEncoder().encode(journal).write(to:journalURL)
        try after.write(to:network)
        try LCSettingsTransaction.recover(owner:preset.owner)
        try require(Data(contentsOf:metadata)==before && !fm.fileExists(atPath:network.path),"partial transaction was not restored")
        // Another writer must not be overwritten during recovery.
        try JSONEncoder().encode(journal).write(to:journalURL)
        let foreign=Data("another edit".utf8);try foreign.write(to:metadata)
        try rejected{try LCSettingsTransaction.recover(owner:preset.owner)}
        try require(Data(contentsOf:metadata)==foreign,"recovery overwrote concurrent edit")
        try fm.removeItem(at:journalURL);try before.write(to:metadata)
        // Inject a write failure at the second path after the first path has been written.
        let directoryPath=root.appendingPathComponent("Applications/AppA.app/LCAppInfo.plist")
        try fm.removeItem(at:directoryPath);try fm.createDirectory(at:directoryPath,withIntermediateDirectories:false)
        try rejected{try LCSettingsTransaction.apply(owner:preset.owner,changes:changes)}
        try require(!fm.fileExists(atPath:network.path),"failed precondition partially published network")
        try fm.removeItem(at:directoryPath);try before.write(to:metadata)
        try fm.setAttributes([.posixPermissions:0o500],ofItemAtPath:metadata.deletingLastPathComponent().path)
        try rejected{try LCSettingsTransaction.apply(owner:preset.owner,changes:changes)}
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:metadata.deletingLastPathComponent().path)
        try require(!fm.fileExists(atPath:network.path) && Data(contentsOf:metadata)==before,"a late write failure was not rolled back")
        try require(!fm.fileExists(atPath:journalURL.path),"late failure left a journal despite successful rollback")
        // A tampered journal must not address another app even under the same Documents root.
        let bad=LCSettingsTransaction.Journal(owner:preset.owner,changes:[.init(path:"Applications/AppB.app/LCAppInfo.plist",before:nil,after:after)])
        try JSONEncoder().encode(bad).write(to:journalURL)
        try rejected{try LCSettingsTransaction.recover(owner:preset.owner)}
        try fm.removeItem(at:journalURL)
        print("PASS: transaction publish, interrupted rollback, preservation of unrelated edits, reject foreign paths")
        try LCTestPresetStore.remove(preset)
        try require(LCTestPresetStore.list(owner:preset.owner).isEmpty,"delete did not remove preset")
        print("PASS: removing a preset preserves config and script references")
    }
}
