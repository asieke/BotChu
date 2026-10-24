import Foundation
import Testing
@testable import BotChuCore

@Suite struct ModelLabelTests {
    @Test func claudeChoicesHaveFullNamesAndSayWhichMove() {
        let options = GenerationOptions.models(for: .claude)
        #expect(options.map(\.id) == ["opus", "claude-opus-5-5", "sonnet", "claude-sonnet-5-5", "haiku", "claude-haiku-5-5"])
        let picker = ModelPickerData(kind: .claude, model: "", openRouterDefault: "")
        let titles = Dictionary(uniqueKeysWithValues: picker.choices.map { ($0.id, $0.title) })
        #expect(titles["opus"] == "Claude Opus · latest")
        #expect(titles["claude-opus-5-5"] == "Claude Opus 5.5")
        #expect(titles["sonnet"] == "Claude Sonnet · latest")
        #expect(titles["claude-sonnet-5-5"] == "Claude Sonnet 5.5")
        #expect(titles["haiku"] == "Claude Haiku · latest")
        #expect(titles["claude-haiku-5-5"] == "Claude Haiku 5.5")
        #expect(!picker.choices.contains { ["Opus", "Sonnet", "Haiku"].contains($0.title) })
        // Pinned versions keep their alias's effort choices.
        #expect(GenerationOptions.efforts(for: .claude, model: "claude-opus-5-5") == GenerationOptions.efforts(for: .claude, model: "opus"))
        #expect(GenerationOptions.efforts(for: .claude, model: "claude-haiku-5-5").isEmpty)
        #expect(picker.matching("5.5").map(\.id) == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
    }

    @Test func aliasesAndDefaultsShowAVersionOnlyOnceReported() {
        let alias = GenerationOptions.label(for: "opus", kind: .claude)
        #expect(alias.title == "Claude Opus · latest")
        #expect(alias.detail == "opus · moving alias · version unresolved")
        let resolved = GenerationOptions.label(for: "opus", kind: .claude, resolved: "claude-opus-5-5")
        #expect(resolved.title == "Claude Opus 5.5 · latest")
        #expect(resolved.detail == "opus · moving alias · last ran claude-opus-5-5")

        #expect(GenerationOptions.label(for: "", kind: .claude) ==
                ModelLabel(title: "Claude Code default", detail: "Chosen by Claude Code · version unresolved"))
        #expect(GenerationOptions.label(for: "", kind: .claude, resolved: "claude-opus-5-5") ==
                ModelLabel(title: "Claude Opus 5.5 · default", detail: "Chosen by Claude Code · last ran claude-opus-5-5"))
        #expect(GenerationOptions.label(for: "", kind: .muse, resolved: "muse-wonder-full-1.0").title == "Muse Wonder Full 1.0 · default")
        for kind in [AgentKind.codex, .antigravity] {
            let label = GenerationOptions.label(for: "", kind: kind)
            #expect(label.title == "\(kind.displayName) default")
            #expect(label.detail == "Chosen by \(kind.displayName) · version unresolved")
        }

        // An ID BotChu doesn't know as an alias, which the CLI ran as something else.
        #expect(GenerationOptions.label(for: "opusplan", kind: .claude, resolved: "claude-sonnet-5-5") ==
                ModelLabel(title: "Claude Sonnet 5.5 · opusplan", detail: "opusplan · alias · last ran claude-sonnet-5-5"))
        #expect(GenerationOptions.label(for: "opusplan", kind: .claude).title == "opusplan")
        #expect(GenerationOptions.label(for: "opus[1m]", kind: .claude).title == "Claude Opus (1M context) · latest")
        #expect(GenerationOptions.label(for: "fable", kind: .claude, resolved: "claude-fable-5-1").title == "Claude Fable 5.1 · latest")
    }

    @Test func pinnedAndCustomIDsAreSpelledOutWithoutGuessing() {
        for (id, kind, title) in [
            ("claude-opus-5-5", AgentKind.claude, "Claude Opus 5.5"),
            ("claude-sonnet-4-5-20250929", .claude, "Claude Sonnet 4.5"),
            ("claude-3-5-haiku-20241022", .claude, "Claude Haiku 3.5"),
            ("claude-opus-4-1", .claude, "Claude Opus 4.1"),
            ("claude-opus-5-5[1m]", .claude, "Claude Opus 5.5 (1M context)"),
            ("claude-experimental-model", .claude, "claude-experimental-model"),
            ("my-proxy-model", .claude, "my-proxy-model"),
            ("gpt-6.1-sol", .codex, "GPT-6.1 Sol"),
            ("gpt-7-custom", .codex, "gpt-7-custom"),
            ("claude-opus-5-5-high", .antigravity, "Claude Opus 5.5"),
            ("muse-spark-1.3", .muse, "Muse Spark 1.3"),
        ] {
            let label = GenerationOptions.label(for: id, kind: kind)
            #expect(label.title == title, "\(id)")
            #expect(label.detail == id)
        }
        // Reporting the ID that was asked for adds nothing.
        #expect(GenerationOptions.label(for: "claude-opus-5-5", kind: .claude, resolved: "claude-opus-5-5").title == "Claude Opus 5.5")
    }

    @Test func pickerShowsTheResolvedVersionOnlyForTheSelectedChoice() {
        let picker = ModelPickerData(kind: .claude, model: "opus", openRouterDefault: "", resolved: "claude-opus-5-5")
        #expect(picker.title == "Claude Opus 5.5 · latest")
        #expect(picker.detail == "opus · moving alias · last ran claude-opus-5-5")
        #expect(picker.choices.first { $0.id == "opus" }?.detail == "opus · moving alias · last ran claude-opus-5-5")
        #expect(picker.choices.first { $0.id == "sonnet" }?.title == "Claude Sonnet · latest")
        #expect(picker.choices.first { $0.id.isEmpty }?.detail == "Chosen by Claude Code · version unresolved")
        #expect(picker.effectiveID == "opus")

        let inherited = ModelPickerData(kind: .claude, model: "", openRouterDefault: "", resolved: "claude-opus-5-5")
        #expect(inherited.title == "Claude Opus 5.5 · default")
        #expect(inherited.effectiveID.isEmpty)
        #expect(inherited.choices.first?.detail == "Chosen by Claude Code · last ran claude-opus-5-5")
    }
}

@Suite struct ReportedModelTests {
    @Test func reportFollowsTheChoiceAndAccountItWasMadeFor() throws {
        var bot = Bot(name: "Test", accountID: "claude-dev", model: "opus", reasoningEffort: .high,
                      workspace: "/tmp/test", sessionID: "s", sessionAccountID: "claude-dev")
        #expect(bot.resolvedModel == nil)
        let first = bot.recordReportedModel("claude-opus-5-5", requested: "opus")
        let again = bot.recordReportedModel("claude-opus-5-5", requested: "opus")
        #expect(first)
        #expect(!again)
        #expect(bot.resolvedModel == "claude-opus-5-5")
        // Recording a report never switches or pins the model, or touches the session.
        #expect(bot.model == "opus")
        #expect(bot.reasoningEffort == .high)
        #expect(bot.resumableSessionID == "s")

        bot.selectModel("sonnet")
        #expect(bot.resolvedModel == nil)
        bot.selectModel("opus")
        #expect(bot.resolvedModel == "claude-opus-5-5")
        bot.selectAccount("claude-personal")
        #expect(bot.model == "opus")
        #expect(bot.resolvedModel == nil)
    }

    @Test func reportSurvivesSavingAndOlderFilesStillLoad() throws {
        var task = BotTask(repo: "owner/name", checkout: "/tmp/name", accountID: "claude-work", model: "")
        task.recordReportedModel("claude-opus-5-5", requested: "")
        let restored = try JSONDecoder().decode(BotTask.self, from: JSONEncoder().encode(task))
        #expect(restored.resolvedModel == "claude-opus-5-5")

        let bot = Bot(name: "Test", workspace: "/tmp/test")
        let data = try JSONEncoder().encode(bot)
        #expect(!String(decoding: data, as: UTF8.self).contains("reportedModel"))
        #expect(try JSONDecoder().decode(Bot.self, from: data).reportedModel == nil)
    }

    private func run(_ kind: AgentKind, _ lines: [String]) -> [AgentEvent] {
        var parser = StreamParsers.make(for: kind)
        return lines.flatMap { parser.parse(line: $0) }
    }

    /// From `claude -p --output-format stream-json --verbose --model haiku` (and a missing
    /// model), 2026-10-24; reduced, with identifiers replaced.
    @Test func claudeReportsTheModelThatWroteItsMessages() {
        let events = run(.claude, [
            #"{"type":"system","subtype":"init","cwd":"/tmp/probe","session_id":"s","tools":["Bash"],"model":"claude-haiku-5-5"}"#,
            #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"OK"}]},"parent_tool_use_id":null,"session_id":"s"}"#,
            #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_2","type":"message","role":"assistant","content":[{"type":"text","text":"Again"}]},"parent_tool_use_id":null,"session_id":"s"}"#,
            #"{"type":"assistant","message":{"model":"claude-sonnet-5-5","id":"msg_3","type":"message","role":"assistant","content":[]},"parent_tool_use_id":"toolu_1","session_id":"s"}"#,
        ])
        #expect(events == [.session("s"), .model("claude-haiku-5-5"), .text("OK"), .text("Again")])

        // The init event repeats a --model that doesn't exist; the reply Claude Code makes up isn't a model.
        let missing = run(.claude, [
            #"{"type":"system","subtype":"init","cwd":"/tmp/probe","session_id":"s","tools":["Bash"],"model":"claude-opus-9-9"}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"There's an issue with the selected model (claude-opus-9-9). It may not exist or you may not have access to it. Run --model to pick a different model."}]},"parent_tool_use_id":null,"session_id":"s"}"#,
        ])
        #expect(!missing.contains { if case .model = $0 { true } else { false } })
    }

    /// From `muse exec --json`, 2026-10-24; reduced, with identifiers replaced.
    @Test func museReportsTheModelItsUsageCounted() {
        let events = run(.muse, [
            #"{"stream":{"kind":"session","id":"s"},"record_type":"event","payload_type":"run.model.configured","payload":{"kind":"run_model_configured","provider_id":"meta","model_id":"muse-bogus-9.9","display_label":"muse-bogus-9.9","source":"startup"}}"#,
            #"{"stream":{"kind":"exec.usage","id":"u"},"record_type":"status","payload_type":"run.usage","payload":{"kind":"run_usage","models":[{"model":"muse-wonder-full-1.0","input_tokens":29569,"cached_tokens":0,"output_tokens":14,"reasoning_tokens":4,"calls":1}],"calls":1,"completed_calls":1}}"#,
            #"{"stream":{"kind":"exec.usage","id":"u"},"record_type":"status","payload_type":"run.usage","payload":{"kind":"run_usage","models":[],"calls":0,"completed_calls":0}}"#,
        ])
        #expect(events == [.session("s"), .model("muse-wonder-full-1.0")])
    }

    @Test func reportedModelsLeaveTheThreadAndActivityAlone() {
        var assembler = ThreadAssembler()
        var messages: [ChatMessage] = []
        for event in [AgentEvent.textDelta("Hel"), .model("claude-opus-5-5"), .textDelta("lo")] {
            assembler.apply(event, to: &messages)
        }
        #expect(messages.map(\.text) == ["Hello"])
        #expect(BotActivity.next(after: .model("claude-opus-5-5")) == nil)
    }
}
