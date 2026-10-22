import Foundation

/// Keeps TeX out of the Markdown parser and serializes math and Mermaid blocks as escaped data.
/// Ordinary replies use native views; rich replies are rendered offline by the bundled libraries.
public enum RichMarkdown {
    public static func html(_ source: String) -> String? {
        guard source.contains("$") || source.contains("\\(") || source.contains("\\[")
                || source.localizedCaseInsensitiveContains("mermaid") else { return nil }
        let scanned = Scanner(source)
        let blocks = MarkdownBlock.split(scanned.masked)
        guard !scanned.expressions.isEmpty || containsDiagram(blocks) else { return nil }
        let renderer = Renderer(expressions: scanned.expressions)
        return blocks.map(renderer.block).joined()
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

    private struct Scanner {
        var masked = ""
        var expressions: [String: Expression] = [:]

        init(_ source: String) {
            let chars = Array(source)
            var prefix = "BCHUMATH"
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
                    if end + closing.count <= chars.count, Array(chars[end..<end + closing.count]) == closing {
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
                let token = "\(prefix)\(expressions.count)END"
                expressions[token] = Expression(source: String(chars[index..<finish]), body: body, display: display, complete: complete)
                masked += token
                index = finish
            }
        }
    }

    private struct Renderer {
        let expressions: [String: Expression]

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
                else {
                    html = raw.htmlEscaped
                    for (token, expression) in expressions { html = html.replacingOccurrences(of: token, with: expression.html) }
                }
                if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
                if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
                if intent.contains(.strikethrough) { html = "<s>\(html)</s>" }
                if intent.contains(.lineBreak) { html = "<br>" }
                if let link = run.link, let scheme = link.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                    html = "<a href=\"\(restore(link.absoluteString).htmlEscaped)\">\(html)</a>"
                }
                return html
            }.joined()
        }

        func restore(_ text: String) -> String {
            expressions.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value.source) }
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
