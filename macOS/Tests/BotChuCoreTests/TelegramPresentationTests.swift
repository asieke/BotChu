import Foundation
import Testing
@testable import BotChuCore

@Suite struct TelegramPresentationTests {
    private func reply(_ turn: [ChatMessage]) throws -> String {
        let user = ChatMessage(role: .user, text: "How did it go?")
        return try #require(TelegramReply.compose(after: user.id, in: [user] + turn, botName: "Danny"))
    }

    @Test func theFinalResultReplacesProgressAndToolNoise() throws {
        let transcript = [ChatMessage(role: .assistant, text: "I'll inspect the repository."),
                          ChatMessage(role: .tool, text: "raw tool secret", toolName: "Bash", toolOutput: String(repeating: "log\n", count: 10_000)),
                          ChatMessage(role: .assistant, text: "Now running the tests."),
                          ChatMessage(role: .tool, toolName: "Bash", toolOutput: "tool payload"),
                          ChatMessage(role: .assistant, text: "Fixed the sign-in bug. All tests passed.")]
        let text = try reply(transcript)
        #expect(text.hasPrefix("Fixed the sign-in bug."))
        #expect(text.contains("All tests passed."))
        #expect(!text.contains("inspect") && !text.contains("Now running") && !text.contains("payload") && !text.contains("secret"))
        #expect(transcript[1].toolOutput?.count == 40_000)
    }

    @Test func aLongAnswerReservesRoomForTheDecisionAtItsEnd() throws {
        let details = (1...80).map { "The implementation detail for module \($0) explains the data flow." }.joined(separator: "\n")
        let text = try reply([ChatMessage(role: .assistant, text: "The search fix is ready.\n\n" + details + "\n\nWarning: production is not deployed.\nThe Safari result is unverified.\nPlease choose whether to deploy today?")])
        #expect(text.hasPrefix("The search fix is ready."))
        #expect(text.contains("production is not deployed") && text.contains("Safari result is unverified"))
        #expect(text.contains("Please choose whether to deploy today?"))
        #expect(text.contains("/details"))
        #expect(text.utf16.count < 1_600)
        #expect(TelegramReply.messages(text).count == 1)
    }

    @Test func failureStopAndPartialResultsNeverReadAsSuccess() throws {
        let failed = try reply([ChatMessage(role: .assistant, text: "Uploaded the files."), ChatMessage(role: .error, text: "401 unauthorized: secret-token")])
        #expect(failed.hasPrefix("⚠️ Danny couldn't finish"))
        #expect(failed.contains("sign-in") && failed.contains("Uploaded the files."))
        #expect(!failed.contains("secret-token"))
        let stopped = try reply([ChatMessage(role: .assistant, text: "The first check passed."), ChatMessage(role: .note, text: "Stopped")])
        #expect(stopped.hasPrefix("⏹ Stopped") && stopped.contains("incomplete") && stopped.contains("follow-up"))
        let partial = try reply([ChatMessage(role: .assistant, text: "Two imports passed.\nThe third import failed.\nNext step: correct its missing column.")])
        #expect(partial.contains("third import failed") && partial.contains("correct its missing column"))
    }

    @Test func aToolEndingTheTurnCannotTurnProgressIntoAResult() throws {
        let text = try reply([ChatMessage(role: .assistant, text: "I'll deploy it now."), ChatMessage(role: .tool, toolName: "Bash", toolState: .failed)])
        #expect(text.contains("ended without a final answer"))
        #expect(!text.contains("I'll deploy"))
    }

    @Test func earlierBlockersAndDecisionsAreNotErasedByAShortFinalAnswer() throws {
        let text = try reply([ChatMessage(role: .assistant, text: "Deployment is blocked pending approval.\nPlease confirm the production target?"),
                              ChatMessage(role: .tool, toolName: "Bash"), ChatMessage(role: .assistant, text: "The tests passed.")])
        #expect(text.hasPrefix("The tests passed."))
        #expect(text.contains("Earlier in this turn: Deployment is blocked pending approval."))
        #expect(text.contains("Please confirm the production target?"))
    }

    @Test func safeErrorCategoriesExplainTheProblemWithoutPathsOrSecrets() throws {
        let missing = try reply([ChatMessage(role: .error, text: "Checkout /private/customer/secrets is missing")])
        #expect(missing.contains("workspace or a required file is missing") && missing.contains("Restore its location"))
        #expect(!missing.contains("/private") && !missing.contains("customer"))
        let denied = try reply([ChatMessage(role: .error, text: "Permission denied writing /private/secret")])
        #expect(denied.contains("could not be accessed") && denied.contains("permissions"))
        #expect(!denied.contains("/private"))
        let rawOnly = try reply([ChatMessage(role: .assistant, text: "{\"tool_result\":\"secret\"}")])
        #expect(rawOnly.contains("ended without a final answer"))
        #expect(!rawOnly.contains("secret"))
    }

    @Test func bulletsLinksSmallCodeAndSpecialCharactersStayReadable() throws {
        let text = try reply([ChatMessage(role: .assistant, text: "## Ready\n- **Fixed** A & B < C.\n- See [the change](https://example.com/pull/1?x=2&y=3).\n```sh\nswift test --filter LoginTests\n```\nEmoji: 👨‍👩‍👧‍👦; literal: x_y!")])
        #expect(text.contains("• Fixed A & B < C."))
        #expect(text.contains("the change (https://example.com/pull/1?x=2&y=3)"))
        #expect(text.contains("swift test --filter LoginTests"))
        #expect(text.contains("👨‍👩‍👧‍👦") && text.contains("x_y!"))
        #expect(!text.contains("**") && !text.contains("##") && !text.contains("```"))
    }

    @Test func rawPayloadsAndLongLogsAreNotAReadableAnswer() throws {
        let text = try reply([ChatMessage(role: .assistant, text: "Updated the settings.\n```json\n{\"tool_call\":\"raw_payload\"}\n```\n" + String(repeating: "DEBUG noisy log\n", count: 80) + "\nNext step: restart the app.")])
        #expect(text.contains("Updated the settings") && text.contains("restart the app"))
        #expect(!text.contains("raw_payload") && !text.contains("noisy log"))
    }

    @Test func codeIndentationAndOperatorsArePreservedInDigestAndDetails() throws {
        let code = "if ready:\n    print(value | mask)\n    print(\"**literal**\")"
        let source = "Use this example.\n```python\n" + code + "\n```"
        let text = try reply([ChatMessage(role: .assistant, text: source)])
        #expect(text.contains(code))
        #expect(TelegramPresentation.plainText(source).contains(code))
    }

    @Test func tooManyWarningsAreExplicitlyIncompleteInsteadOfSilentlyLost() throws {
        let warnings = (1...80).map { "Warning: region \($0) has an unverified deployment and needs checking." }.joined(separator: "\n")
        let text = try reply([ChatMessage(role: .assistant, text: "The first region is ready.\n" + warnings)])
        #expect(text.contains("more caveats or decisions"))
        #expect(text.contains("don't treat this as a complete result"))
        #expect(text.utf16.count < 1_600)
    }

    @Test func detailsKeepTheWholeAssistantReplyAndExcludeOtherTurnsAndTools() throws {
        let user = ChatMessage(role: .user, text: "first"), next = ChatMessage(role: .user, text: "next")
        let long = String(repeating: "Whole answer. ", count: 10_000)
        let thread = [user, ChatMessage(role: .tool, text: "secret output"), ChatMessage(role: .assistant, text: long), next, ChatMessage(role: .assistant, text: "other turn")]
        let full = try #require(TelegramReply.full(after: user.id, in: thread, botName: "Danny"))
        #expect(full == long.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(!full.contains("secret output") && !full.contains("other turn"))
        #expect(thread[2].text == long)
    }
}
