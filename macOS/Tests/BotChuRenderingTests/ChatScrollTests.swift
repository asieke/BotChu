import AppKit
import Foundation
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// Where the chat keeps its reader (#131), as Claude, ChatGPT and Cursor do: sending a message
/// takes them to it from wherever they were; pinned at the end, they stay there while a turn
/// streams, calls and groups grow, sub-agents report and the window or message box resize; scrolled
/// up, nothing that arrives moves them, until they scroll back to the end or click Jump to Latest.
/// The reader's scrolling comes as AppKit delivers it: wheel events into the scroll view, or a
/// scroller drag between its live-scroll notifications.
extension RenderingTests {
    @Test(arguments: [false, true]) func sendingTakesTheReaderToTheirMessage(scrolledUp: Bool) async throws {
        guard #available(macOS 15, *) else { return }
        _ = NSApplication.shared
        let chat = try ScrollingChat(script: ChatScrollFixture.script)
        defer { chat.close() }
        let app = chat.app, target = chat.target
        try await chat.settle()
        if scrolledUp {
            for _ in 0..<15 { Self.wheel(chat.scroll, by: 100) }
            try await chat.settle()
            #expect(!chat.transcript.isPinned)
            #expect(chat.below > 1_000, "scrolled up to \(chat.below) pt above the end")
        } else {
            #expect(chat.transcript.isPinned)
            #expect(chat.below < 1)
        }
        // Return in the message box, as in the report: the message box empties, the message goes
        // through the queue and the conversation prepares its turn, each moving the chat.
        let editor = try #require(chat.window.firstResponder as? NSTextView)
        editor.insertText("Search the web and do deep research on best practices. WAIT", replacementRange: NSRange(location: NSNotFound, length: 0))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: chat.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        chat.window.sendEvent(enter)
        var worst: CGFloat = 0
        for frame in 0..<12 {
            try await chat.settle(frames: 1)
            #expect(chat.transcript.isPinned, "frame \(frame)")
            if frame >= 2 { worst = max(worst, chat.below) }
        }
        #expect(worst < 1, "the chat left the end by \(worst) pt while the message was sent")
        try await chat.wait { app.thread(target).last?.text.hasSuffix("WAIT") == true }
        try await chat.settle()
        #expect(chat.below < 1)
        // The reply arrives below it.
        try chat.release()
        try await chat.wait { app.thread(target).last?.role == .assistant && !app.isRunning(target) }
        try await chat.settle()
        #expect(chat.transcript.isPinned)
        #expect(chat.below < 1)
    }

    @Test func aPinnedChatStaysAtTheEndWhileATurnStreams() async throws {
        guard #available(macOS 15, *) else { return }
        _ = NSApplication.shared
        let chat = try ScrollingChat()
        defer { chat.close() }
        let app = chat.app, target = chat.target, conversation = app.conversation(target)
        var worst: (CGFloat, String) = (0, "")
        func check(_ step: String, frames: Int = 3) async throws {
            try await chat.settle(frames: frames)
            if chat.below > worst.0 { worst = (chat.below, step) }
            #expect(chat.transcript.isPinned, "\(step)")
        }
        app.runStates[target] = RunState(hasOutput: false)
        try await check("typing indicator")
        // A reply streaming in, a delta at a time.
        conversation.append(ChatMessage(role: .assistant, text: "Looking"))
        for i in 0..<20 {
            conversation.stream { $0[$0.count - 1].text += "\n\nMore of the reply \(i), growing in place across a line or two of the chat." }
            try await check("delta \(i)", frames: 1)
        }
        // Calls that group live, finishing and growing the group.
        for i in 0..<8 {
            conversation.append(ChatMessage(role: .tool, toolID: "live\(i)", toolName: "Read", toolInput: "/work/Live\(i).swift", toolState: .running))
            try await check("call \(i) running", frames: 1)
            conversation.stream { $0[$0.count - 1].toolOutput = "let x = \(i)"; $0[$0.count - 1].toolState = .done }
            try await check("call \(i) done", frames: 1)
        }
        // A command with output, and a sub-agent that reports on its card.
        conversation.append(ChatMessage(role: .tool, toolID: "build", toolName: "Bash", toolInput: "swift build",
                                        toolOutput: (1...30).map { "Compiling \($0)" }.joined(separator: "\n"), toolState: .done))
        try await check("command")
        let bot = try #require(app.bot(target.botID))
        var run = SubagentRun(rootBotID: bot.id, rootTaskID: target.taskID, depth: 1, targetBot: bot, title: "Check the docs",
                              brief: "Read the docs and report.", workingDirectory: chat.fixture.root.path, phase: .running)
        app.delegation.records[target] = [run]
        try await check("sub-agent started")
        run.phase = .completed
        run.finishedAt = Date()
        app.delegation.records[target] = [run]
        try await check("sub-agent finished")
        // The message box growing with a long draft, then the window resizing.
        app.drafts[target] = (1...6).map { "Line \($0) of a long draft" }.joined(separator: "\n")
        try await check("message box grew", frames: 6)
        app.drafts[target] = nil
        try await check("message box shrank", frames: 6)
        chat.window.setContentSize(NSSize(width: 980, height: 640))
        try await check("window narrower", frames: 6)
        chat.window.setContentSize(NSSize(width: 1300, height: 960))
        try await check("window wider", frames: 6)
        app.runStates[target] = nil
        try await check("turn ended")
        #expect(worst.0 < 1, "the chat left the end by \(worst.0) pt at \(worst.1)")
    }

    @Test func aReaderScrolledUpKeepsTheirPlaceUntilTheyComeBack() async throws {
        guard #available(macOS 15, *) else { return }
        _ = NSApplication.shared
        let chat = try ScrollingChat()
        defer { chat.close() }
        let app = chat.app, target = chat.target, conversation = app.conversation(target)
        app.runStates[target] = RunState(hasOutput: true)
        try await chat.settle()
        // A few notches of the wheel up from the end.
        for _ in 0..<6 { Self.wheel(chat.scroll, by: 60) }
        try await chat.settle()
        #expect(!chat.transcript.isPinned)
        let held = chat.scroll.contentView.bounds.minY
        let seen = try #require(chat.picture())
        #expect(chat.jumpButton != nil)
        // A reply streams, calls arrive and the turn ends: the reader doesn't move.
        conversation.append(ChatMessage(role: .assistant, text: "Streaming"))
        for i in 0..<12 {
            conversation.stream { $0[$0.count - 1].text += "\n\nStill more \(i), long enough to wrap in the chat." }
            try await chat.settle(frames: 1)
        }
        for i in 0..<6 {
            conversation.append(ChatMessage(role: .tool, toolID: "more\(i)", toolName: "Read", toolInput: "/work/More\(i).swift", toolOutput: "x", toolState: .done))
            try await chat.settle(frames: 1)
        }
        app.runStates[target] = nil
        try await chat.settle()
        #expect(abs(chat.scroll.contentView.bounds.minY - held) < 1)
        #expect(chat.picture() == seen)
        #expect(!chat.transcript.isPinned)
        #expect(chat.below > 300)
        // A resize keeps them off the end too.
        chat.window.setContentSize(NSSize(width: 1100, height: 900))
        try await chat.settle(frames: 6)
        #expect(!chat.transcript.isPinned)
        #expect(chat.below > 300)
        chat.window.setContentSize(NSSize(width: 1300, height: 960))
        try await chat.settle(frames: 6)

        // Back down by hand: pinned again, following what comes.
        for _ in 0..<40 where chat.below > 0.5 { Self.wheel(chat.scroll, by: -60) }
        try await chat.settle()
        let pinnedAfterReturning = chat.transcript.isPinned
        #expect(pinnedAfterReturning)
        #expect(chat.jumpButton == nil)
        conversation.append(ChatMessage(role: .assistant, text: "A new reply\n\nwith a second paragraph."))
        try await chat.settle()
        #expect(chat.below < 1)

        // Up again by the scroller, then Jump to Latest, clicked where it shows.
        Self.dragScroller(chat.scroll, to: 200)
        try await chat.settle()
        #expect(!chat.transcript.isPinned)
        conversation.append(ChatMessage(role: .assistant, text: "Another reply."))
        try await chat.settle()
        #expect(chat.below > 300)
        let jump = try #require(chat.jumpButton)
        chat.click(jump)
        try await chat.settle(frames: 6)
        #expect(chat.transcript.isPinned)
        #expect(chat.below < 1)

        // Scrolled up, then switched away and back: at the newest again.
        Self.dragScroller(chat.scroll, to: 0)
        try await chat.settle()
        #expect(!chat.transcript.isPinned)
        chat.show(.home(target.botID))
        try await chat.settle()
        chat.show(target)
        try await chat.settle(frames: 6)
        #expect(chat.transcript.isPinned)
        #expect(chat.below < 1)
    }

    /// A legacy wheel's notch of `points`, positive toward the top, delivered to the scroll view as
    /// the window would.
    static func wheel(_ scroll: NSScrollView, by points: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: points, wheel2: 0, wheel3: 0)
            .flatMap(NSEvent.init(cgEvent:)) else { return }
        scroll.scrollWheel(with: event)
    }

    /// The reader dragging the scroller until the visible part starts at `y`: AppKit's live scroll,
    /// from its start to its end.
    static func dragScroller(_ scroll: NSScrollView, to y: CGFloat) {
        let clip = scroll.contentView
        let top = max(0, min(y, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height))
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }
}

/// A conversation in a window the size of the report's chat column, shown alone.
@MainActor final class ScrollingChat {
    let fixture: ActivityChatFixture
    let window: NSWindow
    var target: ChatTarget { fixture.task }
    var app: AppModel { fixture.app }
    var transcript: TranscriptModel { TranscriptCache.model(for: target) }
    private let host: NSHostingView<AnyView>
    private let defaults: UserDefaults

    init(script: String? = nil) throws {
        fixture = try ActivityChatFixture(script: script)
        fixture.app.conversation(fixture.task).replace(ChatScrollFixture.messages())
        fixture.app.show(fixture.task)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 960), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defaults = UserDefaults(suiteName: fixture.domain)!
        host = NSHostingView(rootView: AnyView(EmptyView()))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        show(fixture.task)
        host.layoutSubtreeIfNeeded()
    }

    /// The chat's scroll view: another one after switching conversations.
    var scroll: NSScrollView { RenderingTests.chatScrollView(in: host) ?? NSScrollView() }

    func show(_ target: ChatTarget) {
        app.show(target)
        host.rootView = AnyView(ChatView(target: target).id(target).environment(app).defaultAppStorage(defaults))
    }

    func close() {
        window.contentView = nil
        window.close()
        app.runStates.removeAll()
        fixture.cleanUp()
    }

    /// How far the end of the chat is below the visible part.
    var below: CGFloat {
        (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY
    }

    func settle(frames: Int = 4) async throws {
        for _ in 0..<frames {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await settle(frames: 1)
        }
        Issue.record("Timed out waiting for the chat")
        throw CocoaError(.executableLoad)
    }

    /// Lets a turn that waits (WAIT in its message) finish.
    func release() throws {
        try Data().write(to: URL(fileURLWithPath: app.task(target)?.folder ?? fixture.root.path).appendingPathComponent("release"))
    }

    /// Jump to Latest (or Follow Live), where it shows: centered over the bottom of the chat's
    /// visible part, 10 points up. Nil while it doesn't.
    var jumpButton: NSPoint? {
        guard !transcript.isPinned else { return nil }
        let visible = scroll.convert(scroll.bounds, to: nil)
        return NSPoint(x: visible.midX, y: visible.minY + 10 + 14)
    }

    func click(_ point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
    }

    /// The middle of the chat's visible part as drawn, left of its scroller.
    func picture() -> Data? {
        let visible = scroll.convert(scroll.contentView.frame, to: host)
        let band = NSRect(x: visible.minX, y: visible.minY + visible.height * 0.3, width: visible.width - 24, height: visible.height * 0.4).integral
        guard let rep = host.bitmapImageRepForCachingDisplay(in: band) else { return nil }
        host.cacheDisplay(in: band, to: rep)
        guard let data = rep.bitmapData else { return nil }
        return Data(bytes: data, count: rep.bytesPerRow * rep.pixelsHigh)
    }
}

@MainActor enum ChatScrollFixture {
    /// Codex answering at once, or, with WAIT in the message, once `release` is in its folder.
    static let script = #"""
    import json, sys, time
    from pathlib import Path
    def emit(value):
        print(json.dumps(value), flush=True)
    emit({"type":"thread.started", "thread_id":"scroll-session"})
    prompt = sys.argv[-1]
    if "WAIT" in prompt:
        while not Path("release").exists():
            time.sleep(0.02)
    emit({"type":"item.completed", "item":{"type":"agent_message", "text":"reply: " + prompt.splitlines()[-1]}})
    emit({"type":"turn.completed"})
    """#

    /// A conversation like the report's: turns of a question, a few calls and a long reply.
    static func messages(turns: Int = 8) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for turn in 0..<turns {
            messages.append(ChatMessage(role: .user, text: "Question \(turn): look into the next part and tell me what you find."))
            for call in 0..<3 {
                messages.append(ChatMessage(role: .tool, toolID: "r\(turn)-\(call)", toolName: "Read", toolInput: "/work/File\(turn)-\(call).swift",
                                            toolOutput: "let x = \(call)", toolState: .done))
            }
            messages.append(ChatMessage(role: .tool, toolID: "b\(turn)", toolName: "Bash", toolInput: "swift build", toolOutput: "Build complete!", toolState: .done))
            let points = (1...8).map { "- **Point \($0).** A sentence long enough to wrap across a line or two in the chat, with a [link](https://example.com/\($0)) in it." }
            messages.append(ChatMessage(role: .assistant, text: "## Answer \(turn)\n\n" + points.joined(separator: "\n") + "\n\nWhich of those should I pull up next?"))
        }
        return messages
    }
}
