import Foundation
import Testing
@testable import BotChuCore

/// Each CLI's output, trimmed from real runs of "Run ls in the shell, then reply with one word".
private func run(_ kind: AgentKind, _ lines: [String]) -> [AgentEvent] {
    var parser = StreamParsers.make(for: kind)
    return lines.flatMap { parser.parse(line: $0) }
}

private func thread(_ events: [AgentEvent]) -> [ChatMessage] {
    var assembler = ThreadAssembler()
    var messages: [ChatMessage] = []
    for event in events { assembler.apply(event, to: &messages) }
    return messages
}

@Suite struct ClaudeParserTests {
    let lines = [
        #"{"type":"system","subtype":"init","cwd":"/tmp/probe","session_id":"51e64f5b-b2d8-4840-ba1a-81f82d98972a","tools":["Bash"],"model":"claude-opus-5-5"}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[]}},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}},"parent_tool_use_id":null}"#,
        #"{"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls","description":"List files"}}]},"parent_tool_use_id":null,"session_id":"s"}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"(Bash completed with no output)","is_error":false}]},"parent_tool_use_id":null,"session_id":"s"}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","content":[]}},"parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}},"parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":0},"parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Emp"}},"parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ty."}},"parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":1},"parent_tool_use_id":null}"#,
        #"{"type":"assistant","message":{"id":"msg_2","type":"message","role":"assistant","content":[{"type":"text","text":"Empty."}]},"parent_tool_use_id":null}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"Empty.","session_id":"51e64f5b-b2d8-4840-ba1a-81f82d98972a"}"#,
    ]

    @Test func events() {
        #expect(run(.claude, lines) == [
            .session("51e64f5b-b2d8-4840-ba1a-81f82d98972a"),
            .toolStarted(id: "toolu_1", name: "Bash", input: "ls", arguments: #"{"command":"ls","description":"List files"}"#),
            .toolFinished(id: "toolu_1", name: "Bash", output: "(Bash completed with no output)", isError: false),
            .textDelta("Emp"), .textDelta("ty."), .textEnd,
            .finished,
        ])
    }

    @Test func threadHasOneToolAndOneReply() {
        let messages = thread(run(.claude, lines))
        #expect(messages.map(\.role) == [.tool, .assistant])
        #expect(messages[0].toolState == .done)
        #expect(messages[1].text == "Empty.")
    }

    @Test func readArgumentsAreKept() {
        let events = run(.claude, [#"{"type":"assistant","message":{"id":"msg_3","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/tmp/probe/notes.md","offset":40,"limit":20}}]},"parent_tool_use_id":null,"session_id":"s"}"#])
        #expect(events == [.toolStarted(id: "toolu_2", name: "Read", input: "/tmp/probe/notes.md",
                                        arguments: #"{"file_path":"/tmp/probe/notes.md","limit":20,"offset":40}"#)])
    }

    @Test func unstreamedTextIsUsedWhole() {
        let events = run(.claude, [#"{"type":"assistant","message":{"id":"msg_9","content":[{"type":"text","text":"Hi there"}]},"parent_tool_use_id":null}"#])
        #expect(events == [.text("Hi there")])
    }

    @Test func subagentLinesAreSkipped() {
        let events = run(.claude, [#"{"type":"assistant","message":{"id":"m","content":[{"type":"text","text":"inner"}]},"parent_tool_use_id":"toolu_task"}"#])
        #expect(events.isEmpty)
    }

    @Test func errorResult() {
        let events = run(.claude, [#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"No conversation found with session ID: x"}"#])
        #expect(events == [.failed("No conversation found with session ID: x")])
    }

    /// With `--input-format stream-json --replay-user-messages` (Claude Code 2.1.308), each message
    /// taken from stdin comes back: the prompt at the start, a follow-up after the tool result it
    /// followed. Tool results, also `user` lines, are not replays.
    @Test func replayedInputIsTaken() {
        let events = run(.claude, [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Reply with just OK."}]},"session_id":"e485fd44-fe1b-4f33-9fb5-3806e003584a","parent_tool_use_id":null,"uuid":"10eddb68-ca21-4a05-85a1-ae5b1941fb2a","timestamp":"2026-10-23T02:00:04.262Z","isReplay":true}"#,
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_014mbfyb6J2TnMub9WuxJd7h","type":"tool_result","content":"one","is_error":false}]},"parent_tool_use_id":null,"session_id":"837c1775-1771-4e52-9523-a9354e905bef","uuid":"04be0b02-bd34-4738-afe8-2ac04509935d","timestamp":"2026-10-23T01:52:31.200Z","tool_use_result":{"stdout":"one","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Change of plan: after the current command, skip the rest and just reply with the word BANANA."}]},"session_id":"837c1775-1771-4e52-9523-a9354e905bef","parent_tool_use_id":null,"uuid":"5e64391e-4ca5-4c35-84b5-e67a8047ded8","timestamp":"2026-10-23T01:52:27.068Z","isReplay":true}"#,
        ])
        #expect(events == [.inputTaken, .toolFinished(id: "toolu_014mbfyb6J2TnMub9WuxJd7h", name: "Tool", output: "one", isError: false), .inputTaken])
    }

    /// #223, Claude Code 2.1.311: a follow-up written during a long tool call is taken only once the
    /// call returns; the task and heartbeat lines in between carry no events. (The model it reports
    /// is left out here.)
    @Test func followUpDuringALongToolIsTakenAfterItsResult() {
        let events = run(.claude, ClaudeInputSamples.followUpDuringALongTool)
        let shape = events.compactMap { event -> String? in
            switch event {
            case .inputTaken: "taken"
            case .toolStarted: "tool"
            case .toolFinished(_, _, let output, let isError, _): "result:\(output):\(isError)"
            case .text(let text): "text:\(text)"
            case .finished: "finished"
            default: nil
            }
        }
        #expect(shape == ["taken", "tool", "result:1:false", "taken", "text:slept PELICAN", "finished"])
    }

    /// #223: Stop while a follow-up waits on stdin. The CLI rejects the running call and ends with an
    /// error result, never echoing the follow-up, so it is still undelivered.
    @Test func stopDuringALongToolLeavesTheFollowUpUntaken() {
        let events = run(.claude, ClaudeInputSamples.stoppedWithAnUntakenFollowUp)
        #expect(events.filter { $0 == .inputTaken }.count == 1)
        #expect(events.contains { if case .toolFinished(_, _, _, true, _) = $0 { true } else { false } })
        guard case .failed = events.last else { Issue.record("Expected a failed result, got \(String(describing: events.last))"); return }
    }

    /// #255: a turn that ends with a test run going in the background says so after its end, so
    /// BotChu keeps the CLI waiting for it, doing what it does; the new turn that follows its end
    /// starts with a session event.
    @Test func aTurnEndingWithBackgroundTasksSaysWhatTheyDo() {
        let events = run(.claude, ClaudeInputSamples.backgroundTask)
        let shape = events.compactMap { event -> String? in
            switch event {
            case .session: "session"
            case .toolStarted: "tool"
            case .toolFinished: "result"
            case .text(let text): "text:\(text)"
            case .finished: "finished"
            case .backgroundTasks(let tasks): "background:\(tasks.map(\.rawValue))"
            default: nil
            }
        }
        #expect(shape == [
            "session", "tool", #"background:["working"]"#, #"background:["testing"]"#, "result", "text:started",
            "finished", #"background:["testing"]"#, "background:[]", "session", "text:finished", "finished",
        ])
    }
}

@Suite struct CodexParserTests {
    let lines = [
        "Reading additional input from stdin...",
        #"{"type":"thread.started","thread_id":"01a16190-3b37-70b1-b6c1-9b751c29d226"}"#,
        #"{"type":"turn.started"}"#,
        "2026-10-22T03:03:04.753918Z ERROR codex_rmcp_client::oauth: failed to refresh OAuth tokens",
        #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I’ll run `ls`.\n"}}"#,
        #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc ls","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc ls","aggregated_output":"","exit_code":0,"status":"completed"}}"#,
        #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Done"}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":42103,"output_tokens":71}}"#,
    ]

    @Test func events() {
        #expect(run(.codex, lines) == [
            .session("01a16190-3b37-70b1-b6c1-9b751c29d226"),
            .text("I’ll run `ls`.\n"),
            .toolStarted(id: "item_1", name: "Shell", input: "ls"),
            .toolStarted(id: "item_1", name: "Shell", input: "ls"),
            .toolFinished(id: "item_1", name: "Shell", output: "", isError: false, exitCode: 0),
            .text("Done"),
            .usage(TurnUsage(models: [ModelUsage(model: "", uncachedInput: 42103, output: 71)], cumulative: true)),
            .finished,
        ])
    }

    @Test func threadDedupesTheToolCard() {
        let messages = thread(run(.codex, lines))
        #expect(messages.map(\.role) == [.assistant, .tool, .assistant])
        #expect(messages[0].text == "I’ll run `ls`.")
    }

    @Test func failedCommandAndTurn() {
        let events = run(.codex, [
            #"{"type":"item.completed","item":{"id":"i","type":"command_execution","command":"/bin/zsh -lc 'false'","aggregated_output":"","exit_code":1,"status":"failed"}}"#,
            #"{"type":"turn.failed","error":{"message":"usage limit reached"}}"#,
        ])
        #expect(events == [
            .toolStarted(id: "i", name: "Shell", input: "false"),
            .toolFinished(id: "i", name: "Shell", output: "", isError: true, exitCode: 1),
            .failed("usage limit reached"),
        ])
    }
}

@Suite struct AntigravityParserTests {
    let lines = [
        #"{"event":"init","conversation_id":"ed6822af-ee2c-432f-8e59-90a27d09c369","init":{"cwd":"/tmp/probe","tools":["run_command"]}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":0,"state":"DONE","step_type":"user_input"}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":1,"state":"DONE","step_type":"agent_response","duration_seconds":6.2}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"ls"}}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":2,"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"ls"},"output":"Command exited with code 0.\n\nNo output from the command."}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":3,"state":"ACTIVE","step_type":"agent_response","text_delta":"Done"}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":3,"state":"DONE","step_type":"agent_response","text_delta":"\n"}}"#,
        #"{"event":"result","result":{"conversation_id":"c","status":"SUCCESS","response":"Done\n","num_turns":1}}"#,
    ]

    @Test func events() {
        #expect(run(.antigravity, lines) == [
            .session("ed6822af-ee2c-432f-8e59-90a27d09c369"),
            .textEnd,
            .toolStarted(id: "step-2", name: "run_command", input: "ls", arguments: #"{"CommandLine":"ls"}"#),
            .toolStarted(id: "step-2", name: "run_command", input: "ls", arguments: #"{"CommandLine":"ls"}"#),
            .toolFinished(id: "step-2", name: "run_command", output: "Command exited with code 0.\n\nNo output from the command.", isError: false, exitCode: 0),
            .textDelta("Done"),
            .textDelta("\n"), .textEnd,
            .finished,
        ])
    }

    @Test func thread() {
        let messages = BotChuCoreTests.thread(run(.antigravity, lines))
        #expect(messages.map(\.role) == [.tool, .assistant])
        #expect(messages[1].text == "Done")
    }

    @Test(arguments: ["ERROR", "CANCELED", ""])
    func incompleteReplyStillFails(status: String) {
        let events = run(.antigravity, [
            #"{"event":"step_update","step_update":{"state":"ACTIVE","step_type":"agent_response","text_delta":"Partial reply"}}"#,
            "{\"event\":\"result\",\"result\":{\"status\":\"\(status)\",\"response\":\"Partial reply\"}}",
        ])
        #expect(events == [.textDelta("Partial reply"),
                           .failed("Antigravity stopped: \(status.isEmpty ? "unknown status" : status).")])
    }

    @Test(arguments: [true, false])
    func currentErrorIsNotHiddenByCompletedReply(errorFirst: Bool) {
        let reply = #"{"event":"step_update","step_update":{"state":"DONE","step_type":"agent_response","text_delta":"Done"}}"#
        let error = #"{"event":"error","error":{"message":"Quota exhausted"}}"#
        for status in ["ERROR", "SUCCESS"] {
            let events = run(.antigravity, (errorFirst ? [error, reply] : [reply, error]) + [
                "{\"event\":\"result\",\"result\":{\"status\":\"\(status)\",\"response\":\"Done\"}}",
            ])
            let replyEvents: [AgentEvent] = [.textDelta("Done"), .textEnd]
            let failure: [AgentEvent] = [.failed("Quota exhausted")]
            #expect(events == (errorFirst ? failure + replyEvents : replyEvents + failure))
        }
    }

    // Captured from agy on 2026-10-23, with IDs/usage trimmed. The terminal status
    // is changed to ERROR to model the earlier failed trajectory described in #62.
    let recoveredTurn = [
        #"{"event":"step_update","step_update":{"step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":"ORCHID"}}"#,
        #"{"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"agent_response","text_delta":"\n","duration_seconds":3.497328}}"#,
        #"{"event":"result","result":{"status":"ERROR","response":"ORCHID\n","num_turns":1}}"#,
    ]

    @Test func completedResponseOverridesHistoricalFailure() {
        let events = run(.antigravity, recoveredTurn)
        #expect(events == [.textDelta("ORCHID"), .textDelta("\n"), .textEnd, .finished])
        let messages = BotChuCoreTests.thread(events)
        #expect(messages.map(\.role) == [.assistant])
        #expect(messages.first?.text == "ORCHID")
    }

    @Test func failedResult() {
        let events = run(.antigravity, [#"{"event":"result","result":{"status":"ERROR","response":""}}"#])
        #expect(events == [.failed("Antigravity stopped: ERROR.")])
    }

    // #367: the stream leaves out what a search found and what a read returned, so a search with
    // no output and a read's "N lines, M bytes" are successes, not empty results.
    @Test func capturedSearchAndRangeReadStayDone() {
        let messages = BotChuCoreTests.thread(run(.antigravity, AntigravitySamples.searchAndRangeRead))
        #expect(messages.map(\.toolName) == ["search_web", "read_file", "read_file"])
        #expect(messages.map(\.toolState) == [.done, .done, .done])
        #expect(messages.map(\.toolOutput) == ["", "400 lines, 6292 bytes", "2 lines, 11 bytes"])
    }

    @Test func capturedFailedCallCarriesAntigravitysReason() {
        let messages = BotChuCoreTests.thread(run(.antigravity, AntigravitySamples.failedReads))
        #expect(messages.map(\.toolState) == [.failed, .failed])
        #expect(messages.map(\.toolOutput) == ["file does not exist", "path is a directory, not a file"])
        #expect(ToolActivity.failureReason(output: messages[0].toolOutput ?? "") == "not found")
        // Without a reason, BotChu still says the step failed.
        let bare = run(.antigravity, [#"{"event":"step_update","step_update":{"step_index":1,"state":"CANCELED","step_type":"tool","tool_name":"search_web","tool_info":{"name":"search_web"}}}"#])
        #expect(bare.last == .toolFinished(id: "step-1", name: "search_web", output: "Antigravity reported CANCELED.", isError: true))
    }

    @Test func capturedShellExitCodes() {
        let events = run(.antigravity, AntigravitySamples.shell)
        let finished = events.compactMap { event -> (Bool, Int?)? in
            if case let .toolFinished(_, _, _, isError, exitCode) = event { (isError, exitCode) } else { nil }
        }
        // The parser reports how each command exited; the thread decides what failed.
        #expect(finished.map(\.0) == [false, false, false, false])
        #expect(finished.map(\.1) == [0, 1, 1, 0])
        let messages = BotChuCoreTests.thread(events)
        #expect(messages.map(\.toolState) == [.done, .failed, .failed, .done])
        #expect(messages.map(\.toolExitCode) == [0, 1, 1, 0])
        // grep finding nothing still reads as no matches, as it does for the other CLIs.
        #expect(ToolActivity.describe(messages[1]).noMatches)
        #expect(ToolActivity.describe(messages[2]).failure == "not found")
        // Run reviews see the failures and agy's reasons.
        let review = EvaluationSnapshot.items(messages + BotChuCoreTests.thread(run(.antigravity, AntigravitySamples.failedReads)),
                                              brief: "", opening: nil, passages: EvaluationSnapshot.Passages.tiers[0])
        #expect(review.map(\.text) == [
            "run_command: mkdir made → exit 0",
            "run_command: grep zzz small.txt → failed (exit 1)\n    Command exited with code 1.\n    \n    No output from the command.",
            "run_command: ls /nonexistent-367 → failed (exit 1)\n    Command exited with code 1.\n    \n    Command output:\n    ls: /nonexistent-367: No such file or directory",
            "run_command: true → exit 0",
            #"read_file: {"Path":"/tmp/probe/does-not-exist.txt"} → failed"# + "\n    file does not exist",
            #"read_file: {"Path":"/tmp/probe/adir"} → failed"# + "\n    path is a directory, not a file",
        ])
    }

    @Test func exitCodeComesOnlyFromACommandsOwnHeader() {
        let shortened = BotChuCoreTests.thread(run(.antigravity, [AntigravitySamples.truncated]))
        #expect(shortened.map(\.toolExitCode) == [3] && shortened.map(\.toolState) == [.failed])
        func finished(_ name: String, _ output: String) -> [AgentEvent] {
            let line = summarizeToolInput(["event": "step_update", "step_update": ["step_index": 1, "state": "DONE", "step_type": "tool",
                                                                                   "tool_name": name, "tool_info": ["name": name, "output": output]]])
            return run(.antigravity, [line]).filter { if case .toolFinished = $0 { true } else { false } }
        }
        // Text that only looks like the header: in a file, later in the output, or without its period.
        #expect(finished("read_file", "Command exited with code 1.") == [.toolFinished(id: "step-1", name: "read_file", output: "Command exited with code 1.", isError: false)])
        #expect(finished("run_command", "Command failed to run: x\nCommand exited with code 0.").first
            == .toolFinished(id: "step-1", name: "run_command", output: "Command failed to run: x\nCommand exited with code 0.", isError: true))
        #expect(finished("run_command", "Command exited with code 2 and more") == [.toolFinished(id: "step-1", name: "run_command", output: "Command exited with code 2 and more", isError: false)])
        // An empty output doesn't hide a failed step's reason.
        let empty = summarizeToolInput(["event": "step_update", "step_update": ["step_index": 1, "state": "ERROR", "step_type": "tool", "tool_name": "read_file",
                                                                                "tool_info": ["name": "read_file", "output": "", "error": ["message": "file does not exist"]]]])
        #expect(run(.antigravity, [empty]).last == .toolFinished(id: "step-1", name: "read_file", output: "file does not exist", isError: true))
    }

    @Test func capturedRunErrorIsAntigravitysMessage() throws {
        let events = run(.antigravity, [AntigravitySamples.badModel])
        let message = try #require(events.compactMap { if case .failed(let text) = $0 { text } else { nil } }.first)
        #expect(message.hasPrefix("invalid model selection (--model \"bogus-model-xyz\""))
        #expect(events.last == .failed(message))
    }
}

@Suite struct MuseParserTests {
    @Test func capturedToolProgressPrecedesItsResult() {
        var parser = MuseParser()
        #expect(parser.parse(line: MuseSamples.toolTurn[0]) == [.session("id-2")])
        let started = parser.parse(line: MuseSamples.toolTurn[1])
        #expect(started == [.toolStarted(id: "id-6", name: "bash", input: "")])
        var assembler = ThreadAssembler()
        var messages: [ChatMessage] = []
        started.forEach { assembler.apply($0, to: &messages) }
        #expect(messages.count == 1 && messages[0].toolState == .running)
        let result = parser.parse(line: MuseSamples.toolTurn[2])
        #expect(result.last == .toolFinished(id: "id-6", name: "bash", output: "tool-ok", isError: false, exitCode: 0))
        result.forEach { assembler.apply($0, to: &messages) }
        #expect(messages.count == 1 && messages[0].toolState == .done)
        #expect(messages[0].toolInput == "printf tool-ok")
        #expect(messages[0].toolArguments?.contains("printf tool-ok") == true)
        #expect(parser.parse(line: MuseSamples.toolTurn[3]) == [.textDelta("Done")])
        #expect(parser.parse(line: MuseSamples.toolTurn[4]) == [.textEnd, .finished])
        #expect(!parser.requiresTermination)
    }

    // These defensive records are synthetic: the real pending probe emitted neither on stdout.
    @Test(arguments: ["approval.requested", "approval_wait.effect.started"])
    func approvalFailsAndRequestsTermination(_ type: String) {
        var parser = MuseParser()
        #expect(parser.parse(line: "{\"payload_type\":\"\(type)\",\"payload\":{}}") == [
            .failed("Muse is waiting for an approval BotChu can't show"),
        ])
        #expect(parser.requiresTermination)
        #expect(parser.parse(line: MuseSamples.toolTurn[4]).isEmpty)
    }

    @Test func unrelatedLifecycleAndResolvedApprovalsAreIgnored() {
        var parser = MuseParser()
        for line in [
            #"{"payload_type":"task.lifecycle.side_effect_intent","payload":{"event":{"operation":"model.meta.response","idempotency_key":"model:x"}}}"#,
            #"{"payload_type":"task.lifecycle.side_effect_intent","payload":{"event":{"operation":"tool:bash"}}}"#,
            #"{"payload_type":"approval.resolved","payload":{}}"#,
            #"{"payload_type":"approval_wait.effect.terminal","payload":{}}"#,
        ] { #expect(parser.parse(line: line).isEmpty) }
        #expect(!parser.requiresTermination)
    }

    let lines = [
        "muse: workspace root: /tmp/probe (cwd default)",
        #"{"schema_version":1,"stream":{"kind":"session","id":"0cb4a4fa-1730-4e14-b9f2-fa6a0a2b88ab"},"sequence":1,"record_type":"event","payload_type":"runtime.command.accepted","payload":{"kind":"command_accepted"}}"#,
        #"{"schema_version":1,"stream":{"kind":"session","id":"0cb4a4fa-1730-4e14-b9f2-fa6a0a2b88ab"},"sequence":2,"record_type":"event","payload_type":"task.lifecycle.started","payload":{"kind":"task_lifecycle","event":{"kind":"started"}}}"#,
        #"{"schema_version":1,"stream":{"kind":"session","id":"0cb4a4fa-1730-4e14-b9f2-fa6a0a2b88ab"},"sequence":3,"record_type":"event","payload_type":"tool.result","payload":{"kind":"tool_result","call_id":"call_1","text":"{\n  \"command\": \"ls\",\n  \"exit_code\": 0,\n  \"output\": \"muse.jsonl\\n\"\n}","correlation_facts":{"tool_name":"bash","outcome":"success"}}}"#,
        #"{"schema_version":1,"stream":{"kind":"session","id":"0cb4a4fa-1730-4e14-b9f2-fa6a0a2b88ab"},"sequence":4,"record_type":"status","payload_type":"run.output.delta","payload":{"kind":"run_output_delta","text":"banana"}}"#,
        #"{"schema_version":1,"stream":{"kind":"session","id":"0cb4a4fa-1730-4e14-b9f2-fa6a0a2b88ab"},"sequence":5,"record_type":"event","payload_type":"run.terminal.completed","payload":{"kind":"run_terminal","terminal":"completed","text":"banana","reason":null}}"#,
    ]

    @Test func events() {
        #expect(run(.muse, lines) == [
            .session("0cb4a4fa-1730-4e14-b9f2-fa6a0a2b88ab"),
            .toolStarted(id: "call_1", name: "bash", input: "ls", arguments: #"{"command":"ls","exit_code":0}"#),
            .toolFinished(id: "call_1", name: "bash", output: "muse.jsonl\n", isError: false, exitCode: 0),
            .textDelta("banana"),
            .textEnd, .finished,
        ])
    }

    @Test func unstreamedReplyComesFromTheTerminalRecord() {
        let events = run(.muse, [#"{"stream":{"kind":"session","id":"s"},"payload_type":"run.terminal.completed","payload":{"terminal":"completed","text":"hi"}}"#])
        #expect(events == [.session("s"), .text("hi"), .textEnd, .finished])
    }

    @Test func failedRun() {
        let events = run(.muse, [#"{"stream":{"kind":"run","id":"r"},"payload_type":"run.terminal.failed","payload":{"terminal":"failed","reason":"auth expired"}}"#])
        #expect(events == [.failed("auth expired")])
    }
}

@Suite struct PiParserTests {
    let lines = [
        #"{"type":"session","version":3,"id":"01a16193-6e6e-73de-9ba8-b91fff490b56","cwd":"/tmp/probe"}"#,
        #"{"type":"agent_start"}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":1}}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"Running ls now."}}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":1,"content":"Running ls now."}}"#,
        #"{"type":"tool_execution_start","toolCallId":"call_1","toolName":"bash","args":{"command":"ls"}}"#,
        #"{"type":"tool_execution_end","toolCallId":"call_1","toolName":"bash","result":{"content":[{"type":"text","text":"muse.jsonl\n"}]},"isError":false}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"Done"}}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":1,"content":"Done"}}"#,
        #"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"stop"}}"#,
        #"{"type":"agent_end","messages":[]}"#,
        #"{"type":"agent_settled","aborted":false}"#,
    ]

    @Test func events() {
        #expect(run(.pi, lines) == [
            .session("01a16193-6e6e-73de-9ba8-b91fff490b56"),
            .textDelta("Running ls now."), .textEnd,
            .toolStarted(id: "call_1", name: "bash", input: "ls", arguments: #"{"command":"ls"}"#),
            .toolFinished(id: "call_1", name: "bash", output: "muse.jsonl\n", isError: false),
            .textDelta("Done"), .textEnd,
            .finished,
        ])
    }

    @Test func providerError() {
        let events = run(.pi, [#"{"type":"message_end","message":{"role":"assistant","content":[],"provider":"openrouter","stopReason":"error","errorMessage":"401: {\"message\":\"Missing Authentication header\",\"code\":401}"}}"#])
        #expect(events == [.failed(#"401: {"message":"Missing Authentication header","code":401}"#)])
    }
}

@Suite struct ThreadAssemblerTests {
    @Test func deltasJoinAndNewlinesTrim() {
        let messages = thread([.textDelta("\n\nHel"), .textDelta("lo\n"), .textEnd, .textDelta("Again")])
        #expect(messages.map(\.text) == ["Hello", "Again"])
    }

    @Test func toolFinishedWithoutStartStillShows() {
        let messages = thread([.toolFinished(id: "x", name: "Read", output: "ok", isError: false)])
        #expect(messages.count == 1)
        #expect(messages[0].toolName == "Read")
        #expect(messages[0].toolState == .done)
    }

    @Test func missingCompletionIsNotAToolFailure() {
        var messages = thread([.toolStarted(id: "x", name: "Bash", input: "sleep 9")])
        ThreadAssembler.closeRunningTools(&messages)
        #expect(messages[0].toolState == .interrupted)
    }

    /// #367: a non-zero exit is never recorded as a success, whatever the CLI said; a quiet
    /// success (exit 0, or no exit code, with no output) stays one.
    @Test func nonZeroExitIsAFailure() {
        let messages = thread([
            .toolFinished(id: "a", name: "bash", output: "", isError: false, exitCode: 2),
            .toolFinished(id: "b", name: "bash", output: "", isError: false, exitCode: 0),
            .toolFinished(id: "c", name: "Edit", output: "", isError: false),
            .toolFinished(id: "d", name: "Bash", output: "", isError: true),
        ])
        #expect(messages.map(\.toolState) == [.failed, .done, .done, .failed])
    }

    /// The call's arguments, exit code and duration reach the thread, for the chat to describe
    /// it; a call reported whole (Muse, Codex items seen only when complete) has no duration.
    @Test func toolFactsReachTheThread() {
        var assembler = ThreadAssembler()
        var messages: [ChatMessage] = []
        assembler.apply(.toolStarted(id: "r", name: "Read", input: "/a.swift", arguments: #"{"file_path":"/a.swift","limit":30,"offset":1}"#), to: &messages)
        messages[0].date = Date().addingTimeInterval(-1.5)
        assembler.apply(.toolFinished(id: "r", name: "Read", output: "ok", isError: false), to: &messages)
        assembler.apply(.toolStarted(id: "s", name: "Shell", input: "false"), to: &messages)
        assembler.apply(.toolFinished(id: "s", name: "Shell", output: "", isError: true, exitCode: 1), to: &messages)
        #expect(messages[0].toolArguments == #"{"file_path":"/a.swift","limit":30,"offset":1}"#)
        #expect((messages[0].toolDuration ?? 0) >= 1.5)
        #expect(messages[1].toolExitCode == 1)
        #expect(messages[1].toolDuration == nil)
        #expect(ToolActivity.describe(messages[0]).detail == "L1–30")
    }

    /// Threads saved before these fields still load, and new ones round-trip.
    @Test func toolFactsAreOptionalInSavedThreads() throws {
        let old = #"{"date":"2026-10-22T03:01:03Z","id":"00000000-0000-4000-8000-000000000004","role":"tool","text":"","toolID":"t1","toolInput":"ls","toolName":"Bash","toolOutput":"a\n","toolState":"done"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(ChatMessage.self, from: Data(old.utf8))
        #expect(message.toolArguments == nil && message.toolExitCode == nil && message.toolDuration == nil)
        var updated = message
        updated.toolArguments = #"{"command":"ls"}"#
        updated.toolExitCode = 0
        updated.toolDuration = 0.25
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let again = try decoder.decode(ChatMessage.self, from: encoder.encode(updated))
        #expect(again == updated)
    }

    @Test func failureEndsTheOpenReply() {
        let messages = thread([.textDelta("partial"), .failed("boom"), .textDelta("new")])
        #expect(messages.map(\.role) == [.assistant, .error, .assistant])
    }
}

// Captured 2026-10-28: Codex 0.165.0, Antigravity 1.4.9, Muse 1.4.14, Pi 1.4.0.
// Unrelated fields omitted, generation IDs made up; token counts and costs unchanged.
enum TokenUsageSamples {
    static let codex = #"{"type":"turn.completed","usage":{"input_tokens":14610,"cached_input_tokens":12160,"cache_write_input_tokens":0,"output_tokens":6,"reasoning_output_tokens":0}}"#
    static let antigravity = #"{"event":"result","result":{"status":"SUCCESS","usage":{"input_tokens":7578,"output_tokens":42,"thinking_tokens":36,"cache_read_tokens":0,"total_tokens":7620}}}"#
    static let muse = #"{"payload_type":"run.usage","payload":{"models":[{"model":"muse-wonder-full-1.0","input_tokens":27363,"cached_tokens":0,"output_tokens":61,"reasoning_tokens":50,"calls":1}]}}"#
    static let pi = [
        #"{"type":"message_end","message":{"role":"assistant","model":"deepseek/deepseek-v4.1-flash","usage":{"input":2343,"output":59,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":2402,"cost":{"input":8.013060000000001e-05,"output":8.0712e-06,"cacheRead":0,"cacheWrite":0,"total":8.82018e-05}},"responseId":"gen-sample-1","stopReason":"toolUse"}}"#,
        #"{"type":"message_end","message":{"role":"assistant","model":"deepseek/deepseek-v4.1-flash","usage":{"input":2417,"output":6,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":2423,"cost":{"input":8.26614e-05,"output":8.208e-07,"cacheRead":0,"cacheWrite":0,"total":8.34822e-05}},"responseId":"gen-sample-2","stopReason":"stop"}}"#,
        #"{"type":"agent_end"}"#,
    ]
}

@Suite struct StreamParserTests {
    private func usage(_ kind: AgentKind, _ lines: [String]) -> [TurnUsage] {
        run(kind, lines).compactMap { if case .usage(let value) = $0 { value } else { nil } }
    }

    @Test func capturedClaudeBucketsAndCost() throws {
        let value = try #require(usage(.claude, [ClaudeInputSamples.tokenUsage]).first)
        #expect(value == TurnUsage(models: [ModelUsage(model: "claude-haiku-5-5", uncachedInput: 2,
            cacheRead: 11382, cacheWrite: 9705, cacheWrite1h: 9705, output: 6, reasoning: 0)], reportedCostUSD: 0.00205802))
        // Acceptance example from #280, in the captured wire shape.
        let example = ClaudeInputSamples.tokenUsage.replacingOccurrences(of: "9705", with: "8673")
            .replacingOccurrences(of: "0.00205802", with: "0.00185062")
        let expected = try #require(usage(.claude, [example]).first)
        #expect(expected.models.first?.cacheWrite == 8673)
        #expect(expected.models.first?.cacheWrite1h == 8673)
        #expect(expected.models.first?.cacheRead == 11382)
        #expect(expected.reportedCostUSD == 0.00185062)
    }

    @Test func claudePrefersTurnMapAndFallsBackToLegacyMap() throws {
        var object = try #require(decode(ClaudeInputSamples.tokenUsage))
        object["modelUsage"] = ["old-model": ["inputTokens": 9999]]
        let line = summarizeToolInput(object)
        #expect(usage(.claude, [line]).first?.models.first?.model == "claude-haiku-5-5")
        object.removeValue(forKey: "model_usage_since_last_result")
        #expect(usage(.claude, [summarizeToolInput(object)]).first?.models == [ModelUsage(model: "old-model", uncachedInput: 9999)])
        object["model_usage_since_last_result"] = [String: Int]()
        #expect(usage(.claude, [summarizeToolInput(object)]).isEmpty)
    }

    @Test func codexCumulativeIncludesCachedInput() throws {
        let captured = try #require(usage(.codex, [TokenUsageSamples.codex]).first)
        #expect(captured.models == [ModelUsage(model: "", uncachedInput: 2450, cacheRead: 12160, cacheWrite: 0, output: 6, reasoning: 0)])
        #expect(captured.cumulative)
        let example = #"{"type":"turn.completed","usage":{"input_tokens":39555,"cached_input_tokens":31744}}"#
        #expect(usage(.codex, [example]) == [TurnUsage(models: [ModelUsage(model: "", uncachedInput: 7811, cacheRead: 31744)], cumulative: true)])
    }

    @Test func antigravityAndMuseKeepReasoningInsideOutput() throws {
        #expect(usage(.antigravity, [TokenUsageSamples.antigravity]) == [TurnUsage(models: [
            ModelUsage(model: "", uncachedInput: 7578, cacheRead: 0, output: 42, reasoning: 36)], cumulative: true)])
        #expect(usage(.muse, [TokenUsageSamples.muse]) == [TurnUsage(models: [
            ModelUsage(model: "muse-wonder-full-1.0", uncachedInput: 27363, cacheRead: 0, output: 61, reasoning: 50)])])
        #expect(usage(.antigravity, TokenUsageSamples.antigravityCached) == [TurnUsage(models: [
            ModelUsage(model: "", uncachedInput: 9835, cacheRead: 5520, output: 966, reasoning: 918)], cumulative: true)])
    }

    @Test func antigravityResumedResultIsCumulativeNotItsLastStep() {
        let first = usage(.antigravity, TokenUsageSamples.antigravityResumed[0])
        let resumed = usage(.antigravity, TokenUsageSamples.antigravityResumed[1])
        #expect(first == [TurnUsage(models: [ModelUsage(model: "", uncachedInput: 7583, cacheRead: 0, output: 46, reasoning: 41)], cumulative: true)])
        #expect(resumed == [TurnUsage(models: [ModelUsage(model: "", uncachedInput: 9899, cacheRead: 5529, output: 91, reasoning: 80)], cumulative: true)])
    }

    @Test func piAggregatesAssistantRequestsOnceAndResets() throws {
        var parser = PiParser()
        for line in TokenUsageSamples.pi.dropLast() { #expect(parser.parse(line: line).isEmpty) }
        let events = parser.parse(line: TokenUsageSamples.pi.last!)
        let value = try #require(events.compactMap { if case .usage(let v) = $0 { v } else { nil } }.first)
        #expect(events.count == 2)
        #expect(value.models == [ModelUsage(model: "deepseek/deepseek-v4.1-flash", uncachedInput: 4760,
            cacheRead: 0, cacheWrite: 0, output: 65, reasoning: 0)])
        #expect(abs((value.reportedCostUSD ?? 0) - 0.000171684) < 1e-12)
        #expect(value.generationIDs == ["gen-sample-1", "gen-sample-2"])
        #expect(parser.parse(line: #"{"type":"agent_end"}"#) == [.finished])
    }

    @Test func piRetainsMissingResponseIDsWithoutInventingUsage() throws {
        let missing = #"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"stop"}}"#
        let value = try #require(usage(.pi, [TokenUsageSamples.pi[0], missing, #"{"type":"agent_end"}"#]).first)
        #expect(value.generationIDs == ["gen-sample-1", "unrecorded"])
        #expect(usage(.pi, [missing, #"{"type":"agent_end"}"#]).isEmpty)
        for id in ["", "private/path", "invalid space"] {
            let line = "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"responseId\":\"\(id)\",\"usage\":{\"output\":1}}}"
            #expect(usage(.pi, [line, #"{"type":"agent_end"}"#]).first?.generationIDs == ["unrecorded"])
        }
    }

    @Test func piSeparatesModelsAndIgnoresUserUsage() {
        let lines = [
            #"{"type":"message_end","message":{"role":"user","usage":{"input":900}}}"#,
            #"{"type":"message_end","message":{"role":"assistant","model":"a","usage":{"input":3}}}"#,
            #"{"type":"message_end","message":{"role":"assistant","model":"b","usage":{"output":4}}}"#,
            #"{"type":"agent_end"}"#,
        ]
        #expect(usage(.pi, lines) == [TurnUsage(models: [ModelUsage(model: "a", uncachedInput: 3), ModelUsage(model: "b", output: 4)], generationIDs: ["unrecorded", "unrecorded"])])
    }

    @Test func missingMalformedAndExplicitZeroStayDistinct() {
        for (kind, line) in [(AgentKind.claude, #"{"type":"result"}"#), (.codex, #"{"type":"turn.completed","usage":{}}"#),
            (.antigravity, #"{"event":"result","result":{"status":"SUCCESS"}}"#), (.muse, #"{"payload_type":"run.usage","payload":{"models":[]}}"#),
            (.pi, #"{"type":"agent_end"}"#), (.sail, SailEvent.finished.line)] {
            #expect(usage(kind, [line]).isEmpty)
        }
        #expect(usage(.codex, [#"{"type":"turn.completed","usage":{"input_tokens":true,"output_tokens":-2}}"#]).isEmpty)
        #expect(usage(.codex, [#"{"type":"turn.completed","usage":{"input_tokens":0}}"#]).first?.models == [ModelUsage(model: "", uncachedInput: 0)])
    }

    @Test func usageDoesNotChangeTranscriptOrEndText() {
        var assembler = ThreadAssembler()
        var messages: [ChatMessage] = []
        assembler.apply(.textDelta("hello"), to: &messages)
        assembler.apply(.usage(TurnUsage(models: [])), to: &messages)
        assembler.apply(.textDelta(" world"), to: &messages)
        #expect(messages.count == 1)
        #expect(messages.first?.text == "hello world")
    }

    @Test func aggregationDoesNotOverflowOrAddCumulativeReports() {
        var accumulator = TurnUsageAccumulator()
        let large = TurnUsage(models: [ModelUsage(model: "a", uncachedInput: Int.max / 2 + 1, output: 1)], reportedCostUSD: Double.greatestFiniteMagnitude)
        accumulator.add(large)
        accumulator.add(large)
        accumulator.add(large)
        #expect(accumulator.value?.models.first?.uncachedInput == nil)
        #expect(accumulator.value?.models.first?.output == 3)
        #expect(accumulator.value?.reportedCostUSD == nil)
        let cumulative = TurnUsage(models: [ModelUsage(model: "a", uncachedInput: 100)], cumulative: true)
        accumulator.add(cumulative)
        accumulator.add(cumulative)
        #expect(accumulator.value == cumulative)
    }

    @Test func usageBeforeFailureIsRetained() {
        let claude = ClaudeInputSamples.tokenUsage.replacingOccurrences(of: "\"is_error\":false", with: "\"is_error\":true")
        #expect(usage(.claude, [claude]).count == 1)
        #expect(usage(.antigravity, [#"{"event":"error","message":"failed"}"#, TokenUsageSamples.antigravity]).count == 1)
    }

    /// Opt-in, no timing threshold: full parsing and isolated usage extraction from decoded JSON.
    @Test func usageParserBenchmark() throws {
        guard let path = ProcessInfo.processInfo.environment["BOTCHU_USAGE_PARSER_BENCHMARK"] else { return }
        let samples: [(AgentKind, [String])] = [(.claude, [ClaudeInputSamples.tokenUsage]), (.codex, [TokenUsageSamples.codex]),
            (.antigravity, [TokenUsageSamples.antigravity]), (.muse, [TokenUsageSamples.muse]), (.pi, TokenUsageSamples.pi)]
        var results = "Parser: microseconds per complete turn (20000 iterations); JSON decoding included\n"
        for (kind, lines) in samples {
            let start = Date()
            var count = 0
            for _ in 0..<20_000 { count += run(kind, lines).count }
            let full = Date().timeIntervalSince(start) * 1_000_000 / 20_000
            let objects = lines.compactMap(decode)
            let extraction = Date()
            var usages = 0
            for _ in 0..<20_000 {
                var accumulator = TurnUsageAccumulator()
                for object in objects {
                    let value: TurnUsage?
                    switch kind {
                    case .claude: value = UsageParsing.claude(object)
                    case .codex: value = UsageParsing.codex(object)
                    case .antigravity: value = UsageParsing.antigravity(object["result"] as? JSON)
                    case .muse: value = UsageParsing.muse(object["payload"] as? JSON ?? [:])
                    case .pi: value = UsageParsing.pi(object["message"] as? JSON ?? [:])
                    case .sail: value = nil
                    }
                    if let value { accumulator.add(value) }
                }
                usages += accumulator.value?.models.count ?? 0
            }
            let added = Date().timeIntervalSince(extraction) * 1_000_000 / 20_000
            results += "\(kind.rawValue): full \(full) us; usage extraction/aggregation \(added) us; events \(count), models \(usages)\n"
        }
        try results.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// Captured agy 1.4.9 on 2026-10-28 after a shell call. Its input_tokens already
// excludes cache_read_tokens: the second step reports 2261 input and 5520 cached.
// Final usage adds each step; total_tokens here is input + output, also excluding cache.
extension TokenUsageSamples {
    static let antigravityCached = [
        #"{"event":"step_update","step_update":{"step_index":1,"step_type":"agent_response","usage":{"input_tokens":7574,"output_tokens":105,"thinking_tokens":63,"cache_read_tokens":0,"total_tokens":7679}}}"#,
        #"{"event":"step_update","step_update":{"step_index":3,"step_type":"agent_response","usage":{"input_tokens":2261,"output_tokens":861,"thinking_tokens":855,"cache_read_tokens":5520,"total_tokens":3122}}}"#,
        #"{"event":"result","result":{"status":"SUCCESS","usage":{"input_tokens":9835,"output_tokens":966,"thinking_tokens":918,"cache_read_tokens":5520,"total_tokens":10801}}}"#,
    ]
}

// Captured new and resumed agy 1.4.9 turns, 2026-10-28, no tools.
// The resumed step is 2316 input / 45 output but result is 9899 / 91: result usage
// is cumulative for its UUID conversation, including the first turn's 7583 / 46.
extension TokenUsageSamples {
    static let antigravityResumed = [
        [
            #"{"event":"step_update","step_update":{"step_index":1,"step_type":"agent_response","usage":{"input_tokens":7583,"output_tokens":46,"thinking_tokens":41,"cache_read_tokens":0,"total_tokens":7629}}}"#,
            #"{"event":"result","result":{"status":"SUCCESS","usage":{"input_tokens":7583,"output_tokens":46,"thinking_tokens":41,"cache_read_tokens":0,"total_tokens":7629},"num_turns":1}}"#,
        ],
        [
            #"{"event":"step_update","step_update":{"step_index":4,"step_type":"agent_response","usage":{"input_tokens":2316,"output_tokens":45,"thinking_tokens":39,"cache_read_tokens":5529,"total_tokens":2361}}}"#,
            #"{"event":"result","result":{"status":"SUCCESS","usage":{"input_tokens":9899,"output_tokens":91,"thinking_tokens":80,"cache_read_tokens":5529,"total_tokens":9990},"num_turns":2}}"#,
        ],
    ]
}
