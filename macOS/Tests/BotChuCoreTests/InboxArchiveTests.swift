import Foundation
import Testing
@testable import BotChuCore

@Suite struct InboxArchiveTests {
    private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

    @Test func doneLeavesTheListExactly24HoursAfterItWasHandled() throws {
        // A week-old delivery handled now remains for a full day, irrespective of its sent date.
        let delivery = Delivery(botID: UUID(), title: "Old report", sentAt: now.addingTimeInterval(-7 * 86_400))
        var state = InboxState()
        state.setDone(delivery.id, true, at: now)
        let cutoff = now.addingTimeInterval(86_400)
        #expect(state[delivery.id].doneAt == now && state[delivery.id].read)
        #expect(InboxList.groups([delivery], state: state, now: cutoff.addingTimeInterval(-0.001)).first?.ids == [delivery.id])
        #expect(InboxList.groups([delivery], state: state, now: cutoff).isEmpty)
        #expect(InboxList.groups([delivery], state: state, now: cutoff.addingTimeInterval(1)).isEmpty)
        #expect(state.unfinishedCount([delivery]) == 0 && state.unreadCount([delivery]) == 0)

        // A repeat action and merely reading it never restart its clock.
        state.setDone(delivery.id, true, at: cutoff)
        state[delivery.id].read = false
        #expect(state[delivery.id].doneAt == now)
        #expect(InboxList.isArchived(delivery, state: state, now: cutoff))
        let decoded = try Store.decoder.decode(InboxState.self, from: Store.encoder.encode(state))
        #expect(decoded == state && InboxList.groups([delivery], state: decoded, now: cutoff).isEmpty)
    }

    @Test func legacyDoneUsesItsReplyOrLastDeliveryWithoutRewritingAnything() throws {
        let report = Delivery(botID: UUID(), title: "Old", sentAt: now.addingTimeInterval(-86_400))
        let answer = Delivery(botID: UUID(), title: "Answered", sentAt: now.addingTimeInterval(-3 * 86_400))
        let data = Data("""
            {"entries": {
              "\(report.id)": {"read": true, "done": true},
              "\(answer.id)": {"read": true, "done": true, "repliedAt": "\(ISO8601DateFormatter().string(from: now))"}
            }}
            """.utf8)
        let state = try Store.decoder.decode(InboxState.self, from: data)
        #expect(state[report.id].doneAt == nil && state[answer.id].doneAt == nil)
        #expect(InboxList.isArchived(report, state: state, now: now))
        #expect(!InboxList.isArchived(answer, state: state, now: now))
        #expect(InboxList.groups([report, answer], state: state, now: now).first?.ids == [answer.id])
        #expect(InboxList.groups([report, answer], state: state, now: now.addingTimeInterval(86_400)).isEmpty)
        #expect(state.doneDate(of: answer) == now)
    }

    @Test func reopenedRenewedAndAnsweredDeliveriesKeepTheirSemantics() {
        let asking = Delivery(botID: UUID(), title: "Which?", question: .init(text: "Which?"), sentAt: now)
        var state = InboxState()
        state.answer(asking.id, at: now)
        let later = now.addingTimeInterval(2 * 86_400)
        #expect(InboxList.groups([asking], state: state, now: later).isEmpty)
        state.setDone(asking.id, false, at: later)
        #expect(state[asking.id].doneAt == nil && state.isAnswered(asking) && !state.needsAnswer(asking))
        #expect(InboxList.groups([asking], state: state, now: later).first?.ids == [asking.id])
        state.setDone(asking.id, true, at: later)
        #expect(state[asking.id].doneAt == later && !InboxList.isArchived(asking, state: state, now: later))

        var update = asking
        update.updatedAt = later.addingTimeInterval(1)
        let same = Delivery.resent(update, replacing: asking)
        state.received(same.delivery.id, renewed: same.renewed, shown: false)
        #expect(state[asking.id].doneAt == later && state.isAnswered(same.delivery))
        update.note = "The options changed"
        let changed = Delivery.resent(update, replacing: asking)
        state.received(changed.delivery.id, renewed: changed.renewed, shown: false)
        #expect(state[asking.id].doneAt == nil && !state[asking.id].done)
        #expect(state.needsInput(changed.delivery) && state.isUnread(changed.delivery))
        #expect(InboxList.groups([changed.delivery], state: state, now: later).first?.section == .needsInput)
    }

    @Test func archiveSearchFindsSavedMetadataWithoutChangingStateOrCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-archive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = InboxFolder(home: BotHome(workspace: root.path))
        let contents = Data("# Evidence kept".utf8)
        let report = Delivery(botID: UUID(), title: "Café release", note: "The deployment is finished.",
                              files: [.init(name: "evidence.md", kind: .document, bytes: contents.count)],
                              links: [.init(repo: "asieke/BotChu", number: 275, isPullRequest: true)],
                              question: .init(text: "Ship the next one?", choices: ["Wait until Monday"]),
                              credits: [.init(botID: UUID(), name: "Research Assistant")], sentAt: now)
        try folder.save(report, contents: ["evidence.md": contents])
        var state = InboxState()
        state.answer(report.id, at: now)
        try state.save(to: root)
        let saved = InboxState.load(from: root)
        let deliveries = folder.load(), later = now.addingTimeInterval(2 * 86_400)
        #expect(InboxList.groups(deliveries, state: saved, now: later).isEmpty)
        for query in [" CAFÉ ", "deployment", "evidence.md", "BotChu#275", "Ship the next", "Monday", "Research Assistant"] {
            let groups = InboxList.groups(deliveries, state: saved, now: later, matching: query)
            #expect(groups == [InboxList.Group(section: .done, ids: [report.id])], "\(query)")
        }
        #expect(InboxList.groups(deliveries, state: saved, now: later, matching: "missing").isEmpty)
        #expect(InboxList.groups(deliveries, state: saved, now: later, matching: " \n ").isEmpty)
        #expect(InboxState.load(from: root) == state && folder.load() == [report])
        #expect(try Data(contentsOf: folder.fileURL("evidence.md", of: report.id)) == contents)
        #expect(saved.unreadCount(deliveries) == 0 && saved.unfinishedCount(deliveries) == 0 && saved.isAnswered(report))
    }

    @Test func theSelectedArchiveStaysReadableUntilTheOwnerLeavesIt() {
        let report = Delivery(botID: UUID(), title: "Report", sentAt: now)
        var state = InboxState()
        state.setDone(report.id, true, at: now)
        let cutoff = now.addingTimeInterval(86_400)
        #expect(InboxList.groups([report], state: state, now: cutoff, retaining: report.id).first?.ids == [report.id])
        #expect(InboxList.groups([report], state: state, now: cutoff).isEmpty)
        // Pinning its place alone doesn't retain an old Done item; a search must still match it.
        #expect(InboxList.groups([report], state: state, now: cutoff, pinned: [report.id: .done]).isEmpty)
        #expect(InboxList.groups([report], state: state, now: cutoff, matching: "unrelated", retaining: report.id).isEmpty)
    }

    @Test func listCandidatesStayBoundedAsTheArchiveGrowsAndExpireWithoutScanningIt() {
        let active = Delivery(botID: UUID(), title: "Active", sentAt: now)
        let recent = Delivery(botID: UUID(), title: "Recent", sentAt: now)
        let old = (0..<10_000).map { Delivery(botID: active.botID, title: "Archived \($0)", sentAt: now.addingTimeInterval(-Double($0 + 2) * 86_400)) }
        var state = InboxState()
        for delivery in old { state.setDone(delivery.id, true, at: delivery.updatedAt) }
        state.setDone(recent.id, true, at: now)
        let all = old + [active, recent]
        var index = InboxList.Index(all, state: state, now: now)
        #expect(index.deliveries.count == 2)
        #expect(Set(InboxList.shown(InboxList.groups(index.deliveries.values, state: state, now: now), showsDone: true)) == [active.id, recent.id])
        #expect(index.nextExpiration(state: state) == now.addingTimeInterval(86_400))
        index.expire(state: state, now: now.addingTimeInterval(86_400))
        #expect(index.deliveries.count == 1 && index.deliveries[active.id] != nil)
        #expect(index.nextExpiration(state: state) == nil)

        // Reopen and renew update just the affected delivery, without rebuilding archived rows.
        state.setDone(old[0].id, false, at: now)
        index.update(old[0], state: state, now: now)
        #expect(index.deliveries.count == 2 && index.deliveries[old[0].id] != nil)
        var renewed = old[1]
        renewed.updatedAt = now.addingTimeInterval(1)
        state.received(renewed.id, renewed: true, shown: false)
        index.update(renewed, state: state, now: now)
        #expect(index.deliveries.count == 3 && index.latest == renewed)
        #expect(state.unfinishedCount(all) == 3)
        #expect(all.count == 10_002)
    }
}
