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
            .toolFinished(id: "step-2", name: "run_command", output: "Command exited with code 0.\n\nNo output from the command.", isError: false),
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
