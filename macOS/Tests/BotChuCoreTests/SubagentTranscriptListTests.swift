import Foundation
import Testing
@testable import BotChuCore

/// #361: what a sub-agent's Transcript lists and how much of it.
struct SubagentTranscriptListTests {
    private func tool(_ name: String, _ index: Int = 0) -> ChatMessage {
        ChatMessage(role: .tool, toolID: "call-\(index)", toolName: name, toolInput: "ls", toolState: .done)
    }

    @Test func listsRepliesToolsAndErrorsButNotEmptyRepliesOrBotChusLines() {
        let messages = [
            ChatMessage(role: .user, text: "The brief"),
            ChatMessage(role: .assistant, text: "Looking."),
            ChatMessage(role: .assistant, text: " \n\t "),
            tool("Bash"),
            ChatMessage(role: .note, text: "New session"),
            ChatMessage(role: .receipt, text: "Task done"),
            ChatMessage(role: .error, text: "exit 1"),
            ChatMessage(role: .error, text: ""),
        ]
        let list = SubagentTranscriptList(messages, kind: .claude)
        #expect(list.items.map(\.id) == [messages[1].id, messages[3].id, messages[6].id])
    }

    /// Sail's submissions are progress rows of the provider, a third of a Sail run's tool rows: they
    /// are neither listed nor counted, under way or done. One that failed says what went wrong, and
    /// is. A tool of that name elsewhere is a tool call.
    @Test func sailProgressRowsAreNotListedUnlessTheyFailed() {
        var waiting = tool(SailAgent.rowName, 3), failed = tool(SailAgent.rowName, 4)
        waiting.toolState = .running
        failed.toolState = .failed
        let messages = [tool(SailAgent.rowName, 0), tool("bash", 1), tool(SailAgent.rowName, 2),
                        ChatMessage(role: .assistant, text: "Done."), waiting, failed]
        #expect(SubagentTranscriptList(messages, kind: .sail).items.map(\.id) == [messages[1].id, messages[3].id, failed.id])
        #expect(SubagentTranscriptList(messages, kind: .claude).items.count == 6)
    }

    /// Following, it shows the last `window`; it starts where the reader asked once they did.
    @Test func showsTheLastWindowUntilTheReaderAsksForEarlierOnes() {
        let window = SubagentTranscriptList.window
        let short = SubagentTranscriptList((0..<5).map { tool("Bash", $0) }, kind: .claude)
        #expect(short.start(pinned: nil) == 0)
        var messages = (0..<160).map { tool("Bash", $0) }
        var list = SubagentTranscriptList(messages, kind: .claude)
        #expect(list.start(pinned: nil) == 160 - window)
        // As it streams, the window moves with the last item.
        messages.append(tool("Bash", 160))
        list = SubagentTranscriptList(messages, kind: .claude)
        #expect(list.items.count - list.start(pinned: nil) == window)
        #expect(list.items[list.start(pinned: nil)...].last?.id == messages.last?.id)
        #expect(list.start(pinned: 40) == 40)
        #expect(list.start(pinned: 500) == list.items.count)
    }

    /// "Show N earlier" while following: the held transcript can start earlier than the live one
    /// (the resident messages moved on meanwhile), so the start counts back from its end.
    @Test func showingEarlierCountsBackFromTheEndOfTheHeldTranscript() {
        let held = SubagentTranscriptList((0..<300).map { tool("Bash", $0) }, kind: .claude)
        #expect(SubagentTranscriptList.start(showing: 12, before: 12, in: held) == 276)
        #expect(SubagentTranscriptList.start(showing: 100, before: 250, in: held) == 0)
    }
}
