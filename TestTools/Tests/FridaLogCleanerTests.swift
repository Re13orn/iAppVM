import Foundation

@main struct FridaLogCleanerTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("iappvm-log-clean-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let sessions = root.appendingPathComponent("Library/iOSVM/Sessions")
        let debug = root.appendingPathComponent("Library/iOSVM/Debug")
        let first = sessions.appendingPathComponent("session-1")
        let second = sessions.appendingPathComponent("session-2")
        let scripts = first.appendingPathComponent("phone-scripts")
        for directory in [scripts, second, debug] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("process one".utf8).write(to: first.appendingPathComponent("console.log"))
        try Data("process two".utf8).write(to: second.appendingPathComponent("console.log"))
        try Data("phone one".utf8).write(to: scripts.appendingPathComponent("script.jsonl"))
        try Data("state".utf8).write(to: scripts.appendingPathComponent("script.state.json"))
        let client1 = debug.appendingPathComponent("client-1-42.jsonl")
        let client2 = debug.appendingPathComponent("client-2-43.jsonl")
        let receipt = debug.appendingPathComponent("client.json")
        try Data("computer one".utf8).write(to: client1)
        try Data("computer two".utf8).write(to: client2)
        try Data("receipt".utf8).write(to: receipt)

        let phoneRemoved = try LCFridaLogCleaner.clearSession(root: root, folder: first, source: .phone)
        precondition(phoneRemoved == 1)
        precondition(!fm.fileExists(atPath: scripts.appendingPathComponent("script.jsonl").path))
        precondition(fm.fileExists(atPath: scripts.appendingPathComponent("script.state.json").path))
        precondition(fm.fileExists(atPath: first.appendingPathComponent("console.log").path))
        let processRemoved = try LCFridaLogCleaner.clearSession(root: root, folder: second, source: .process)
        precondition(processRemoved == 1)
        precondition(!fm.fileExists(atPath: second.appendingPathComponent("console.log").path))
        let computerRemoved = try LCFridaLogCleaner.clearComputerLog(root: root, file: client1)
        precondition(computerRemoved == 1)
        precondition(!fm.fileExists(atPath: client1.path) && fm.fileExists(atPath: client2.path))
        let allRemoved = try LCFridaLogCleaner.clearAll(root: root)
        precondition(allRemoved == 3)
        let remainingSessions = try fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)
        precondition(remainingSessions.isEmpty)
        precondition(!fm.fileExists(atPath: client2.path) && fm.fileExists(atPath: receipt.path))
        do {
            _ = try LCFridaLogCleaner.clearComputerLog(root: root, file: receipt)
            throw NSError(domain: "acceptedReceipt", code: 1)
        } catch let error as NSError {
            precondition(error.domain == "IOSVMFridaLogs")
        }
        let linked = root.appendingPathComponent("LinkedContainer")
        let outside = root.appendingPathComponent("OutsideSessions")
        let outsideSession = outside.appendingPathComponent("session-outside")
        try fm.createDirectory(at: outsideSession, withIntermediateDirectories: true)
        let victim = outsideSession.appendingPathComponent("console.log")
        try Data("must remain".utf8).write(to: victim)
        let linkedLibrary = linked.appendingPathComponent("Library/iOSVM")
        try fm.createDirectory(at: linkedLibrary, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedLibrary.appendingPathComponent("Sessions"), withDestinationURL: outside)
        do {
            _ = try LCFridaLogCleaner.clearAll(root: linked)
            throw NSError(domain: "acceptedLinkedRoot", code: 1)
        } catch let error as NSError {
            precondition(error.domain == "IOSVMFridaLogs")
        }
        precondition(fm.fileExists(atPath: victim.path))
        print("PASS: clear current phone/process/computer logs; clear all sessions; preserve state receipts, connection receipt and unrelated data")
        print("PASS: linked log roots and files are rejected before cleanup")
    }
}
