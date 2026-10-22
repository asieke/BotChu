import Foundation

/// A reply split for display: fenced code blocks apart from the prose around them, since SwiftUI's
/// `Text` renders only inline Markdown.
public enum MarkdownBlock: Equatable, Sendable {
    case prose(String)
    case code(String)

    public static func split(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var inCode = false
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(.prose(normalize(joined))) }
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code = []
                } else {
                    flushProse()
                }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        // An unclosed fence (a reply still streaming) shows as code so far.
        if inCode { blocks.append(.code(code.joined(separator: "\n"))) }
        flushProse()
        return blocks
    }

    /// Block syntax inline Markdown would show literally: headings become bold lines and list
    /// bullets become "•".
    static func normalize(_ prose: String) -> String {
        prose.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop(while: { $0 == " " })
            let indent = String(repeating: " ", count: line.count - trimmed.count)
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return heading.isEmpty ? String(line) : "**\(heading)**"
            }
            for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
                return indent + "• " + trimmed.dropFirst(2)
            }
            return String(line)
        }.joined(separator: "\n")
    }
}
