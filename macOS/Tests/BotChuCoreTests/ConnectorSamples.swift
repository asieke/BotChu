import Foundation

/// Native connector discovery captured on 2026-10-26 (#183), sanitized: session, app and request
/// ids are made up, paths are placeholders, endpoints (`httpOrigin`) are null, tool catalogs are
/// cut to a stub or two, and the init keeps only the fields the parser reads beside a few others.
/// Server and connector names are as reported.
enum ConnectorSamples {
    /// Claude Code 2.1.311 `-p --output-format stream-json --verbose`, `claude-personal`: its
    /// `system/init` line (claude.ai connectors and a plugin's server).
    static let claudeInit = #"""
    {"type":"system","subtype":"init","cwd":"/Users/me/bots/scout","session_id":"7f1c2a9e-0b3d-4c55-9a61-2e8f0d4b7c10","tools":["Bash","Read","Edit","mcp__claude_ai_Claude_Docs__batch","mcp__claude_ai_Claude_Docs__guide","mcp__claude_ai_Linear__get_issue","mcp__claude_ai_Gmail__search_threads","mcp__claude_ai_Gmail__get_thread","mcp__claude_ai_Google_Drive__search_files"],"mcp_servers":[{"name":"plugin:github:github","status":"failed","source":"plugin"},{"name":"claude.ai Claude Docs","status":"connected","source":"claudeai"},{"name":"claude.ai Slack","status":"needs-auth","source":"claudeai"},{"name":"claude.ai Agora MCP","status":"needs-auth","source":"claudeai"},{"name":"claude.ai Linear","status":"connected","source":"claudeai"},{"name":"claude.ai Google Drive","status":"connected","source":"claudeai"},{"name":"claude.ai Google Calendar","status":"needs-auth","source":"claudeai"},{"name":"claude.ai Gmail","status":"connected","source":"claudeai"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"none","claude_code_version":"2.1.311"}
    """#

    /// Claude Code 2.1.311 `mcp list`, `claude-personal`, in a bot's folder. Targets (URLs and
    /// commands) are replaced with placeholders, and the request id in an error is made up.
    static let claudeList = """
    Checking MCP server health…

    claude.ai Claude Docs: https://connector.example/docs - ✔ Connected
    claude.ai Slack: https://connector.example/slack - ! Needs authentication
    claude.ai Agora MCP: https://connector.example/agora - ✘ Failed to connect — HTTP 404: Error POSTing to endpoint: {"type":"error","error":{"type":"not_found_error","message":"No MCP endpoint was found at the URL provided."},"request_id":"req_0000"}
    claude.ai Linear: https://connector.example/linear - ✔ Connected
    claude.ai Google Drive: https://connector.example/drive - ✔ Connected
    claude.ai Google Calendar: https://connector.example/calendar - ✔ Connected
    claude.ai Gmail: https://connector.example/gmail - ✔ Connected
    plugin:github:github: https://mcp.example/ (HTTP) - ✘ Failed to connect — HTTP 400: Error POSTing to endpoint: bad request: Authorization header is badly formatted
    """

    /// The same Claude Code with an empty config, then with servers of its own: a project's
    /// unapproved `.mcp.json` server, a command that can't start and a URL that refuses.
    static let claudeListEmpty = "No MCP servers configured. Use `claude mcp add` to add a server.\n"
    static let claudeListLocal = """
    Checking MCP server health…

    broken: /bin/false  - ✘ Failed to connect — ENOENT: no such file or directory, posix_spawn '/bin/false'
    remote-docs: http://127.0.0.1:9/mcp (HTTP) - ✘ Failed to connect — ECONNREFUSED: Unable to connect. Is the computer able to access the url?
    local-notes: /bin/echo hi - ⏸ Pending approval (run `claude` to approve)
    """

    /// Claude Code 2.1.311 as BotChu runs it, with `--input-format stream-json`: the init comes
    /// before most connectors have connected, and the claude.ai ones can be missing from it.
    static let claudeLiveInit = #"""
    {"type":"system","subtype":"init","cwd":"/Users/me/bots/scout","session_id":"0d6e4f21-9c8b-4a7e-b3f2-5a1c9e8d7b60","tools":["Bash","Read"],"mcp_servers":[{"name":"plugin:github:github","status":"pending","source":"plugin"}],"claude_code_version":"2.1.311"}
    """#

    /// Codex 0.164.0 `app-server`, `codex-personal`: `mcpServerStatus/list` with
    /// `detail: toolsAndAuthOnly` (one page; `nextCursor` null).
    static let codexServers = #"""
    {"data":[{"name":"circleback","authStatus":"oAuth","runtimeStatus":null,"pluginId":null,"httpOrigin":null,"serverInfo":{"name":"circleback-mcp"},"serverCapabilities":{"tools":{}},"toolListMeta":null,"tools":{"search_meetings":{"name":"search_meetings","inputSchema":{"type":"object"}},"get_meeting":{"name":"get_meeting","inputSchema":{"type":"object"}}},"toolsError":null,"resources":[],"resourceTemplates":[]},{"name":"codex_apps","authStatus":"bearerToken","runtimeStatus":null,"pluginId":null,"httpOrigin":null,"serverInfo":{"name":"plugin-runtime"},"serverCapabilities":{"tools":{}},"toolListMeta":null,"tools":{"gmail_search":{"name":"gmail_search","inputSchema":{"type":"object"}}},"toolsError":null,"resources":[],"resourceTemplates":[]},{"name":"computer-use","authStatus":"unsupported","runtimeStatus":null,"pluginId":null,"httpOrigin":null,"serverInfo":null,"serverCapabilities":null,"toolListMeta":null,"tools":{},"toolsError":null,"resources":[],"resourceTemplates":[]},{"name":"knowledge-bridge","authStatus":"notLoggedIn","runtimeStatus":null,"pluginId":null,"httpOrigin":null,"serverInfo":null,"serverCapabilities":null,"toolListMeta":null,"tools":{},"toolsError":"MCP startup failed: OAuth authorization required","resources":[],"resourceTemplates":[]},{"name":"link","authStatus":"unsupported","runtimeStatus":null,"pluginId":null,"httpOrigin":null,"serverInfo":{"name":"link-cli","version":"0.30.0"},"serverCapabilities":{"tools":{"listChanged":true}},"toolListMeta":null,"tools":{"get_tool_details":{"name":"get_tool_details","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}},"search_tools":{"name":"search_tools","inputSchema":{"type":"object"}},"call_tool":{"name":"call_tool","inputSchema":{"type":"object"}},"list_tools":{"name":"list_tools","inputSchema":{"type":"object"}}},"toolsError":null,"resources":[],"resourceTemplates":[]}],"nextCursor":null}
    """#

    /// Codex 0.164.0 `app/installed` with `forceRefresh: true`, cut to five of its 24 apps.
    static let codexInstalled = #"""
    {"apps":[{"id":"asdk_app_0001","runtimeName":"Linear","enabled":true,"callable":true},{"id":"connector_0002","runtimeName":"Gmail","enabled":true,"callable":true},{"id":"connector_0003","runtimeName":"Google Drive","enabled":true,"callable":true},{"id":"connector_0004","runtimeName":"GitHub","enabled":true,"callable":true},{"id":"connector_0005","runtimeName":"Search Service","enabled":true,"callable":true}]}
    """#

    /// Codex 0.164.0 `app-server`, `codex-personal`, captured again on 2026-10-27 (#212) with
    /// only these fields printed: third-party app ids are made up, Codex's own (`connector_openai_…`)
    /// are as reported, tool catalogs are stubs of the reported size or less. Its own apps and the
    /// link and node_repl servers are the provider's, Computer Use lists no tools outside a thread,
    /// and a service can come both as an app and as a server of the owner's. The `cua_repl` server,
    /// the bundled computer-use runtime, is as `codex-dev` reported it the same day.
    static let codexInstalledSystem = #"""
    {"apps":[{"id":"asdk_app_0001","runtimeName":"Circleback","enabled":true,"callable":true},{"id":"connector_0011","runtimeName":"Sites","enabled":true,"callable":true},{"id":"connector_0012","runtimeName":"Gmail","enabled":true,"callable":true},{"id":"connector_openai_chatgpt_pets","runtimeName":"Pets","enabled":true,"callable":true},{"id":"connector_openai_codex_document_control","runtimeName":"Codex Document Control","enabled":true,"callable":true},{"id":"connector_openai_hotline","runtimeName":"Hotline","enabled":true,"callable":true},{"id":"connector_openai_search_service","runtimeName":"Search Service","enabled":true,"callable":true}]}
    """#
    static let codexServersSystem = #"""
    {"data":[{"name":"circleback","authStatus":"oAuth","runtimeStatus":null,"pluginId":null,"tools":{"search_meetings":{},"get_meeting":{}},"toolsError":null},{"name":"codex_apps","authStatus":"bearerToken","runtimeStatus":null,"pluginId":null,"tools":{"gmail_search":{}},"toolsError":null},{"name":"computer-use","authStatus":"unsupported","runtimeStatus":null,"pluginId":null,"tools":{},"toolsError":null},{"name":"cua_repl","authStatus":"unsupported","runtimeStatus":null,"pluginId":null,"tools":{},"toolsError":null},{"name":"knowledge-bridge","authStatus":"notLoggedIn","runtimeStatus":null,"pluginId":null,"tools":{},"toolsError":"MCP startup failed: OAuth authorization required"},{"name":"link","authStatus":"unsupported","runtimeStatus":null,"pluginId":null,"tools":{"a":{},"b":{},"c":{},"d":{}},"toolsError":null},{"name":"node_repl","authStatus":"unsupported","runtimeStatus":null,"pluginId":null,"tools":{"a":{},"b":{},"c":{},"d":{}},"toolsError":null}],"nextCursor":null}
    """#

    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }
}
