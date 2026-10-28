import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// What a stand-in filer was given, in place of gh: no test files a real issue.
private actor Filings {
    private(set) var all: [(title: String, body: String, images: [Data])] = []
    func add(_ title: String, _ body: String, _ images: [Data]) { all.append((title, body, images)) }
}

/// A stand-in for the window's screenshot, so no test captures the screen for a report: the windows
/// it was asked for, whether a sheet covered each then, and a picture of its own each time (or, when
/// it `fails`, why there is none).
@MainActor private final class Captures {
    private(set) var windows: [NSWindow] = []
    private(set) var covered: [Bool] = []
    private(set) var pictures: [Data] = []
    var fails = false

    func capture(_ window: NSWindow) throws -> Data {
        windows.append(window)
        covered.append(window.attachedSheet != nil)
        if fails { throw ImageDelivery.Failure("The window isn't on screen.") }
        let colors: [NSColor] = [.systemTeal, .systemPurple, .systemYellow]
        let picture = try png(colors[pictures.count % colors.count])
        pictures.append(picture)
        return picture
    }

    private func png(_ color: NSColor) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 26, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 26).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}

extension RenderingTests {
    /// Report a Bug or Feature, from the toolbar: it opens with a screenshot of its window, taken
    /// before the sheet covers it; its app state leaves the bot's name, folder and conversation out;
    /// a pasted screenshot goes with the report; ⌘Return files it; one that isn't filed stays, with
    /// its images and why, and is tried again without another screenshot, or without the window's
    /// once it is removed; once filed, the sheet gives the issue's link (and says when an image didn't
    /// make it), and Done closes it. The next report takes a new screenshot, and one that can't be
    /// taken leaves the report to go without it, saying so.
    @Test func reportSheetFilesTheReportOrKeepsItWithWhy() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-report-\(UUID().uuidString)")
        let domain = "local.BotChu.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        defaults.set(root.appendingPathComponent("bots").path, forKey: "botsRoot")
        let bot = Bot(name: "Secret Scout", workspace: root.appendingPathComponent("bots/secret-scout").path)
        let store = Store(root: root.appendingPathComponent("Support"))
        try BotHome(workspace: bot.workspace).save(bot)
        try BotHome(workspace: bot.workspace).saveThread([ChatMessage(role: .user, text: "The vault code is hunter2."),
                                                          ChatMessage(role: .assistant, text: "Noted.")])
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let model = AppModel(store: store, settings: AppSettings(defaults: defaults),
                             usage: UsageCache { _, _ in throw UsageFailure("No usage in tests") })
        let filings = Filings()
        model.issueFiler = IssueFiler { title, body, images in
            await filings.add(title, body, images)
            return .failed("gh couldn't create the issue:\nHTTP 401: Bad credentials")
        }
        let captures = Captures()
        model.windowCapture = { window in try captures.capture(window) }
        let host = NSHostingView(rootView: ContentView().environment(model).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        // As SwiftUI names the app's main windows, which reports are made from.
        window.identifier = NSUserInterfaceItemIdentifier("main-report-test")
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await waitForReport {
            window.isVisible && window.toolbar?.items.contains { $0.label == "Report a Bug or Feature" } == true
                && model.thread(.home(bot.id)).count == 2
        }

        // The toolbar's button opens the sheet.
        let item = try #require(window.toolbar?.items.first { $0.label == "Report a Bug or Feature" })
        #expect(item.toolTip?.contains("public issue") == true)
        let view = try #require(item.view)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                clickCount: 1, pressure: 1)!)
        }
        try await waitForReport { window.attachedSheet?.isVisible == true && window.attachedSheet?.firstResponder is NSTextView }
        let sheet = try #require(window.attachedSheet)
        let request = try #require(model.issueReport)
        #expect(!model.canReportIssue)
        // The window's screenshot was taken once, of this window, before the sheet covered it, and
        // is the report's first image, which can be removed.
        #expect(captures.windows.count == 1)
        #expect(captures.windows.first === window)
        #expect(captures.covered == [false])
        #expect(request.hasScreenshot && request.screenshotProblem == nil)
        #expect(request.images.images.map(\.name) == [IssueReportRequest.screenshotName])
        #expect(request.images.images.first?.png == captures.pictures.first)
        #expect(request.images.images.first?.preview != nil)
        let state = request.snapshot.lines.joined(separator: "\n")
        #expect(state.contains("Conversation: Home; 2 messages, 0 tool calls"))
        #expect(state.contains("Bots: 1, no turns running"))
        for secret in ["Secret Scout", "secret-scout", root.path, "hunter2", "Noted"] {
            #expect(!state.contains(secret), "“\(secret)” would reach the issue")
        }

        let editor = try #require(sheet.firstResponder as? NSTextView)
        let report = "The sidebar flickers.\n\nIt happens when a task starts."
        editor.insertText(report, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitForReport { request.text == report && request.canSubmit }
        #expect(request.text == report)
        #expect(request.title == "The sidebar flickers")
        #expect(request.visibility == "Public issue with screenshot")
        // A title typed in its field names the issue; left empty, the first line does (#232).
        request.typedTitle = "Sidebar flicker"
        #expect(request.title == "Sidebar flicker")
        request.typedTitle = ""
        #expect(request.title == "The sidebar flickers")
        // Only a screenshot on the pasteboard: Edit ▸ Paste stays on, and the image goes after the text.
        let pasteboard = StandInPasteboard()
        defer { pasteboard.restore() }
        let picture = NSImage(size: NSSize(width: 24, height: 16))
        picture.lockFocus(); NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: 24, height: 16).fill(); picture.unlockFocus()
        pasteboard.board.clearContents()
        pasteboard.board.setData(try #require(picture.tiffRepresentation), forType: .tiff)
        #expect(editor.validateMenuItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")))
        editor.paste(nil)
        #expect(request.images.images.count == 2)
        #expect(request.visibility == "Public issue with screenshot and 1 image")
        #expect(editor.string == report)
        try await waitForReport { request.images.images.count == 2 && editor.isEditable }
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("report-sheet"))
        }
        try await sendReportKey("\r", code: 36, modifiers: .command, to: sheet)
        try await waitForReport {
            request.state == .failed("gh couldn't create the issue:\nHTTP 401: Bad credentials") && editor.isEditable
        }
        #expect(request.state == .failed("gh couldn't create the issue:\nHTTP 401: Bad credentials"))
        #expect(editor.string == report)
        #expect(window.attachedSheet === sheet)
        let filed = await filings.all
        #expect(filed.count == 1)
        #expect(filed.first?.title == "The sidebar flickers")
        #expect(filed.first?.body == IssueReport.body(report: report, images: 2, snapshot: request.snapshot))
        #expect(filed.first?.images.count == 2)
        #expect(filed.first?.images.first == captures.pictures.first)
        #expect(filed.first?.images.last.flatMap(NSImage.init(data:)) != nil)
        #expect(request.images.images.count == 2)
        #expect(captures.windows.count == 1)

        // The window's screenshot removed, it is tried again without it, and isn't taken again:
        // it is filed, though gh couldn't upload the other image; the sheet links the issue and
        // says so, and Done closes it.
        request.images.remove(try #require(request.images.images.first?.id))
        #expect(!request.hasScreenshot)
        let retried = Filings()
        let partly = IssueFiler.Outcome.filed(URL(string: "https://github.com/asieke/BotChu/issues/52"),
                                              problem: "Not every image was attached:\nfailed to upload ./image-1.png: unexpected EOF")
        model.issueFiler = IssueFiler { title, body, images in
            await retried.add(title, body, images)
            return partly
        }
        try await sendReportKey("\r", code: 36, modifiers: .command, to: sheet)
        try await waitForReport {
            if case .filed = request.state { return editor.window == nil }
            return false
        }
        let again = await retried.all
        #expect(again.count == 1)
        #expect(again.first?.images.count == 1)
        #expect(again.first?.images.first != captures.pictures.first)
        #expect(again.first?.body == IssueReport.body(report: report, images: 1, snapshot: request.snapshot))
        #expect(captures.windows.count == 1)
        #expect(request.state == .filed(URL(string: "https://github.com/asieke/BotChu/issues/52"),
                                        problem: "Not every image was attached:\nfailed to upload ./image-1.png: unexpected EOF"))
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("report-filed"))
        }
        try await sendReportKey("\r", code: 36, to: sheet)
        try await waitForReport { model.issueReport == nil && window.attachedSheet == nil }
        #expect(model.issueReport == nil)
        #expect(window.attachedSheet == nil)
        #expect(model.canReportIssue)

        // A gallery's report says which, with a screenshot of its own; Escape closes the sheet
        // without filing.
        model.destination = .projects
        model.reportIssue()
        try await waitForReport { window.attachedSheet?.isVisible == true && window.attachedSheet?.firstResponder is NSTextView }
        let gallery = try #require(window.attachedSheet)
        #expect(model.issueReport?.snapshot.lines.contains("Screen: Projects") == true)
        #expect(model.issueReport?.snapshot.lines.contains { $0.hasPrefix("Conversation:") } == false)
        #expect(captures.windows.count == 2 && captures.covered == [false, false])
        #expect(captures.pictures.count == 2 && captures.pictures[0] != captures.pictures[1])
        #expect(model.issueReport?.images.images.map(\.png) == [captures.pictures[1]])
        try await sendReportKey("\u{1B}", code: 53, to: gallery)
        try await waitForReport { model.issueReport == nil && window.attachedSheet == nil }
        #expect(model.issueReport == nil)
        #expect(await filings.all.count == 1)
        #expect(await retried.all.count == 1)

        // When the screenshot can't be taken, the sheet opens without one and says so, and the
        // report goes as text.
        captures.fails = true
        let textOnly = Filings()
        model.issueFiler = IssueFiler { title, body, images in
            await textOnly.add(title, body, images)
            return .filed(URL(string: "https://github.com/asieke/BotChu/issues/53"))
        }
        model.reportIssue(text: "Add a dark icon.")
        try await waitForReport { window.attachedSheet?.isVisible == true && window.attachedSheet?.firstResponder is NSTextView }
        let plain = try #require(window.attachedSheet)
        let failed = try #require(model.issueReport)
        #expect(captures.windows.count == 3)
        #expect(failed.images.images.isEmpty && !failed.hasScreenshot)
        #expect(failed.screenshotProblem == "The window isn't on screen.")
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("report-no-screenshot"))
        }
        try await sendReportKey("\r", code: 36, modifiers: .command, to: plain)
        try await waitForReport {
            if case .filed = failed.state { return !(plain.firstResponder is NSTextView) }
            return false
        }
        #expect(failed.state == .filed(URL(string: "https://github.com/asieke/BotChu/issues/53")))
        #expect(await textOnly.all.map(\.images.count) == [0])
        try await sendReportKey("\r", code: 36, to: plain)
        try await waitForReport { model.issueReport == nil && window.attachedSheet == nil }
        #expect(model.issueReport == nil)
    }

    /// A window's screenshot is the window as the window server shows it, through ScreenCaptureKit,
    /// at its pixels up to the edge limit, without asking for Screen Recording; a window that isn't
    /// shown has none; and one that never comes is given up on.
    @Test func aWindowsScreenshotIsTheWindowAsItShows() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1).cgColor
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))

        let png = try await WindowCapture.screen(window)
        let rep = try #require(NSBitmapImageRep(data: png))
        let size = IssueReport.screenshotSize(width: window.frame.width, height: window.frame.height, scale: window.backingScaleFactor)
        #expect(abs(rep.pixelsWide - size.width) <= 2 && abs(rep.pixelsHigh - size.height) <= 2, "\(rep.pixelsWide) × \(rep.pixelsHigh)")
        let center = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        // Orange, through the display's color profile: not blank, white, black or grey.
        #expect(center.redComponent > 0.85 && (0.35...0.75).contains(center.greenComponent) && center.blueComponent < 0.4, "\(center)")

        window.orderOut(nil)
        await #expect(throws: (any Error).self) { try await WindowCapture.screen(window) }
        let started = ContinuousClock.now
        let never = await WindowCapture.take(window, with: { _ in
            try await Task.sleep(for: .seconds(30))
            return Data()
        }, timeout: .milliseconds(200))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect((try? never.get()) == nil)
        if case .failure(let error) = never { #expect(error.localizedDescription == "Taking it took too long.") }
        let none = await WindowCapture.take(nil, with: { _ in Data() })
        #expect((try? none.get()) == nil)
    }

    private func sendReportKey(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow) async throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: text,
                                                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        // SwiftUI updates its enabled keyboard shortcuts on the next render. Wait for that
        // actual shortcut to handle the event instead of sleeping or dropping it into the editor.
        try await waitForReport { window.performKeyEquivalent(with: event) }
    }

    private func waitForReport(line: Int = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "The report sheet reached the expected state at line \(line)")
    }

    private static func sendKey(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: text,
                                     charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }
}
