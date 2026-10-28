import Foundation
import Testing
@testable import BotChuCore

@Suite struct SettingsPageTests {
    @Test func tenPagesInThreeGroupsEachOnce() {
        #expect(SettingsPage.groups.flatMap { $0 } == SettingsPage.allCases)
        #expect(SettingsPage.groups.map(\.count) == [4, 2, 4])
        #expect(Set(SettingsPage.allCases.map(\.symbol)).count == 10)
    }

    @Test func pageNamesAreTheOnesTheAppsMessagesUse() {
        // "Settings ▸ Run reviews", "▸ Hosts", "▸ Sail", "▸ Telegram", "▸ Remote queue", "▸ Accounts".
        #expect(SettingsPage.allCases.map(\.title) == ["General", "Accounts", "GitHub", "Hosts", "Run reviews", "Pets",
                                                       "OpenRouter", "Sail", "Telegram", "Remote queue"])
        #expect(SettingsPage(rawValue: "sail") == .sail)
        #expect(SettingsPage(rawValue: "remote-queue") == .remoteQueue)
        #expect(SettingsPage(rawValue: "run-reviews") == .runReviews)
        #expect(SettingsPage(rawValue: "Remote queue") == nil)
    }

    @Test func theRailFoldsIntoAMenuBelow720Points() {
        #expect(SettingsPage.isCompact(width: 590))
        #expect(SettingsPage.isCompact(width: 719.5))
        #expect(!SettingsPage.isCompact(width: 720))
        #expect(!SettingsPage.isCompact(width: 976))
    }

    @Test func marksSayWhatNeedsTheOwnerInWords() {
        #expect(SettingsMark.accounts(found: [:]) == nil, "Not checked yet")
        #expect(SettingsMark.accounts(found: ["a": true, "b": true]) == nil)
        #expect(SettingsMark.accounts(found: ["a": false, "b": true, "c": false]) == .problem(count: 2))
        #expect(SettingsMark.problem(count: 1).label == "1 problem")
        #expect(SettingsMark.problem(count: 2).label == "2 problems")
        #expect(SettingsMark.service(unsaved: true, problem: true, running: true) == .unsaved)
        #expect(SettingsMark.service(unsaved: false, problem: true, running: true) == .problem(count: nil))
        #expect(SettingsMark.service(unsaved: false, problem: false, running: true) == .on)
        #expect(SettingsMark.service(unsaved: false, problem: false, running: false) == nil)
        #expect(SettingsMark.on.label == "On")
    }
}

@Suite struct SettingsKeyDraftTests {
    @Test func aDraftStartsFromTheSavedKeyOnceAndKeepsWhatIsTyped() {
        var draft = SettingsKeyDraft()
        #expect(draft.text == nil)
        #expect(!draft.isUnsaved, "Nothing typed before its page shows")
        draft.seed(saved: "sk-or-old")
        #expect(draft.text == "sk-or-old")
        #expect(!draft.isUnsaved)
        draft.text = "sk-or-new "
        #expect(draft.isUnsaved)
        // Showing the page again keeps what is typed.
        draft.seed(saved: "sk-or-old")
        #expect(draft.text == "sk-or-new ")
        #expect(draft.save() == "sk-or-new")
        #expect(draft.saved == "sk-or-new")
        #expect(!draft.isUnsaved)
        draft.text = "  sk-or-new\n"
        #expect(!draft.isUnsaved, "Only spaces around it differ")
    }

    @Test func noSavedKeyIsEmptyAndRemovingSavesEmpty() {
        var draft = SettingsKeyDraft()
        draft.seed(saved: nil)
        #expect(draft.text == "")
        #expect(!draft.isUnsaved)
        draft.text = "123:AA"
        _ = draft.save()
        draft.text = ""
        #expect(draft.isUnsaved)
        #expect(draft.save() == "")
        #expect(!draft.isUnsaved)
    }
}
