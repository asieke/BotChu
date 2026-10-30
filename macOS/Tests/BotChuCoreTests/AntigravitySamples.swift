// Real Antigravity 1.4.11 `-p --output-format stream-json` stdout on the google account,
// captured 2026-10-30 with BotChu's own flags (#367). Conversation IDs replaced with "c", the
// probe folder shortened to /tmp/probe, and the bad-model error's list of models trimmed.
enum AntigravitySamples {
    // The stream carries neither a search's results nor a read's text, yet the model got both:
    // asked in the same run, it listed a vertexaisearch.cloud.google.com grounding URL among the
    // results, and quoted line 205's random token from a 400-line file read as lines 200–210.
    // "400 lines, 6292 bytes" is agy's summary of every read, whole file or range.
    static let searchAndRangeRead = [
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"search_web","tool_info":{"name":"search_web","parameters":{"query":"Swift 6 release date"}}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":2,"state":"DONE","step_type":"tool","tool_name":"search_web","duration_seconds":1.586824,"tool_info":{"name":"search_web","parameters":{"query":"Swift 6 release date"}}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":4,"state":"ACTIVE","step_type":"tool","tool_name":"read_file","tool_info":{"name":"read_file","parameters":{"EndLine":210,"Path":"/tmp/probe/big.txt","StartLine":200}}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":4,"state":"DONE","step_type":"tool","tool_name":"read_file","duration_seconds":0.044594,"tool_info":{"name":"read_file","parameters":{"EndLine":210,"Path":"/tmp/probe/big.txt","StartLine":200},"output":"400 lines, 6292 bytes"}}}"#,
        // A range past the end is clamped: the model got "Showing lines 2-2 of 2".
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":6,"state":"DONE","step_type":"tool","tool_name":"read_file","duration_seconds":0.032065,"tool_info":{"name":"read_file","parameters":{"EndLine":950,"Path":"/tmp/probe/small.txt","StartLine":900},"output":"2 lines, 11 bytes"}}}"#,
    ]

    // A failed call ends ERROR with agy's reason in tool_info.error; the model saw
    // "Encountered error in tool execution: file does not exist".
    static let failedReads = [
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":2,"state":"ERROR","step_type":"tool","tool_name":"read_file","duration_seconds":0.005566,"tool_info":{"name":"read_file","parameters":{"Path":"/tmp/probe/does-not-exist.txt"},"error":{"type":"TOOL_ERROR","message":"file does not exist"}}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":4,"state":"ERROR","step_type":"tool","tool_name":"read_file","duration_seconds":0.033523,"tool_info":{"name":"read_file","parameters":{"Path":"/tmp/probe/adir"},"error":{"type":"TOOL_ERROR","message":"path is a directory, not a file"}}}}"#,
    ]

    // Every command ends DONE; only the output says how it exited.
    static let shell = [
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":2,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":1.487237,"tool_info":{"name":"run_command","parameters":{"CommandLine":"mkdir made"},"output":"Command exited with code 0.\n\nNo output from the command."}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":4,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":0.014716,"tool_info":{"name":"run_command","parameters":{"CommandLine":"grep zzz small.txt"},"output":"Command exited with code 1.\n\nNo output from the command."}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":6,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":0.015097,"tool_info":{"name":"run_command","parameters":{"CommandLine":"ls /nonexistent-367"},"output":"Command exited with code 1.\n\nCommand output:\nls: /nonexistent-367: No such file or directory\r\n"}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":8,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":0.050668,"tool_info":{"name":"run_command","parameters":{"CommandLine":"true"},"output":"Command exited with code 0.\n\nNo output from the command."}}}"#,
    ]

    // `seq 1 60000; exit 3`: agy shortens a long output and puts a note before it. The middle of
    // the preview is cut further here, and the home folder renamed.
    static let truncated = #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":2,"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"seq 1 60000; exit 3"},"output":"The tool's output was truncated due to being too long. You can find the full output in a file at file:///Users/me/.gemini/antigravity-cli/brain/c/.system_generated/steps/2/output.txt.\n\nHere is a preview with the middle of the output truncated:\nCommand exited with code 3.\n\nCommand output:\n1\r\n2\r\n3\r\n59998\r\n59999\r\n60000\r\n"}}}"#

    // `--model bogus-model-xyz`: the only line on stdout (exit 1).
    static let badModel = #"{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"invalid model selection (--model \"bogus-model-xyz\" --effort \"\"): model bogus-model-xyz is not recognized as a known model or custom model in settings\nAvailable models:\n  Gemini 4 Argon (Medium)\n  GPT-OSS 120B (Medium)","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"finished_reason":"error"}}"#
}
