import Foundation
import Testing
@testable import BotChuCore

@Suite struct AntigravitySubagentTests {
    // Captured from agy on 2026-10-22 in an isolated three-worker arithmetic run.
    // Only conversation ids and local paths are sanitized. The terminal event changes type.
    let lines = [
        #"{"event":"step_update","step_update":{"conversation_id":"parent","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"invoke_subagent","tool_info":{"name":"invoke_subagent","parameters":{"Role":"Compute 2+3","TypeName":"self"}}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"parent","step_index":2,"state":"DONE","step_type":"subagent","tool_name":"invoke_subagent","duration_seconds":1.7857910000000001,"subagent_info":{"subagents":[{"type_name":"self","role":"Compute 2+3","initial_prompt":"Compute 2+3 and return just the number. Do not read files or do external research.","conversation_id":"child-2"}]}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"parent","step_index":3,"state":"ACTIVE","step_type":"tool","tool_name":"invoke_subagent","tool_info":{"name":"invoke_subagent","parameters":{"Role":"Compute 5+7","TypeName":"self"}}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"parent","step_index":3,"state":"DONE","step_type":"subagent","tool_name":"invoke_subagent","duration_seconds":2.814385,"subagent_info":{"subagents":[{"type_name":"self","role":"Compute 5+7","initial_prompt":"Compute 5+7 and return just the number. Do not read files or do external research.","conversation_id":"child-3"}]}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"parent","step_index":4,"state":"ACTIVE","step_type":"tool","tool_name":"invoke_subagent","tool_info":{"name":"invoke_subagent","parameters":{"Role":"Compute 11+13","TypeName":"self"}}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"parent","step_index":4,"state":"DONE","step_type":"subagent","tool_name":"invoke_subagent","duration_seconds":3.691554,"subagent_info":{"subagents":[{"type_name":"self","role":"Compute 11+13","initial_prompt":"Compute 11+13 and return just the number. Do not read files or do external research.","conversation_id":"child-4"}]}}}"#,
    ]

    @Test func launchCompletionChangesStepType() {
        var parser = AntigravityParser()
        var assembler = ThreadAssembler()
        var messages: [ChatMessage] = []
        for line in lines {
            for event in parser.parse(line: line) { assembler.apply(event, to: &messages) }
        }
        ThreadAssembler.closeRunningTools(&messages)
        #expect(messages.count == 3)
        #expect(messages.allSatisfy { $0.toolState == .done })
        #expect(messages.map(\.toolInput) == ["Compute 2+3", "Compute 5+7", "Compute 11+13"])
        #expect(messages[0].toolOutput?.contains("child-2") == true)
    }

    @Test(arguments: ["ERROR", "CANCELED"])
    func unsuccessfulSubagentLaunch(state: String) {
        var parser = AntigravityParser()
        let line = lines[1].replacingOccurrences(of: "DONE", with: state)
        let events = parser.parse(line: line)
        #expect(events.contains { if case .toolFinished(_, _, _, let error, _) = $0 { return error }; return false })
    }
}
