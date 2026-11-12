import Foundation
@main struct ConsoleLogFilterTests {
    static func main() throws {
        let warning = "objc[123]: Class Example is implemented in both /A (0x1) and /B (0x2). One of the two will be used. Which one is undefined."
        let normal = "Frida: Listening on 127.0.0.1 TCP port 27044\nTypeError: fixture\nCFNetwork SSLHandshake failed (-9806)\n[Trust audit] Ready\n"
        let result = LCConsoleLogFilter.clean(warning + "\r\n" + normal)
        precondition(result.hiddenWarnings == 1 && result.text == normal)
        precondition(LCConsoleLogFilter.clean(normal).text == normal)
        let script = "console.log('" + warning + "')\n{\"message\":\"" + warning + "\"}\n"
        precondition(LCConsoleLogFilter.clean(script).text == script)
        precondition(LCConsoleLogFilter.clean("objc[123]: Class Example is implemented in both /A").hiddenWarnings == 0)
        if CommandLine.arguments.count == 3 {
            let original = URL(fileURLWithPath:CommandLine.arguments[1])
            let data = try Data(contentsOf:original)
            let cleaned = LCConsoleLogFilter.clean(String(decoding:data,as:UTF8.self))
            precondition(cleaned.hiddenWarnings == 158)
            precondition(cleaned.text.contains("Frida: Listening on 127.0.0.1 TCP port 27044"))
            precondition(cleaned.text.contains("CFNetwork SSLHandshake failed (-9806)"))
            let destination = URL(fileURLWithPath:CommandLine.arguments[2])
            precondition(!FileManager.default.fileExists(atPath:destination.path))
            try Data(cleaned.text.utf8).write(to:destination,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
            let untouched = try Data(contentsOf:original)
            precondition(untouched == data)
            print("PASS: filtered 158 duplicate-class warnings; original log and real errors preserved")
        }
    }
}
