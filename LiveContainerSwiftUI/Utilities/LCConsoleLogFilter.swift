import Foundation

/// Presentation-only filtering. Never suppress arbitrary stderr, script output or network errors.
enum LCConsoleLogFilter {
    struct Result { let text: String; let hiddenWarnings: Int }
    private static let duplicateClass = try! NSRegularExpression(pattern:
        #"^objc\[[0-9]+\]: Class \S+ is implemented in both .+ and .+\. One of the two will be used\. Which one is undefined\.$"#)

    static func clean(_ text: String) -> Result {
        var hidden = 0
        let lines = text.components(separatedBy: "\n").filter { line in
            let candidate = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if duplicateClass.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil {
                hidden += 1
                return false
            }
            return true
        }
        return Result(text: lines.joined(separator: "\n"), hiddenWarnings: hidden)
    }
}
