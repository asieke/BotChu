import Foundation

/// Foundation parses Markdown's block structure, but SwiftUI Text only draws its inline styles.
/// Keep that structure as a tree so the app can lay out lists, quotes, code and tables natively.
public struct MarkdownBlock: Identifiable, Equatable, Sendable {
    public let id: Int
    public let kind: PresentationIntent.Kind
    public var text: AttributedString = AttributedString()
    public var children: [MarkdownBlock] = []

    public static func split(_ source: String) -> [MarkdownBlock] {
        guard !source.isEmpty else { return [] }
        let options = AttributedString.MarkdownParsingOptions(failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(source))]
        }
        var root = MarkdownBlock(id: 0, kind: .paragraph)
        for run in parsed.runs {
            let path = Array(run.presentationIntent?.components.reversed() ?? [])
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            root.append(text, path: path[...])
        }
        return root.children.isEmpty && !root.text.characters.isEmpty ? [root] : root.children
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
