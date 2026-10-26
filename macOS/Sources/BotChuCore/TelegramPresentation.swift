import Foundation

/// A phone-sized, extractive digest of an answer, never a second model's interpretation of it.
/// Selection works on complete sentences/bullets, reserving room for caveats and decisions even
/// when they are at the end. The original messages remain the source for /details and Home.
enum TelegramPresentation {
    static let budget = 1_400
    static let more = "Full reply: /details. Everything stays in BotChu."

    private struct Unit {
        var text: String
        var priority: Int
        var paragraph: Int
    }

    static func summary(_ turn: [ChatMessage], botName: String) -> String {
        let botName = displayName(botName)
        let assistant = turn.lastIndex { $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let finalEvent = turn.last { $0.role == .assistant || $0.role == .error }
        let failed = finalEvent?.role == .error
        let stopped = turn.contains { $0.role == .note && $0.text == "Stopped" }
        let toolsAfterAnswer = assistant.map { index in turn[(index + 1)...].contains { $0.role == .tool } } ?? false
        let source = assistant.map { turn[$0].text } ?? ""
        var units = readableUnits(source)
        // A final "tests passed" must not erase a decision or blocker already reported. Label
        // earlier statements as earlier evidence: do not claim that a later result resolved them.
        if let assistant {
            var seen = Set(units.map(\.text))
            for message in turn[..<assistant] where message.role == .assistant {
                for unit in readableUnits(message.text) where unit.priority >= 2 && seen.insert(unit.text).inserted {
                    units.append(Unit(text: "Earlier in this turn: " + unit.text, priority: unit.priority, paragraph: -units.count - 1))
                }
            }
        }
        var status: String?
        if failed {
            status = "⚠️ \(botName) couldn't finish this turn. " + recovery(for: finalEvent?.text ?? "")
        } else if stopped {
            status = "⏹ Stopped in BotChu. This result may be incomplete; send a follow-up to continue."
        } else if toolsAfterAnswer || units.isEmpty {
            status = "\(botName) ended without a final answer. Ask it to explain the result or continue."
        }

        // An old progress message is not a result just because a tool was the last event.
        let candidates = toolsAfterAnswer ? units.filter { $0.priority >= 2 } : units
        var chosen: [Int] = []
        var used = (status?.utf16.count ?? 0) + more.utf16.count + 8
        var omittedImportant = false
        func take(_ i: Int) {
            guard !chosen.contains(i) else { return }
            let size = candidates[i].text.utf16.count + 2
            if used + size <= budget {
                chosen.append(i)
                used += size
            } else if candidates[i].priority >= 2 { omittedImportant = true }
        }
        // Result first, but a long introduction cannot consume the space for the actual decision.
        if let first = candidates.indices.first, candidates[first].text.utf16.count <= 450 { take(first) }
        for i in candidates.indices.sorted(by: { candidates[$0].priority == candidates[$1].priority ? $0 < $1 : candidates[$0].priority > candidates[$1].priority }) where candidates[i].priority >= 2 { take(i) }
        for i in candidates.indices where chosen.count < 6 { take(i) }
        var selected: [String] = []
        var previous: Int?
        for i in chosen.sorted() {
            if let previous, candidates[i].paragraph == candidates[previous].paragraph, i == previous + 1 {
                selected[selected.count - 1] += " " + candidates[i].text
            } else { selected.append(candidates[i].text) }
            previous = i
        }
        var result: [String] = status.map { [$0] } ?? []
        result += selected
        if omittedImportant {
            result.append("There are more caveats or decisions in /details; don't treat this as a complete result.")
        }
        if result.isEmpty {
            result.append("\(botName)'s reply needs more room. Read /details for the answer.")
        }
        let omitted = chosen.count < units.count || toolsAfterAnswer || plainText(source).filter { !$0.isWhitespace } != selected.joined().filter { !$0.isWhitespace }
        if omitted { result.append(more) }
        return result.joined(separator: "\n\n")
    }

    static func displayName(_ name: String) -> String {
        TelegramReply.split(name.replacingOccurrences(of: "\n", with: " "), limit: 80).first ?? "Bot"
    }

    /// Plain text needs no Telegram escaping. Links keep both their label and actual destination,
    /// bullets stay bullets, short code is preserved, and table rows are readable without pipes.
    static func plainText(_ text: String) -> String {
        var output: [String] = []
        var prose: [String] = []
        var inCode = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !prose.isEmpty { output.append(plainProse(prose.joined(separator: "\n"))); prose = [] }
                inCode.toggle()
                output.append(line)
            } else if inCode { output.append(line) }
            else { prose.append(line) }
        }
        if !prose.isEmpty { output.append(plainProse(prose.joined(separator: "\n"))) }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plainProse(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")
        value = replace(#"!?\[([^\]\n]+)\]\(([^\s)]+)\)"#, in: value, with: "$1 ($2)")
        value = replace(#"(?m)^\s{0,3}#{1,6}\s+"#, in: value, with: "")
        value = replace(#"(?m)^\s*[-*+]\s+"#, in: value, with: "• ")
        value = replace(#"(?m)^\s*>\s?"#, in: value, with: "")
        value = replace(#"\*\*([^*\n]+)\*\*|__([^_\n]+)__"#, in: value, with: "$1$2")
        value = replace(#"`([^`\n]+)`"#, in: value, with: "$1")
        value = replace(#"(?m)^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$"#, in: value, with: "")
        value = replace(#"(?m)^\|\s*(.*?)\s*\|$"#, in: value, with: "$1")
        value = value.replacingOccurrences(of: " | ", with: " · ")
        value = replace(#"\\([_*\[\]()~`>#+\-=|{}.!])"#, in: value, with: "$1")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readableUnits(_ text: String) -> [Unit] {
        var pieces: [(text: String, code: Bool)] = []
        var prose: [String] = []
        var code: [String]?
        var language = ""
        func flushProse() {
            if !prose.isEmpty { pieces.append((prose.joined(separator: "\n"), false)); prose = [] }
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if let block = code {
                    if block.count <= 6, block.joined(separator: "\n").utf16.count <= 320,
                       !["json", "jsonl", "log", "logs", "diff"].contains(language), !block.contains(where: noise) {
                        pieces.append((block.joined(separator: "\n"), true))
                    }
                    code = nil
                } else {
                    flushProse()
                    code = []
                    language = String(trimmed.dropFirst(3)).lowercased()
                }
                continue
            }
            if code != nil { code?.append(line); continue }
            if !noise(trimmed) { prose.append(line) }
        }
        flushProse()
        var seen: Set<String> = []
        var result: [Unit] = []
        var paragraphIndex = 0
        for piece in pieces {
            if piece.code {
                // A code example is one indivisible unit. Preserve indentation and operators.
                if !piece.text.isEmpty, seen.insert(piece.text).inserted {
                    result.append(Unit(text: piece.text, priority: 1, paragraph: paragraphIndex))
                }
                paragraphIndex += 1
                continue
            }
            for paragraph in plainProse(piece.text).components(separatedBy: "\n") {
                // Keep punctuation and complete thoughts, never a character-count cutoff.
                let sentences = replace(#"(?<=[.!?])\s+(?=[A-Z0-9•])"#, in: paragraph, with: "\n").components(separatedBy: "\n")
                for sentence in sentences {
                    let sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !sentence.isEmpty, !noise(sentence), seen.insert(sentence).inserted else { continue }
                    result.append(Unit(text: sentence, priority: priority(sentence), paragraph: paragraphIndex))
                }
                paragraphIndex += 1
            }
        }
        return result
    }

    private static func priority(_ text: String) -> Int {
        let lower = text.lowercased()
        if text.contains("?") || matches(#"\b(decision|approval|permission|confirm|choose|need you|please|next step|next action|blocked|blocker|waiting for)\b"#, lower) { return 3 }
        if matches(#"\b(fail(?:ed|ure|ing)?|error|incomplete|partial(?:ly)?|unverified|uncertain|unknown|risk|warning|caveat|cannot|can't|couldn't|not yet|not tested|not verified|not deployed|not merged|still needs|still need|remaining|unable|did not|didn't|not sure)\b"#, lower) { return 2 }
        if matches(#"\b(fixed|complete[d]?|passed|shipped|deployed|merged|found|result|recommend|https?://)\b"#, lower) { return 1 }
        return 0
    }

    private static func noise(_ text: String) -> Bool {
        matches(#"^\s*(\{\s*\"|\[\s*\{|</?(?:system|tool|assistant|analysis)|(?:tool_call|tool_result|function_call|function_result|event|payload)\s*[:=]|(?:DEBUG|TRACE|INFO)\b|\d{4}-\d\d-\d\d[T ]\d\d:|\[\d+/\d+\]|\$\s)"#, text)
    }

    private static func recovery(for error: String) -> String {
        let value = error.lowercased()
        if matches(#"(?:checkout|workspace|working directory|repository|repo|folder).*(?:missing|not found|does not exist)|(?:missing|not found).*(?:checkout|workspace|repository|folder)|no such file or directory"#, value) { return "The workspace or a required file is missing. Restore its location in BotChu, then retry." }
        if matches(#"permission denied|operation not permitted|read.only file system|access denied|not writable"#, value) { return "A file or folder could not be accessed. Check its permissions in BotChu, then retry." }
        if matches(#"no space left|disk full|out of disk|storage full"#, value) { return "Storage is full. Free some space, then retry." }
        if matches(#"\b(auth|unauthorized|login|sign.?in|credential|401|403)\b"#, value) { return "Check the account's sign-in in BotChu, then retry." }
        if matches(#"\b(quota|allowance|rate.?limit|429|credits)\b"#, value) { return "Check its remaining allowance in BotChu, then retry when available." }
        if matches(#"\b(timeout|timed out|network|offline|connection)\b"#, value) { return "Check the connection, then retry. Details are in BotChu." }
        return "Check the error in BotChu, then send a follow-up to retry."
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
