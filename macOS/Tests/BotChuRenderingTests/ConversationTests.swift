import AppKit
import Foundation
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func composerSendsWithReturnWhileRunningAndKeepsTaskQueuesSeparate() async throws {
        _ = NSApplication.shared
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.runStates[target] = RunState(hasOutput: true, activity: .coding)
        app.show(target)
        let defaults = UserDefaults(suiteName: fixture.domain)!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); app.runStates.removeAll() }
        window.contentView = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("Also update the documentation", replacementRange: NSRange(location: NSNotFound, length: 0))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(150))
        #expect(app.messageQueues[target]?.messages.map(\.text) == ["Also update the documentation"])
        #expect((app.drafts[target] ?? "").isEmpty)
        #expect(app.isRunning(target))
        #expect(app.thread(target).isEmpty)

        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("working"))
        }
        app.show(.home(fixture.bot.id))
        try await Task.sleep(for: .milliseconds(150))
        #expect(app.messageQueues[.home(fixture.bot.id)]?.messages.isEmpty == true)
        #expect(app.status(of: .home(fixture.bot.id))?.phase == .idle)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("idle"))
        }
        app.show(target)
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 820, height: 600))
        try await Task.sleep(for: .milliseconds(200))
        #expect(window.frame.width >= window.contentMinSize.width)
        #expect(app.messageQueues[target]?.messages.count == 1)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("dark-compact"))
        }
    }

    @Test func composerGrowsWithShiftReturnAndPastesQueuedImages() async throws {
        _ = NSApplication.shared
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.runStates[target] = RunState(hasOutput: true)
        app.show(target)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); app.runStates.removeAll() }
        window.contentView = NSHostingView(rootView: ChatView(target: target).environment(app))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        let editor = try #require(window.firstResponder as? ComposerTextView)
        let scroll = try #require(editor.enclosingScrollView)
        let initialHeight = scroll.frame.height
        editor.insertText("first", replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<6 {
            let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            window.sendEvent(enter)
        }
        editor.insertText("last", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        #expect(app.drafts[target] == "first" + String(repeating: "\n", count: 6) + "last")
        #expect(app.messageQueues[target]?.messages.isEmpty != false)
        #expect(scroll.frame.height > initialHeight)
        editor.insertText(String(repeating: "\nmore", count: 30), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        #expect(scroll.frame.height <= 200)
        #expect(scroll.hasVerticalScroller)
        let image = NSImage(size: NSSize(width: 40, height: 20))
        image.lockFocus(); NSColor.systemRed.setFill(); NSRect(x: 0, y: 0, width: 40, height: 20).fill(); image.unlockFocus()
        let bytes = try #require(image.tiffRepresentation)
        // Only an image on the pasteboard, as after a screenshot is copied: a plain-text view turns
        // Edit ▸ Paste (⌘V) off for it, so the composer must keep it on.
        let pasteboard = StandInPasteboard()
        defer { pasteboard.restore() }
        pasteboard.board.setData(bytes, forType: .tiff)
        #expect(editor.validateMenuItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")))
        editor.paste(nil)
        let attachment = try #require(app.draftImages[target]?.first)
        #expect(app.draftImages[.home(fixture.bot.id)] == nil)
        let copy = try Data(contentsOf: fixture.home.imageURL(attachment))
        #expect(NSImage(data: copy) != nil)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            try await Task.sleep(for: .milliseconds(100))
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("composer-images"))
        }
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.messageQueues[target]?.messages.first?.images == [attachment])
        #expect(app.draftImages[target] == nil)
        #expect((app.drafts[target] ?? "").isEmpty)
        #expect(scroll.frame.height == initialHeight)
        let recovered = AppModel(store: fixture.store, settings: fixture.settings)
        let queued = try #require(recovered.messageQueues[target]?.messages.first)
        recovered.editQueuedMessage(queued.id, in: target)
        #expect(recovered.draftImages[target] == [attachment])
        #expect(recovered.drafts[target]?.hasPrefix("first\n") == true)
    }

    @Test func stoppingBeforeImageDeliveryDoesNotLaunchTheCLI() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let image = try fixture.home.saveImage(Data([1, 2, 3]), name: "fixture.png")
        #expect(fixture.app.send("Inspect", to: fixture.taskTarget, images: [image]))
        fixture.app.stop(fixture.taskTarget)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!fixture.app.isRunning(fixture.taskTarget))
        #expect(!FileManager.default.fileExists(atPath: fixture.folder(fixture.taskTarget).appendingPathComponent("calls.jsonl").path))
    }

    @Test func imageOnlyMessagesReachTheCLIAndPreserveTheirTranscript() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 10, height: 10).fill(); image.unlockFocus()
        try fixture.app.addImage(try #require(image.tiffRepresentation), name: "screen.png", to: fixture.taskTarget)
        let images = try #require(fixture.app.draftImages[fixture.taskTarget])
        #expect(fixture.app.send("", to: fixture.taskTarget, images: images))
        try await fixture.wait { !fixture.app.isRunning(fixture.taskTarget) }
        let call = try #require(fixture.calls(fixture.taskTarget).first)
        #expect(call.contains("--image"))
        #expect(call.contains(fixture.home.imageURL(images[0]).path))
        #expect(fixture.home.loadThread(task: fixture.taskTarget.taskID!).first { $0.role == .user }?.images == images)
        #expect(fixture.app.messageQueues[fixture.taskTarget]?.messages.isEmpty == true)
    }

    @Test func followUpsDrainInOrderOnTheirOwnTaskAndResumeItsSession() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        #expect(app.send("WAIT", to: target))
        try await fixture.wait { app.runSettings(of: target)?.resumableSessionID != nil }
        #expect(app.send("second", to: target))
        #expect(app.send("third", to: target))
        #expect(app.thread(target).filter { $0.role == .user }.map(\.text) == ["WAIT"])
        #expect(app.messageQueues[target]?.messages.map(\.text) == ["second", "third"])
        await app.storage.settle()
        #expect(fixture.home.loadQueuedMessages(task: target.taskID).count == 2)
        app.show(.home(fixture.bot.id))
        #expect(app.status(of: .home(fixture.bot.id))?.phase == .idle)
        #expect(app.status(of: fixture.otherTaskTarget)?.phase == .idle)
        #expect(app.status(of: target)?.phase == .working)
        #expect(app.status(of: fixture.bot).phase == .working)
        try fixture.release(target)
        try await fixture.wait { !app.isRunning(target) && app.messageQueues[target]?.messages.isEmpty == true }
        #expect(app.thread(target).filter { $0.role == .user }.map(\.text) == ["WAIT", "second", "third"])
        #expect(app.thread(target).filter { $0.role == .assistant }.map(\.text) == ["reply:WAIT", "reply:second", "reply:third"])
        #expect(app.thread(.home(fixture.bot.id)).allSatisfy { $0.role.isNote })
        #expect(app.runSettings(of: target)?.resumableSessionID == "fixture-session")
        #expect(fixture.home.loadQueuedMessages(task: target.taskID).isEmpty)
        let calls = try fixture.calls(target)
        #expect(calls.count == 3)
        #expect(calls.dropFirst().allSatisfy { $0.prefix(3) == ["exec", "resume", "fixture-session"] })
        #expect(!app.thread(target).contains { $0.role == .error })
    }

    @Test func stopKeepsMessagesAndRelaunchRecoversThemPaused() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.send("WAIT", to: target)
        try await fixture.wait { app.runSettings(of: target)?.resumableSessionID != nil }
        app.send("keep this", to: target)
        app.stop(target)
        try await fixture.wait { !app.isRunning(target) }
        #expect(try fixture.calls(target).count == 1)
        #expect(app.messageQueues[target]?.isPaused == true)
        let recovered = AppModel(store: fixture.store, settings: fixture.settings)
        #expect(recovered.messageQueues[target]?.messages.map(\.text) == ["keep this"])
        #expect(recovered.messageQueues[target]?.isPaused == true)
        #expect(!recovered.isRunning(target))
        recovered.drafts[target] = "a draft already here"
        let id = try #require(recovered.messageQueues[target]?.messages.first?.id)
        recovered.editQueuedMessage(id, in: target)
        #expect(recovered.drafts[target] == "keep this\n\na draft already here")
        await recovered.storage.settle()
        #expect(fixture.home.loadQueuedMessages(task: target.taskID).isEmpty)
    }

    /// #43: quitting BotChu (every deploy restarts it) is not the owner's Stop. Messages left
    /// queued go out on their own after the next launch.
    @Test func relaunchSendsMessagesLeftQueuedWhenBotChuQuit() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.send("WAIT", to: target)
        try await fixture.wait { app.runSettings(of: target)?.resumableSessionID != nil }
        app.send("after relaunch", to: target)
        app.stopAll()
        try await fixture.wait { !app.isRunning(target) }
        #expect(app.messageQueues[target]?.isPaused == false)
        #expect(!fixture.home.loadQueuePaused(task: target.taskID))
        #expect(try fixture.calls(target).count == 1)
        let relaunched = AppModel(store: fixture.store, settings: fixture.settings)
        defer { relaunched.stopAll() }
        #expect(relaunched.messageQueues[target]?.isPaused == false)
        try await fixture.wait { relaunched.thread(target).last?.text == "reply:after relaunch" }
        #expect(relaunched.messageQueues[target]?.messages.isEmpty == true)
        #expect(fixture.home.loadQueuedMessages(task: target.taskID).isEmpty)
        #expect(try fixture.calls(target).count == 2)
    }

    /// #43: a turn that recovers from an error (Codex's reconnects) and finishes, then exits
    /// nonzero, used to pause the queue as if it had failed.
    @Test func turnThatRecoversFromAnErrorStillSendsTheNextMessage() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.send("WAIT FLAKY EXIT3", to: target)
        try await fixture.wait { app.runSettings(of: target)?.resumableSessionID != nil }
        app.send("next", to: target)
        try fixture.release(target)
        try await fixture.wait { !app.isRunning(target) && app.thread(target).last?.text == "reply:next" }
        #expect(app.messageQueues[target]?.messages.isEmpty == true)
        #expect(app.messageQueues[target]?.isPaused == false)
        #expect(try fixture.calls(target).count == 2)
    }

    /// Claude Code takes a follow-up mid-turn, at its next tool call, in the same process; the
    /// message joins the transcript where the CLI took it, and leaves the queue only then.
    @Test(arguments: [false, true]) func claudeTakesAFollowUpAtItsNextToolCall(withImages: Bool) async throws {
        let fixture = try ConversationFixture(accountID: "claude-dev", script: ConversationFixture.claudeScript)
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        #expect(app.takesFollowUpsMidTurn(target))
        let bytes = Data(repeating: 65, count: 300_000)
        let image = try fixture.home.saveImage(bytes, name: "fixture.png")
        app.send("WAIT", to: target, images: withImages ? [image] : [])
        try await fixture.wait { app.runStates[target]?.takesInput == true }
        app.send("steer me", to: target, images: withImages ? [image] : [])
        let id = try #require(app.messageQueues[target]?.messages.first?.id)
        // Written to the CLI once a saved queue holds it.
        try await fixture.wait { app.messageQueues[target]?.isInFlight(id) == true }
        // Already written to the CLI: it can't be taken back into the composer.
        app.editQueuedMessage(id, in: target)
        #expect(app.messageQueues[target]?.messages.count == 1)
        await app.storage.settle()
        #expect(fixture.home.loadQueuedMessages(task: target.taskID).map(\.id) == [id])
        // The tool call ends once the CLI has the follow-up, so it takes it at that call.
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.folder(target).appendingPathComponent("received").path) }
        try fixture.release(target)
        try await fixture.wait { !app.isRunning(target) }
        let thread = app.thread(target).filter { !$0.role.isNote }
        #expect(thread.map(\.role) == [.user, .tool, .user, .assistant])
        #expect(thread.filter { $0.role == .user }.map(\.text) == ["WAIT", "steer me"])
        #expect(thread.last?.text == "steered:steer me")
        if withImages {
            #expect(thread.filter { $0.role == .user }.allSatisfy { $0.images == [image] })
            let payloads = try String(contentsOf: fixture.folder(target).appendingPathComponent("inputs.jsonl"), encoding: .utf8)
            let lines = payloads.split(separator: "\n")
            #expect(lines.count == 2)
            for line in lines {
                let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                let message = try #require(object["message"] as? [String: Any])
                let content = try #require(message["content"] as? [[String: Any]])
                let source = try #require(content.last?["source"] as? [String: String])
                #expect(source["data"].flatMap { Data(base64Encoded: $0) } == bytes)
            }
        }
        #expect(app.messageQueues[target]?.messages.isEmpty == true)
        #expect(fixture.home.loadQueuedMessages(task: target.taskID).isEmpty)
        let calls = try fixture.calls(target)
        #expect(calls.count == 1)
        #expect(calls.first?.contains("--replay-user-messages") == true)
        #expect(!app.thread(target).contains { $0.role == .error })
    }

    /// #77: Claude Code takes a follow-up while the task's transcript can't be saved (its file is
    /// locked). The message stays in the saved queue as taken, the chat says why once, and a
    /// relaunch puts it back into the transcript without running the CLI again.
    @Test func followUpTakenWhileTheTranscriptCantBeSavedSurvivesARelaunch() async throws {
        let fixture = try ConversationFixture(accountID: "claude-dev", script: ConversationFixture.claudeScript)
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget, taskID = try #require(target.taskID)
        let transcript = fixture.home.taskThreadURL(taskID)
        func lock(_ locked: Bool) throws { try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: transcript.path) }
        defer { try? lock(false) }
        app.send("WAIT", to: target)
        try await fixture.wait { app.runStates[target]?.takesInput == true }
        try lock(true)
        app.send("steer me", to: target)
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.folder(target).appendingPathComponent("received").path) }
        try fixture.release(target)
        try await fixture.wait { !app.isRunning(target) }
        #expect(app.thread(target).filter { $0.role == .user }.map(\.text) == ["WAIT", "steer me"])
        let errors = app.thread(target).filter { $0.role == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.text.hasPrefix("Couldn't save this conversation (") == true)
        #expect(app.messageQueues[target]?.messages.isEmpty == true)
        #expect(app.messageQueues[target]?.taken.map(\.text) == ["steer me"])
        await app.storage.settle()
        #expect(fixture.home.loadThread(task: taskID).filter { $0.role == .user }.map(\.text) == ["WAIT"])
        #expect(fixture.home.loadQueuedMessages(task: taskID).isEmpty)
        #expect(fixture.home.loadQueue(delivered: fixture.home.loadThread(task: taskID), task: taskID).taken.map(\.text) == ["steer me"])

        try lock(false)
        let relaunched = AppModel(store: fixture.store, settings: fixture.settings)
        defer { relaunched.stopAll() }
        #expect(relaunched.thread(target).filter { $0.role == .user }.map(\.text) == ["WAIT", "steer me"])
        #expect(relaunched.thread(target).last?.role == .note)
        #expect(relaunched.messageQueues[target]?.messages.isEmpty == true)
        #expect(relaunched.messageQueues[target]?.taken.isEmpty == true)
        #expect(fixture.home.loadThread(task: taskID).filter { $0.role == .user }.map(\.text) == ["WAIT", "steer me"])
        // Launch sends what is still queued once the window is up; nothing is, so the CLI doesn't run.
        try await Task.sleep(for: .milliseconds(200))
        #expect(!relaunched.isRunning(target))
        #expect(try fixture.calls(target).count == 1)
    }

    @Test func failedTurnPausesQueueAndExplicitResumeSendsIt() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.send("WAIT FAIL", to: target)
        try await fixture.wait { app.runSettings(of: target)?.resumableSessionID != nil }
        app.send("try again", to: target)
        try fixture.release(target)
        try await fixture.wait { !app.isRunning(target) }
        #expect(app.messageQueues[target]?.isPaused == true)
        #expect(app.messageQueues[target]?.messages.count == 1)
        app.resumeQueuedMessages(to: target)
        try await fixture.wait { !app.isRunning(target) }
        #expect(app.messageQueues[target]?.messages.isEmpty == true)
        #expect(app.thread(target).last?.text == "reply:try again")
    }

    @Test func simultaneousConversationsKeepTheirOwnQueueAndStopState() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.bot.id), task = fixture.taskTarget
        app.send("WAIT", to: home)
        app.send("WAIT", to: task)
        try await fixture.wait {
            app.runSettings(of: home)?.resumableSessionID != nil && app.runSettings(of: task)?.resumableSessionID != nil
        }
        app.send("home follow-up", to: home)
        app.send("task follow-up", to: task)
        app.stop(home)
        try fixture.release(task)
        try await fixture.wait { !app.isRunning(home) && !app.isRunning(task) }
        #expect(app.messageQueues[home]?.messages.map(\.text) == ["home follow-up"])
        #expect(app.messageQueues[home]?.isPaused == true)
        #expect(app.messageQueues[task]?.messages.isEmpty == true)
        #expect(app.thread(task).last?.text == "reply:task follow-up")
        #expect(!app.thread(home).contains { $0.role == .user && $0.text == "task follow-up" })
        #expect(try fixture.calls(home).count == 1)
        #expect(try fixture.calls(task).count == 2)
    }

    /// #107: the queue is saved off the main thread; a send whose save fails isn't accepted, its
    /// message leaves the queue, the conversation says why, and no CLI runs.
    @Test func failedQueueWriteDoesNotAcceptOrLoseTheDraft() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        let file = fixture.home.taskURL(target.taskID!).appendingPathComponent("queued.jsonl")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        app.runStates[target] = RunState()
        app.drafts[target] = "Keep my draft"
        let accepted = await app.sendAccepted("Keep my draft", to: target)
        #expect(!accepted)
        #expect(app.messageQueues[target]?.messages.isEmpty == true)
        #expect(app.drafts[target] == "Keep my draft")
        #expect(app.thread(target).last?.role == .error)
        app.runStates.removeAll()
        // Idle, the send is refused the same way, and nothing starts.
        #expect(!(await app.sendAccepted("Still not saved", to: target)))
        #expect(app.messageQueues[target]?.messages.isEmpty == true)
        #expect(!app.isRunning(target))
        #expect(!FileManager.default.fileExists(atPath: fixture.folder(target).appendingPathComponent("calls.jsonl").path))
    }

    @Test func queuedMessagesDuringPreparationCanBeStoppedWithoutStarting() throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.runStates[target] = RunState(preparing: true)
        app.send("after setup", to: target)
        app.resumeQueuedMessages(to: target)
        #expect(app.runStates[target]?.preparing == true)
        app.stop(target)
        #expect(!app.isRunning(target))
        #expect(app.messageQueues[target]?.messages.map(\.text) == ["after setup"])
        #expect(app.messageQueues[target]?.isPaused == true)
        #expect(app.thread(target).allSatisfy { $0.role.isNote })
    }

    /// #46: a reply streaming into a task doesn't invalidate anything a view of another
    /// conversation reads, nor the task's own status (its sidebar row) while only its text grows.
    @Test func streamingIntoATaskLeavesOtherConversationsAndItsStatusAlone() async throws {
        let fixture = try ConversationFixture(accountID: "claude-dev", script: ConversationFixture.streamScript)
        defer { fixture.cleanUp() }
        let app = fixture.app, shown = ChatTarget.home(fixture.bot.id), streaming = fixture.taskTarget
        app.show(shown)
        #expect(app.send("STREAM", to: streaming))
        try await fixture.wait { app.thread(streaming).last?.text.hasPrefix("first") == true }
        let shownChanged = Flag(), otherTaskChanged = Flag(), statusChanged = Flag(), threadChanged = Flag()
        withObservationTracking {
            _ = app.thread(shown)
            _ = app.runStates[shown]?.preparing
            _ = app.isRunning(shown)
            _ = app.messageQueues[shown]
            _ = app.reactions[shown]
            _ = app.status(of: shown)
        } onChange: { shownChanged.set() }
        withObservationTracking {
            _ = app.thread(fixture.otherTaskTarget)
            _ = app.status(of: fixture.otherTaskTarget)
        } onChange: { otherTaskChanged.set() }
        withObservationTracking { _ = app.status(of: streaming) } onChange: { statusChanged.set() }
        withObservationTracking { _ = app.thread(streaming) } onChange: { threadChanged.set() }
        try fixture.release(streaming)
        try await fixture.wait { app.thread(streaming).last?.text.contains("token199") == true }
        #expect(threadChanged.value)
        #expect(!shownChanged.value)
        #expect(!otherTaskChanged.value)
        #expect(!statusChanged.value)
        try Data().write(to: fixture.folder(streaming).appendingPathComponent("finish"))
        try await fixture.wait { !app.isRunning(streaming) }
        #expect(app.thread(streaming).filter { $0.role == .assistant }.map(\.text).first?.hasSuffix("token199") == true)
    }

    /// #46: quitting mid-turn saves what the turn streamed so far; the turn's end would have.
    @Test func quittingMidTurnKeepsWhatTheTurnStreamed() async throws {
        let fixture = try ConversationFixture(accountID: "claude-dev", script: ConversationFixture.streamScript)
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        #expect(app.send("STREAM", to: target))
        try fixture.release(target)
        try await fixture.wait { app.thread(target).last?.text.contains("token199") == true }
        app.stopAll()
        let saved = fixture.home.loadThread(task: try #require(target.taskID))
        #expect(saved.first?.text == "STREAM")
        #expect(saved.last?.text.contains("token199") == true)
    }

    @Test func profileActivityAndReactionsAreScopedToTheirConversation() throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.bot.id), target = fixture.taskTarget
        app.reactions.removeAll()
        app.runStates[target] = RunState(hasOutput: true, activity: .coding)
        for selected in [home, fixture.otherTaskTarget, target, home] {
            app.show(selected)
            #expect(app.tab(of: fixture.bot.id) == selected)
            #expect(app.status(of: selected)?.phase == (selected == target ? .working : .idle))
            #expect(app.status(of: selected)?.activity == (selected == target ? .coding : .idle))
        }
        app.runStates[target] = nil
        app.react(.done, for: target, seconds: 3)
        #expect(app.status(of: target)?.activity == .done)
        #expect(app.status(of: home)?.activity == .idle)
        app.runStates[home] = RunState(hasOutput: true)
        #expect(app.status(of: target)?.phase == .idle)
        #expect(app.status(of: fixture.otherTaskTarget)?.phase == .idle)
        app.runStates.removeAll()
    }
}

/// Whether an observation fired.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
    func set() {
        lock.lock()
        fired = true
        lock.unlock()
    }
}

/// A real child process with deterministic streaming and interruption, on isolated bot data.
/// The lock directory makes overlapping CLI processes fail, and the SIGINT tail checks draining.
@MainActor private final class ConversationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-conversation-\(UUID().uuidString)")
    let domain = "local.BotChu.ConversationTests.\(UUID().uuidString)"
    let store: Store
    let settings: AppSettings
    let bot: Bot
    let home: BotHome
    let app: AppModel
    let taskTarget: ChatTarget
    let otherTaskTarget: ChatTarget

    init(accountID: String = "codex-dev", script source: String = ConversationFixture.script) throws {
        store = Store(root: root.appendingPathComponent("index"))
        settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        bot = Bot(name: "Fixture", accountID: accountID, workspace: root.appendingPathComponent("bot").path)
        home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        let script = root.appendingPathComponent("cli.py")
        try source.write(to: script, atomically: true, encoding: .utf8)
        settings.commands[bot.accountID] = "/usr/bin/python3 \(Shell.quote(script.path))"
        var task = BotTask(for: bot, repo: "fixture/repo", checkout: root.path, work: nil, brief: "Test")
        task.folder = root.appendingPathComponent("task").path
        try FileManager.default.createDirectory(atPath: task.folder!, withIntermediateDirectories: true)
        try home.save(task)
        taskTarget = .task(task.id, of: bot.id)
        let other = BotTask(for: bot, repo: "fixture/other", checkout: root.path, work: nil, brief: "Other")
        try home.save(other)
        otherTaskTarget = .task(other.id, of: bot.id)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
    }

    func folder(_ target: ChatTarget) -> URL {
        URL(fileURLWithPath: app.task(target)?.folder ?? bot.workspace)
    }
    func release(_ target: ChatTarget) throws {
        try Data().write(to: folder(target).appendingPathComponent("release"))
    }
    func calls(_ target: ChatTarget) throws -> [[String]] {
        let text = try String(contentsOf: folder(target).appendingPathComponent("calls.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for the fixture process")
        throw CocoaError(.executableLoad)
    }
    func cleanUp() {
        app.stopAll()
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    static let script = #"""
    import json, os, signal, sys, time
    from pathlib import Path
    def emit(value):
        print(json.dumps(value), flush=True)
    def reply(text):
        emit({"type":"item.completed", "item":{"type":"agent_message", "text":text}})
    try:
        os.mkdir("active")
    except FileExistsError:
        emit({"type":"turn.failed", "error":{"message":"Overlapping processes"}})
        sys.exit(1)
    def interrupt(signum, frame):
        time.sleep(0.05)
        reply("interrupted tail")
        os.rmdir("active")
        sys.exit(130)
    signal.signal(signal.SIGINT, interrupt)
    with open("calls.jsonl", "a") as file:
        file.write(json.dumps(sys.argv[1:]) + "\n")
    emit({"type":"thread.started", "thread_id":"fixture-session"})
    prompt = sys.argv[-1]
    if "FLAKY" in prompt:
        # Codex reports problems it recovers from, such as a dropped stream, as errors.
        emit({"type":"error", "message":"Reconnecting... 1/5"})
    if "WAIT" in prompt:
        while not Path("release").exists():
            time.sleep(0.02)
    if "FAIL" in prompt:
        emit({"type":"turn.failed", "error":{"message":"Fixture failure"}})
    else:
        # Fresh sessions contain a preamble; the actual request is its final line.
        reply("reply:" + prompt.splitlines()[-1])
        emit({"type":"turn.completed"})
    os.rmdir("active")
    if "EXIT3" in prompt:
        sys.exit(3)
    """#

    /// Claude Code streaming a reply: its first word, then, once released, 200 more in bursts; it
    /// ends once told to finish.
    static let streamScript = #"""
    import json, sys, time
    from pathlib import Path
    def emit(value):
        print(json.dumps(value), flush=True)
    def event(value):
        emit({"type":"stream_event", "event":value, "parent_tool_use_id":None})
    with open("calls.jsonl", "a") as file:
        file.write(json.dumps(sys.argv[1:]) + "\n")
    emit({"type":"system", "subtype":"init", "session_id":"claude-stream"})
    first = json.loads(sys.stdin.readline())
    first.update({"session_id": "claude-stream", "parent_tool_use_id": None, "isReplay": True})
    emit(first)
    event({"type":"message_start", "message":{"id":"m1"}})
    event({"type":"content_block_start", "index":0, "content_block":{"type":"text"}})
    event({"type":"content_block_delta", "index":0, "delta":{"type":"text_delta", "text":"first "}})
    while not Path("release").exists():
        time.sleep(0.02)
    for i in range(200):
        event({"type":"content_block_delta", "index":0, "delta":{"type":"text_delta", "text":"token%d " % i}})
        if i % 10 == 9:
            time.sleep(0.01)
    while not Path("finish").exists():
        time.sleep(0.02)
    event({"type":"content_block_stop", "index":0})
    emit({"type":"result", "subtype":"success", "is_error":False, "result":"ok"})
    """#

    /// Claude Code with `--input-format stream-json --replay-user-messages`: messages on stdin,
    /// each echoed when taken; one written during a tool call is taken after its result; the CLI
    /// ends when stdin closes.
    static let claudeScript = #"""
    import json, os, select, sys, time
    from pathlib import Path
    def emit(value):
        print(json.dumps(value), flush=True)
    buffer = b""
    def read_line(timeout=None):
        global buffer
        while b"\n" not in buffer:
            ready, _, _ = select.select([0], [], [], timeout)
            if not ready:
                return None
            chunk = os.read(0, 65536)
            if not chunk:
                return ""
            buffer += chunk
        line, buffer = buffer.split(b"\n", 1)
        return line.decode()
    def text(line):
        return json.loads(line)["message"]["content"][0]["text"]
    def replay(line):
        with open("inputs.jsonl", "a") as file:
            file.write(line + "\n")
        value = json.loads(line)
        value.update({"session_id": "claude-fixture", "parent_tool_use_id": None, "isReplay": True})
        emit(value)
    def say(words):
        emit({"type":"assistant", "message":{"id":"m" + str(time.time()), "role":"assistant",
              "content":[{"type":"text", "text":words}]}, "parent_tool_use_id":None})
    def result():
        emit({"type":"result", "subtype":"success", "is_error":False, "result":"ok"})
    with open("calls.jsonl", "a") as file:
        file.write(json.dumps(sys.argv[1:]) + "\n")
    emit({"type":"system", "subtype":"init", "session_id":"claude-fixture"})
    first = read_line()
    replay(first)
    prompt = text(first).splitlines()[-1]
    if "WAIT" in prompt:
        emit({"type":"assistant", "message":{"id":"m1", "role":"assistant", "content":[{"type":"tool_use",
              "id":"toolu_1", "name":"Bash", "input":{"command":"sleep 1"}}]}, "parent_tool_use_id":None})
        pending = []
        while not Path("release").exists():
            line = read_line(0.02)
            if line:
                pending.append(line)
                Path("received").touch()
        emit({"type":"user", "message":{"role":"user", "content":[{"tool_use_id":"toolu_1", "type":"tool_result",
              "content":"done", "is_error":False}]}, "parent_tool_use_id":None})
        for line in pending:
            replay(line)
            say("steered:" + text(line))
    else:
        say("reply:" + prompt)
    result()
    while True:
        line = read_line()
        if not line:
            break
        replay(line)
        say("reply:" + text(line))
        result()
    """#
}
