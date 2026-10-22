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
            .toolStarted(id: "toolu_1", name: "Bash", input: "ls"),
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
            .toolFinished(id: "item_1", name: "Shell", output: "", isError: false),
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
            .toolFinished(id: "i", name: "Shell", output: "", isError: true),
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
            .toolStarted(id: "step-2", name: "run_command", input: "ls"),
            .toolStarted(id: "step-2", name: "run_command", input: "ls"),
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

    @Test func failedResult() {
        let events = run(.antigravity, [#"{"event":"result","result":{"status":"ERROR","response":""}}"#])
        #expect(events == [.failed("Antigravity stopped: ERROR.")])
    }
}

@Suite struct MuseParserTests {
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
            .toolStarted(id: "call_1", name: "bash", input: "ls"),
            .toolFinished(id: "call_1", name: "bash", output: "muse.jsonl\n", isError: false),
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
            .toolStarted(id: "call_1", name: "bash", input: "ls"),
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

    @Test func failureEndsTheOpenReply() {
        let messages = thread([.textDelta("partial"), .failed("boom"), .textDelta("new")])
        #expect(messages.map(\.role) == [.assistant, .error, .assistant])
    }
}
