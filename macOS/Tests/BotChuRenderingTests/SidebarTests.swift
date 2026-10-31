import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func oneConversationsActivityOnlyReevaluatesItsSidebarRow() async throws {
        _ = NSApplication.shared
        let fixture = try InboxStatusFixture()
        defer { fixture.cleanUp() }
        try await fixture.ready()
        let app = fixture.app, changed = fixture.targets[1]
        app.destination = .projects
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 1_400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        var bodies: [UUID: Int] = [:], derivations: [UUID: Int] = [:]
        SidebarStatusDiagnostics.didEvaluateRow = { bodies[$0, default: 0] += 1 }
        SidebarStatusDiagnostics.didDeriveSummary = { derivations[$0, default: 0] += 1 }
        defer {
            SidebarStatusDiagnostics.didEvaluateRow = nil
            SidebarStatusDiagnostics.didDeriveSummary = nil
        }
        window.contentView = NSHostingView(rootView: SidebarView().environment(app).defaultAppStorage(fixture.defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
        #expect(bodies[changed.botID, default: 0] > 0)
        bodies.removeAll(); derivations.removeAll()
        let regroupings = app.inbox.statusDerivations
        app.runStates[changed] = RunState(hasOutput: true, activity: .coding)
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        #expect(bodies[changed.botID, default: 0] > 0)
        #expect(derivations[changed.botID, default: 0] > 0)
        #expect(bodies.keys.allSatisfy { $0 == changed.botID }, "Unrelated row bodies stay untouched: \(bodies)")
        #expect(derivations.keys.allSatisfy { $0 == changed.botID }, "Unrelated statuses stay untouched: \(derivations)")
        #expect(app.inbox.statusDerivations == regroupings)
        let activityRows = bodies.count, activityDerivations = derivations.values.reduce(0, +)

        bodies.removeAll(); derivations.removeAll()
        let delivery = try #require(fixture.deliveries.first { $0.taskID == changed.taskID && $0.purpose == .needsInput })
        app.inbox.setDone(delivery.id, true)
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        #expect(bodies[changed.botID, default: 0] > 0)
        #expect(bodies.keys.allSatisfy { $0 == changed.botID })
        #expect(derivations.keys.allSatisfy { $0 == changed.botID })
        #expect(app.inbox.statusDerivations == regroupings + 1)

        // Unread dots and task lists are observed by conversation and by bot, as activity is (#340).
        let inboxRows = bodies.count, inboxDerivations = derivations.values.reduce(0, +)
        let other = fixture.bots[5].id
        let changes: [(name: String, botID: UUID, change: () -> Void)] = [
            ("unread", changed.botID, { app.unread.insert(changed) }),
            ("task metadata", changed.botID, { app.tasks[changed.botID]?[0].title = "Renamed task" }),
            ("new task", other, { app.tasks[other, default: []].append(BotTask(title: "New", repo: "fixture/repo", checkout: "/")) }),
        ]
        var counters: [String] = []
        for (name, botID, change) in changes {
            bodies.removeAll(); derivations.removeAll()
            change()
            try await Task.sleep(for: .milliseconds(200))
            window.layoutIfNeeded()
            #expect(bodies[botID, default: 0] > 0, "\(name) redraws its bot's row")
            #expect(bodies.keys.allSatisfy { $0 == botID }, "\(name) leaves the other rows untouched: \(bodies)")
            #expect(derivations.keys.allSatisfy { $0 == botID }, "\(name) leaves the other statuses untouched: \(derivations)")
            counters.append("\(name) \(bodies.count)/\(derivations.values.reduce(0, +))")
        }
        #expect(app.inbox.statusDerivations == regroupings + 1, "Metadata and unread changes never regroup the Inbox")
        print("#271 sidebar counters (rows / summary derivations): activity \(activityRows)/\(activityDerivations), Inbox question \(inboxRows)/\(inboxDerivations), \(counters.joined(separator: ", "))")
    }
}

