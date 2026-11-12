// Standalone UI acceptance harness using synthetic files; never opens wallet data.
import SwiftUI
import SQLite3

extension String: @retroactive Error {}

@main
struct SandboxBrowserApp: App {
    private let root: URL
    init() {
        let fm = FileManager.default
        root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Fixture")
        for folder in ["Documents", "Library", "tmp"] {
            try! fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try! Data("hidden fixture\n".utf8).write(to: root.appendingPathComponent(".hidden.txt"))
        try! Data("{\"purpose\":\"sandbox browser acceptance\",\"enabled\":true,\"count\":3}".utf8)
            .write(to: root.appendingPathComponent("Documents/example.json"))
        try! PropertyListSerialization.data(fromPropertyList: ["fixture": true, "format": "binary plist"], format: .binary, options: 0)
            .write(to: root.appendingPathComponent("Library/example.plist"))
        var db: OpaquePointer?
        sqlite3_open(root.appendingPathComponent("Documents/example.sqlite").path, &db)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS checks (id INTEGER, name TEXT); DELETE FROM checks; INSERT INTO checks VALUES(1,'directory listing'),(2,'JSON preview'),(3,'SQLite read-only');", nil, nil, nil)
        sqlite3_close(db)
    }
    var body: some Scene {
        WindowGroup {
            NavigationView {
                if let preview = UserDefaults.standard.string(forKey: "preview") {
                    LCContainerFilePreview(root: root, url: root.appendingPathComponent(preview))
                } else if let table = UserDefaults.standard.string(forKey: "table") {
                    LCSQLiteTableView(root: root, url: root.appendingPathComponent("Documents/example.sqlite"), table: table)
                } else {
                    LCContainerFilesView(root: root, directory: root)
                }
            }.navigationViewStyle(.stack)
        }
    }
}
