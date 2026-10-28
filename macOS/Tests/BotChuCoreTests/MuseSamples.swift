// Sanitized real Muse Code 1.4.14 `exec --json` stdout, captured 2026-10-28.
// Capture: --no-session-log --approval-mode untrusted, a harmless shell tool.
// Only command acceptance, tool side-effect/result, text and terminal records retained.
// Prompts and unrelated telemetry omitted; all runtime identifiers replaced with placeholders.
// The automatic approval judge allowed this call. A second capture with --approval-judge off
// stopped after tool.bash was proposed: no approval or approval-wait record appeared on stdout
// before the 55-second timeout. Approval regression records are synthetic, not this capture.
enum MuseSamples {
    static let toolTurn = [
        #"{"schema_version":1,"id":"id-1","stream":{"kind":"session","id":"id-2"},"sequence":1,"recorded_at":1780531400000000,"record_type":"reconciliation","durability":"durable","causation_id":"id-3","payload_type":"runtime.command.accepted","payload_schema_version":1,"payload":{"kind":"command_accepted","command_id":"id-3","client_id":null,"command_kind":"turn.submit"}}"#,
        #"{"schema_version":1,"id":"id-4","stream":{"kind":"session","id":"id-2"},"sequence":25,"recorded_at":1780531400000046,"record_type":"event","durability":"durable","causation_id":"id-3","payload_type":"task.lifecycle.side_effect_intent","payload_schema_version":1,"payload":{"kind":"task_lifecycle","command_id":"id-3","run_stream":{"kind":"run","id":"id-3"},"task_stream":{"kind":"task","id":"id-5"},"task_id":"id-5","event":{"kind":"side_effect_intent","task_id":"id-5","operation":"tool:bash","idempotency_key":"tool:id-6","policy_decision":"allow:llm_judge","cancellation_handle":null,"parent_task_id":null}}}"#,
        #"{"schema_version":1,"id":"id-7","stream":{"kind":"session","id":"id-2"},"sequence":29,"recorded_at":1780531400000054,"record_type":"event","durability":"durable","causation_id":"id-3","payload_type":"tool.result","payload_schema_version":1,"payload":{"kind":"tool_result","command_id":"id-3","run_stream":{"kind":"run","id":"id-3"},"call_id":"id-6","text":"{\n  \"chunk_id\": \"chunk\",\n  \"command\": \"printf tool-ok\",\n  \"description\": \"Print tool-ok string\",\n  \"exit_code\": 0,\n  \"terminal_status\": \"completed\",\n  \"output\": \"tool-ok\",\n  \"original_output_bytes\": 7,\n  \"original_output_tokens\": 2,\n  \"truncated\": false\n}","correlation_facts":{"tool_name":"bash","outcome":"success"}}}"#,
        #"{"schema_version":1,"id":"id-8","stream":{"kind":"session","id":"id-2"},"sequence":44,"recorded_at":1780531400000084,"record_type":"status","durability":"ephemeral","causation_id":"id-3","payload_type":"run.output.delta","payload_schema_version":1,"payload":{"kind":"run_output_delta","command_id":"id-3","run_stream":{"kind":"run","id":"id-3"},"text":"Done"}}"#,
        #"{"schema_version":1,"id":"id-9","stream":{"kind":"session","id":"id-2"},"sequence":62,"recorded_at":1780531400000120,"record_type":"event","durability":"durable","causation_id":"id-3","payload_type":"run.terminal.completed","payload_schema_version":1,"payload":{"kind":"run_terminal","command_id":"id-3","run_stream":{"kind":"run","id":"id-3"},"terminal":"completed","text":"Done","reason":null}}"#,
    ]
}
