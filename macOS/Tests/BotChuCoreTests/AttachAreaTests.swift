import Foundation
import Testing
@testable import BotChuCore

/// Attach Project Area's rows and its prepared-sheet presentation (#402, #438).
@Suite struct AttachAreaTests {
    private func close(_ presentation: inout AttachAreaPresentation, _ request: UUID) -> Bool { presentation.close(request) }

    private func row(_ name: String, _ repo: String) -> AttachAreaRow {
        let entry = ProjectCatalogEntry(name: name, repo: repo, url: URL(string: "https://github.com/\(repo)")!, status: nil,
                                        location: RepoLocation(path: "/w/\(repo)"), workplace: "This Mac")
        return AttachAreaRow(entry: entry, owner: nil, problem: nil)
    }

    @Test func theSearchKeepsRowsWithEveryWordInTheirNameOrRepository() {
        let rows = [row("BotChu", "asieke/BotChu"), row("GitChu", "asieke/GitChu"), row("Kids Post", "sieke/kids-post")]
        #expect(AttachAreaRow.filter(rows, query: "") == rows)
        #expect(AttachAreaRow.filter(rows, query: "   ").map(\.id) == rows.map(\.id))
        #expect(AttachAreaRow.filter(rows, query: "chu").map(\.id) == ["asieke/BotChu", "asieke/GitChu"])
        #expect(AttachAreaRow.filter(rows, query: "ASIEKE git").map(\.id) == ["asieke/GitChu"])
        #expect(AttachAreaRow.filter(rows, query: "kids sieke/").map(\.id) == ["sieke/kids-post"])
        #expect(AttachAreaRow.filter(rows, query: "nothing").isEmpty)
    }

    @Test func eachOpeningUsesThePreparedFormOnceAndAColdOneWhenNoneIsReady() {
        var presentation = AttachAreaPresentation()
        #expect(presentation.needsPreparation)
        let first = UUID()
        presentation.prepared(first)
        #expect(!presentation.needsPreparation)

        let warm = presentation.open(cold: { Issue.record("A prepared form was ready"); return UUID() }())
        #expect(warm?.form == first)
        #expect(warm?.wasPrepared == true)
        // Nothing is prepared while it shows, and a second press doesn't open another.
        #expect(!presentation.needsPreparation)
        presentation.prepared(UUID())
        #expect(presentation.prepared == nil)
        #expect(presentation.open(cold: UUID()).map(\.request) == nil)

        #expect(close(&presentation, warm!.request))
        #expect(presentation.needsPreparation)

        // Without a prepared form, the opening makes one now; the used form never comes back.
        let made = UUID()
        let cold = presentation.open(cold: made)
        #expect(cold?.form == made)
        #expect(cold?.wasPrepared == false)
        #expect(cold?.request != warm?.request)
    }

    @Test func onlyTheShownOpeningCloses() {
        var presentation = AttachAreaPresentation()
        let first = presentation.open(cold: UUID())!
        #expect(close(&presentation, first.request))
        // A second Cancel, or Escape after Cancel, closes nothing.
        #expect(!close(&presentation, first.request))

        let second = presentation.open(cold: UUID())!
        // The late dismissal of the earlier opening leaves the new one shown.
        #expect(!close(&presentation, first.request))
        #expect(presentation.shown?.request == second.request)
        #expect(close(&presentation, second.request))
    }

    @Test func resettingForgetsThePreparedAndTheShownForm() {
        var presentation = AttachAreaPresentation()
        presentation.prepared(UUID())
        presentation.reset()
        #expect(presentation == AttachAreaPresentation())
        let shown = presentation.open(cold: UUID())!
        presentation.reset()
        #expect(!close(&presentation, shown.request))
        #expect(presentation.needsPreparation)
    }
}
