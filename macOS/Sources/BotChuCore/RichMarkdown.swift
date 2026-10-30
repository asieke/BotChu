import Foundation

/// Keeps TeX out of the Markdown parser and serializes math and Mermaid blocks as escaped data.
/// Ordinary replies use native views; rich replies are rendered offline by the bundled libraries.
public enum RichMarkdown {
    public static func html(_ source: String) -> String? {
        if case .rich(let html) = rendering(source) { return html }
        return nil
    }

    /// How the reply is drawn, from one Markdown parse. A reply without math has nothing masked,
    /// so the blocks parsed to look for a diagram are its own: a `$HOME` in shell code, a price or
    /// the word "mermaid" doesn't parse it twice.
    static func rendering(_ source: String) -> MarkdownRendering {
        guard MarkdownShape(source).mayBeRich else { return .blocks(MarkdownBlock.split(source)) }
        let scanned = Scanner(source)
        let blocks = MarkdownBlock.split(scanned.masked)
        guard !scanned.expressions.isEmpty || containsDiagram(blocks) else { return .blocks(blocks) }
        let renderer = Renderer(prefix: Array(scanned.prefix.utf8), expressions: scanned.expressions)
        return .rich(html: blocks.map(renderer.block).joined())
    }

    private static func containsDiagram(_ blocks: [MarkdownBlock]) -> Bool {
        blocks.contains {
            if case .codeBlock(let language) = $0.kind, language?.lowercased() == "mermaid" { return true }
            return containsDiagram($0.children)
        }
    }

    private struct Expression {
        let source: String
        let body: String
        let display: Bool
        let complete: Bool

        var html: String {
            guard complete else {
                return "<code class=\"math-source\">\(source.htmlEscaped)</code>"
            }
            return "<span class=\"tex\" data-display=\"\(display)\" data-tex=\"\(body.htmlEscaped)\">\(source.htmlEscaped)</span>"
        }
    }

    /// The source with each expression replaced by a token, `<prefix><number>END`, that the
    /// Markdown parser leaves alone; the prefix is one the source doesn't contain.
    private struct Scanner {
        var masked = ""
        var expressions: [Expression] = []
        var prefix = "BCHUMATH"

        init(_ source: String) {
            let chars = Array(source)
            while source.contains(prefix) { prefix += "X" }
            var index = 0
            var fence: (Character, Int)?
            while index < chars.count {
                // Preserve fenced code verbatim, including incomplete streaming fences.
                if index == 0 || chars[index - 1] == "\n" {
                    let end = chars[index...].firstIndex(of: "\n") ?? chars.count
                    let line = Array(chars[index..<end].drop(while: { $0 == " " || $0 == "\t" || $0 == ">" }))
                    let marker = line.first ?? " "
                    let count = line.prefix(while: { $0 == marker }).count
                    let isFence = (marker == "`" || marker == "~") && count >= 3
                    if let current = fence {
                        if isFence, current.0 == marker, count >= current.1,
                           line.dropFirst(count).allSatisfy(\.isWhitespace) { fence = nil }
                        masked += String(chars[index..<end]); index = end
                        if index < chars.count { masked.append("\n"); index += 1 }
                        continue
                    } else if isFence {
                        fence = (marker, count)
                        masked += String(chars[index..<end]); index = end
                        if index < chars.count { masked.append("\n"); index += 1 }
                        continue
                    }
                }
                if chars[index] == "`" {
                    let count = chars[index...].prefix(while: { $0 == "`" }).count
                    var end = index + count
                    var found = false
                    while end < chars.count {
                        if chars[end] == "`" {
                            let length = chars[end...].prefix(while: { $0 == "`" }).count
                            end += length
                            if length == count { found = true; break }
                        } else { end += 1 }
                    }
                    if !found { end = index + count }
                    masked += String(chars[index..<end]); index = end
                    continue
                }
                let backslashMath = chars[index] == "\\" && index + 1 < chars.count && "([".contains(chars[index + 1])
                if chars[index] == "\\", !backslashMath, index + 1 < chars.count {
                    masked += String(chars[index...index + 1]); index += 2
                    continue
                }
                guard chars[index] == "$" || backslashMath else {
                    masked.append(chars[index]); index += 1; continue
                }
                let display = backslashMath ? chars[index + 1] == "[" : index + 1 < chars.count && chars[index + 1] == "$"
                let length = backslashMath || display ? 2 : 1
                let begin = index + length
                guard begin < chars.count, display || !chars[begin].isWhitespace else {
                    masked += String(chars[index..<begin]); index = begin; continue
                }
                let closing: [Character] = backslashMath ? ["\\", display ? "]" : ")"] : Array(display ? "$$" : "$")
                var end = begin
                var complete = false
                while end < chars.count {
                    if !display, chars[end] == "\n" { break }
                    if end + closing.count <= chars.count, chars[end] == closing[0], closing.count == 1 || chars[end + 1] == closing[1] {
                        let after = end + closing.count
                        // Single-dollar math cannot close before a digit: "$5 and $10" is currency.
                        if display || backslashMath || (end > begin && !chars[end - 1].isWhitespace && (after == chars.count || !chars[after].isNumber)) {
                            complete = true; break
                        }
                        if !display, !backslashMath { break }
                    }
                    if !display, !backslashMath, chars[end] == "`" { break }
                    if !display, !backslashMath, chars[end] == "\\", end + 1 < chars.count, chars[end + 1] == "$" { break }
                    if chars[end] == "\\", end + 1 < chars.count { end += 2 }
                    else { end += 1 }
                }
                let body = String(chars[begin..<end])
                if !complete, end < chars.count, chars[end] != "\n" {
                    masked.append(chars[index]); index += 1; continue
                }
                if !complete, !display, !backslashMath, !body.contains("_") && !body.contains("^") && !body.contains("\\") {
                    masked.append(chars[index]); index += 1; continue
                }
                let finish = complete ? end + closing.count : end
                masked += "\(prefix)\(expressions.count)END"
                expressions.append(Expression(source: String(chars[index..<finish]), body: body, display: display, complete: complete))
                index = finish
            }
        }
    }

    private struct Renderer {
        /// The tokens' prefix, in UTF-8.
        let prefix: [UInt8]
        let expressions: [Expression]

        func block(_ value: MarkdownBlock) -> String {
            let children = { value.children.map(block).joined() }
            switch value.kind {
            case .paragraph: return "<p>\(inline(value.text))</p>"
            case .header(let level): return "<h\(level)>\(inline(value.text))</h\(level)>"
            case .orderedList:
                let start: Int
                if let item = value.children.first, case .listItem(let ordinal) = item.kind { start = ordinal }
                else { start = 1 }
                return "<ol start=\"\(start)\">\(children())</ol>"
            case .unorderedList: return "<ul>\(children())</ul>"
            case .listItem: return "<li>\(children())</li>"
            case .blockQuote: return "<blockquote>\(children())</blockquote>"
            case .thematicBreak: return "<hr>"
            case .codeBlock(let language):
                if language?.lowercased() == "mermaid" {
                    let source = restore(String(value.text.characters)).htmlEscaped
                    return "<section class=\"diagram-block\"><header>Diagram<button type=\"button\" class=\"copy-code\">Copy source</button><button type=\"button\" class=\"diagram-size\" hidden>Actual size</button></header><div class=\"diagram\" aria-label=\"Mermaid diagram\"></div><details open><summary>Source</summary><pre><code>\(source)</code></pre></details></section>"
                }
                return "<section class=\"code-block\"><header>\((language ?? "Code").htmlEscaped)<button type=\"button\" class=\"copy-code\" aria-label=\"Copy code\">Copy</button></header><pre><code>\(restore(String(value.text.characters)).htmlEscaped)</code></pre></section>"
            case .table(let columns):
                let rows = value.children.map { row in
                    let tag = row.kind == .tableHeaderRow ? "th" : "td"
                    let cells = columns.enumerated().map { index, column in
                        let cell = row.children.first { $0.kind == .tableCell(columnIndex: index) }
                        let alignment = column.alignment == .right ? "right" : column.alignment == .center ? "center" : "left"
                        return "<\(tag) style=\"text-align:\(alignment)\">\(inline(cell?.text ?? AttributedString()))</\(tag)>"
                    }.joined()
                    return "<tr>\(cells)</tr>"
                }.joined()
                return "<div class=\"table-scroll\"><table>\(rows)</table></div>"
            default: return children()
            }
        }

        func inline(_ text: AttributedString) -> String {
            text.runs.map { run in
                let raw = String(text[run.range].characters)
                let intent = run.inlinePresentationIntent ?? []
                var html: String
                if intent.contains(.code) { html = "<code>\(restore(raw).htmlEscaped)</code>" }
                else { html = substitute(raw.htmlEscaped, with: \.html) }
                if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
                if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
                if intent.contains(.strikethrough) { html = "<s>\(html)</s>" }
                if intent.contains(.lineBreak) { html = "<br>" }
                if let link = run.link, ReplyLink(link) == .web {
                    html = "<a href=\"\(restore(link.absoluteString).htmlEscaped)\">\(html)</a>"
                } else if let link = run.link, let page = URL(string: restore(link.absoluteString)).flatMap(FileLink.pageLink) {
                    // A file the reply links to, resolved by the chat, not against this page (#363).
                    html = "<a href=\"\(page.htmlEscaped)\">\(html)</a>"
                }
                return html
            }.joined()
        }

        func restore(_ text: String) -> String {
            substitute(text, with: \.source)
        }

        /// The text with each token replaced by its expression's `value`, found where the text
        /// has the prefix: one pass over the text, however many expressions the reply has.
        /// Escaping leaves tokens as they are, as they are only capitals and digits.
        func substitute(_ text: String, with value: (Expression) -> String) -> String {
            guard !expressions.isEmpty else { return text }
            var text = text
            return text.withUTF8 { bytes in
                var result = ""
                var copied = 0
                var index = 0
                while index + prefix.count <= bytes.count {
                    guard bytes[index] == prefix[0], (1..<prefix.count).allSatisfy({ bytes[index + $0] == prefix[$0] }) else {
                        index += 1
                        continue
                    }
                    var end = index + prefix.count
                    var number = 0
                    while end < bytes.count, end - index - prefix.count < 9, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[end]) {
                        number = number * 10 + Int(bytes[end] - UInt8(ascii: "0"))
                        end += 1
                    }
                    guard end > index + prefix.count, end + 3 <= bytes.count, bytes[end] == UInt8(ascii: "E"),
                          bytes[end + 1] == UInt8(ascii: "N"), bytes[end + 2] == UInt8(ascii: "D"), number < expressions.count else {
                        index += 1
                        continue
                    }
                    // The prefix and token are ASCII, so these are whole characters.
                    result += String(decoding: UnsafeBufferPointer(rebasing: bytes[copied..<index]), as: UTF8.self)
                    result += value(expressions[number])
                    index = end + 3
                    copied = index
                }
                guard copied > 0 else { return String(decoding: bytes, as: UTF8.self) }
                result += String(decoding: UnsafeBufferPointer(rebasing: bytes[copied...]), as: UTF8.self)
                return result
            }
        }
    }
}

extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
