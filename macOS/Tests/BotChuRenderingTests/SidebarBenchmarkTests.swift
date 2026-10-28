import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// Run on both revisions with the same fixture, through the window gate. This file and
/// InboxStatusFixture.swift also compile on the pre-cache revision for a real before/after pair.
extension RenderingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTCHU_SIDEBAR_BENCHMARK"] != nil))
    func sidebarStatusBenchmark() async throws {
        _ = NSApplication.shared
        let fixture = try InboxStatusFixture()
        defer { fixture.cleanUp() }
        try await fixture.ready()
        let app = fixture.app
        for target in fixture.targets { _ = await app.loadedThread(target) }
        let active = [1, 6, 11, 16].map { fixture.targets[$0] }
        for target in active { app.runStates[target] = RunState(hasOutput: true, activity: .coding) }
        app.show(fixture.targets[0])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_240, height: 820),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(fixture.defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        func draw() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func milliseconds(since start: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        var report = ChatBenchReport()
        report.note("20 bots, 80 tasks, 2000 deliveries, 4 active tasks; warm histories; 30 samples; \(ProcessInfo.processInfo.operatingSystemVersionString)")
        report.note("Load before: \(ChatBenchReport.load())")
        var navigation: [Double] = [], typing: [Double] = [], activity: [Double] = []
        for index in 0..<30 {
            var start = DispatchTime.now().uptimeNanoseconds
            app.show(fixture.targets[index.isMultiple(of: 2) ? 0 : 2])
            draw()
            navigation.append(milliseconds(since: start))
            try await Task.sleep(for: .milliseconds(40))
            start = DispatchTime.now().uptimeNanoseconds
            app.runStates[active[1]] = RunState(hasOutput: true, activity: index.isMultiple(of: 2) ? .thinking : .coding)
            draw()
            activity.append(milliseconds(since: start))
            let editor = try #require(sidebarBenchmarkEditor(in: window.contentView!))
            window.makeFirstResponder(editor)
            start = DispatchTime.now().uptimeNanoseconds
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
            window.sendEvent(key)
            draw()
            typing.append(milliseconds(since: start))
            #expect(editor.string.hasSuffix("x"))
            try await Task.sleep(for: .milliseconds(40))
        }
        report.add("Switch conversation and draw", navigation)
        report.add("Activity update and draw", activity)
        report.add("Keystroke and draw", typing)
        report.note("Load after: \(ChatBenchReport.load())")
        let text = report.text(title: "#271 Sidebar status benchmark")
        print(text)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_SIDEBAR_BENCHMARK"], path.hasPrefix("/") {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

@MainActor private func sidebarBenchmarkEditor(in view: NSView) -> ComposerTextView? {
    (view as? ComposerTextView) ?? view.subviews.lazy.compactMap { sidebarBenchmarkEditor(in: $0) }.first
}
