import Foundation

/// Foundation parses Markdown's block structure, but SwiftUI Text only draws its inline styles.
/// Keep that structure as a tree so the app can lay out lists, quotes, code and tables natively.
public struct MarkdownBlock: Identifiable, Equatable, Sendable {
    public let id: Int
    public let kind: PresentationIntent.Kind
    public var text: AttributedString = AttributedString()
    public var children: [MarkdownBlock] = []
    /// Its place in the reply: its index among its parent's children, at each level from the top.
    /// Kept with it, so a view of an unchanged block is given the very same value again.
    public var path: [Int] = []

    public static func split(_ source: String) -> [MarkdownBlock] {
        guard !source.isEmpty else { return [] }
        MarkdownParses.record()
        let options = AttributedString.MarkdownParsingOptions(failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(source), path: [0])]
        }
        var root = MarkdownBlock(id: 0, kind: .paragraph)
        for run in parsed.runs {
            let path = Array(run.presentationIntent?.components.reversed() ?? [])
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            root.append(text, path: path[...])
        }
        var blocks = root.children.isEmpty && !root.text.characters.isEmpty ? [root] : root.children
        place(&blocks, in: [])
        return blocks
    }

    private static func place(_ blocks: inout [MarkdownBlock], in parent: [Int]) {
        for index in blocks.indices {
            blocks[index].path = parent + [index]
            place(&blocks[index].children, in: blocks[index].path)
        }
    }

    /// `blocks`, with each block equal to the one in `old` at its place taken from `old`, and
    /// within a block that changed (a list gaining an item), its children likewise.
    static func reusing(_ old: [MarkdownBlock], in blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        var result = blocks
        for index in result.indices.prefix(old.count) {
            let earlier = old[index]
            if result[index] == earlier {
                result[index] = earlier
            } else if result[index].id == earlier.id, result[index].kind == earlier.kind, !earlier.children.isEmpty {
                result[index].children = reusing(earlier.children, in: result[index].children)
            }
        }
        return result
    }

    private mutating func append(_ text: AttributedString, path: ArraySlice<PresentationIntent.IntentType>) {
        guard let component = path.first else {
            self.text.append(text)
            return
        }
        if children.last?.id != component.identity {
            children.append(MarkdownBlock(id: component.identity, kind: component.kind))
        }
        children[children.count - 1].append(text, path: path.dropFirst())
    }
}

/// Markdown parses counted, so tests can check that a reply is parsed once (`counting`), and that
/// a reply being written is never parsed on the main thread (`main`).
enum MarkdownParses {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func add() { lock.lock(); value += 1; lock.unlock() }
    }

    @TaskLocal static var counter: Counter?
    private static let onMain = Counter()

    static func record() {
        counter?.add()
        if Thread.isMainThread { onMain.add() }
    }

    /// The parses run on the main thread since launch.
    static var main: Int { onMain.count }

    /// How many parses `work` runs on its own thread.
    static func counting(_ work: () -> Void) -> Int {
        let counter = Counter()
        $counter.withValue(counter, operation: work)
        return counter.count
    }
}

/// What a reply's text says about its layout, read in one pass over its bytes: its length, its
/// code fences, and whether it may hold math or a diagram (`RichMarkdown`).
public struct MarkdownShape: Equatable, Sendable {
    public var bytes = 0
    /// How many times "```" occurs, as `components(separatedBy: "```").count - 1` counts them.
    public var fences = 0
    /// It has a `$`, `\(` or `\[`, or says "mermaid" in any case: only then can it be rich.
    public var mayBeRich = false

    public init(_ text: String) {
        var text = text
        text.withUTF8 { bytes in
            self.bytes = bytes.count
            let mermaid = Array("mermaid".utf8)
            var index = 0
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "`"):
                    if index + 2 < bytes.count, bytes[index + 1] == UInt8(ascii: "`"), bytes[index + 2] == UInt8(ascii: "`") {
                        fences += 1
                        index += 3
                        continue
                    }
                case UInt8(ascii: "$"):
                    mayBeRich = true
                case UInt8(ascii: "\\"):
                    if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "(") || bytes[index + 1] == UInt8(ascii: "[") { mayBeRich = true }
                case UInt8(ascii: "m"), UInt8(ascii: "M"):
                    if !mayBeRich, index + mermaid.count <= bytes.count,
                       (0..<mermaid.count).allSatisfy({ bytes[index + $0] | 0x20 == mermaid[$0] }) { mayBeRich = true }
                default:
                    break
                }
                index += 1
            }
        }
    }
}
