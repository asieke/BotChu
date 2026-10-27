import Foundation
import Testing
@testable import BotChuCore

@Suite struct ConnectorParsingTests {
    @Test func claudeInitReportsItsConnectorsBesideTheSession() {
        var parser = ClaudeParser()
        let events = parser.parse(line: ConnectorSamples.claudeInit)
        #expect(events.first == .session("7f1c2a9e-0b3d-4c55-9a61-2e8f0d4b7c10"))
        guard case .connectors(let connectors) = events.last else { Issue.record("No connectors in \(events)"); return }
        let report = ConnectorReport(connectors: connectors)
        #expect(report.connected.map(\.name) == ["Claude Docs", "Gmail", "Google Drive", "Linear"])
        #expect(report.rows.map(\.state) == [.needsAuth, .failed])
        #expect(report.rows[0].connectors.map(\.name) == ["Agora MCP", "Google Calendar", "Slack"])
        #expect(report.rows[1].connectors.map(\.name) == ["github"])
        #expect(report.rows[1].connectors[0].origin == .plugin)
        let gmail = connectors.first { $0.name == "Gmail" }
        #expect(gmail?.origin == .claudeAI)
        #expect(gmail?.toolCount == 2)
        #expect(gmail?.detail == "claude.ai connector · 2 tools listed")
        // A failed or unsigned server's tool count isn't reported as zero.
        #expect(connectors.first { $0.name == "Slack" }?.toolCount == nil)
    }

    @Test func claudeInitStatesFollowTheSDKContract() {
        // The documented statuses beyond the capture: pending can still connect; disabled is off.
        let event = ConnectorSamples.object(#"""
        {"type":"system","subtype":"init","session_id":"s","mcp_servers":[{"name":"postgres","status":"pending"},{"name":"notion","status":"disabled"},{"name":"later","status":"some-new-state"},{"name":""}]}
        """#)
        let connectors = ConnectorParser.claudeInit(event) ?? []
        #expect(connectors.map(\.state) == [.unconfirmed, .off, .unconfirmed])
        #expect(connectors.allSatisfy { $0.origin == .mcpServer })
    }

    @Test func anInitWithoutTheListIsUnknownAndAnEmptyListIsNone() {
        // An older Claude Code's init says nothing about connectors: no event, so nothing claims none.
        var parser = ClaudeParser()
        #expect(parser.parse(line: #"{"type":"system","subtype":"init","session_id":"s1"}"#) == [.session("s1")])
        var empty = ClaudeParser()
        #expect(empty.parse(line: #"{"type":"system","subtype":"init","session_id":"s2","mcp_servers":[]}"#) == [.session("s2"), .connectors([])])
    }

    @Test func claudeMcpListKeepsNamesAndStatesOnly() throws {
        let connectors = try ConnectorParser.claudeList(ConnectorSamples.claudeList)
        let report = ConnectorReport(connectors: connectors)
        #expect(report.connected.map(\.name) == ["Claude Docs", "Gmail", "Google Calendar", "Google Drive", "Linear"])
        #expect(report.rows.map(\.state) == [.needsAuth, .failed])
        #expect(report.rows[1].connectors.map(\.name) == ["Agora MCP", "github"])
        #expect(connectors.first { $0.name == "github" }?.origin == .plugin)
        #expect(connectors.first { $0.name == "Slack" }?.origin == .claudeAI)
        // No endpoint, command or error text is kept.
        let kept = connectors.map { "\($0.name) \($0.detail)" }.joined()
        #expect(!kept.contains("example") && !kept.contains("HTTP") && !kept.contains("req_"))

        let local = try ConnectorParser.claudeList(ConnectorSamples.claudeListLocal)
        #expect(local.map(\.name) == ["broken", "remote-docs", "local-notes"])
        #expect(local.map(\.state) == [.failed, .failed, .unconfirmed])
        #expect(local.allSatisfy { $0.origin == .mcpServer })

        // Nothing configured is none; output BotChu can't read is a failure, never none.
        #expect(try ConnectorParser.claudeList(ConnectorSamples.claudeListEmpty).isEmpty)
        #expect(throws: ConnectorFailure.self) { try ConnectorParser.claudeList("Error: something new\n") }
        #expect(throws: ConnectorFailure.self) { try ConnectorParser.claudeList("") }
    }

    @Test func claudeMcpListStatesFromTheInstalledVersion() throws {
        // The statuses Claude Code 2.1.311 prints beside those captured.
        let output = """
        a: x - ! Connected · tools fetch failed
        b: x - ⊘ Disabled for this project (re-enable via /mcp)
        c: x - ✘ Rejected (see disabledMcpjsonServers in settings)
        d: x - - Not configured
        e: x - ✘ Connection error
        f: a - b - ✔ Connected
        """
        #expect(try ConnectorParser.claudeList(output).map(\.state) == [.unconfirmed, .off, .off, .unconfirmed, .failed, .connected])
    }

    @Test func liveInputInitIsASnapshotOfPendingServers() {
        var parser = ClaudeParser()
        let events = parser.parse(line: ConnectorSamples.claudeLiveInit)
        #expect(events.last == .connectors([Connector(name: "github", state: .unconfirmed, origin: .plugin)]))
    }

    @Test func codexAppsAndServersFromTheCapture() throws {
        let connectors = try ConnectorParser.codex(installed: ConnectorSamples.object(ConnectorSamples.codexInstalled),
                                                   servers: [ConnectorSamples.object(ConnectorSamples.codexServers)])
        let report = ConnectorReport(connectors: connectors)
        // codex_apps is how Codex reaches its apps, so the apps stand for it.
        #expect(!connectors.contains { $0.name == "codex_apps" })
        #expect(report.connected.map(\.name) == ["circleback", "GitHub", "Gmail", "Google Drive", "Linear", "link", "Search Service"])
        #expect(report.rows.map(\.state) == [.needsAuth, .unconfirmed])
        #expect(report.rows[0].connectors.map(\.name) == ["knowledge-bridge"])
        #expect(report.rows[1].connectors.map(\.name) == ["computer-use"])
        #expect(connectors.first { $0.name == "link" }?.detail == "MCP server · 4 tools listed")
        #expect(connectors.first { $0.name == "Gmail" }?.detail == "Codex app")
    }

    @Test func codexStatesFromRuntimeAndAppFlags() throws {
        let installed = ConnectorSamples.object(#"""
        {"apps":[{"id":"a1","runtimeName":"Off app","enabled":false,"callable":false},{"id":"a2","runtimeName":"No tools","enabled":true,"callable":false},{"id":"connector_x","runtimeName":null,"enabled":true,"callable":true}]}
        """#)
        let page1 = ConnectorSamples.object(#"""
        {"data":[{"name":"a","authStatus":"oAuth","runtimeStatus":"connected","tools":{}},{"name":"b","authStatus":"oAuth","runtimeStatus":"authenticationRequired","tools":{}}],"nextCursor":"2"}
        """#)
        let page2 = ConnectorSamples.object(#"""
        {"data":[{"name":"c","authStatus":"unsupported","runtimeStatus":"failed","tools":{}},{"name":"d","authStatus":"unsupported","runtimeStatus":"disabled","tools":{}},{"name":"e","authStatus":"unsupported","runtimeStatus":"starting","tools":{}},{"name":"f","authStatus":"unsupported","toolsError":"boom","tools":{}},{"name":"g","authStatus":"unsupported","pluginId":"p@1","tools":{"t":{}}}],"nextCursor":null}
        """#)
        let connectors = try ConnectorParser.codex(installed: installed, servers: [page1, page2])
        let states = Dictionary(connectors.map { ($0.name, $0.state) }, uniquingKeysWith: { a, _ in a })
        #expect(states == ["Off app": .off, "No tools": .unconfirmed, "connector_x": .connected,
                           "a": .connected, "b": .needsAuth, "c": .failed, "d": .off, "e": .unconfirmed, "f": .failed, "g": .connected])
        #expect(connectors.first { $0.name == "g" }?.origin == .plugin)
        #expect(throws: ConnectorFailure.self) { try ConnectorParser.codex(installed: [:], servers: []) }
    }

    @Test func emptyReportsAreNoneNotUnknown() {
        let report = ConnectorReport(connectors: [])
        #expect(report.connected.isEmpty && report.rows.isEmpty)
    }
}

@Suite struct ConnectorCardTests {
    let here = ConnectorScope(accountID: "claude-personal", command: "~/.local/bin/claude-personal", folder: "/bots/scout")
    let report = ConnectorReport(connectors: [Connector(name: "Gmail", state: .connected, origin: .claudeAI)], at: Date(timeIntervalSince1970: 0))

    @Test func onAHostASessionReportIsCurrentOnlyForItsSessionAndScope() {
        let session = SessionConnectorReport(scope: here, sessionID: "s1", report: report)
        #expect(ConnectorCard.make(kind: .claude, scope: here, host: "Hermes", sessionID: "s1", session: session, check: nil)
                == .session(report, current: true))
        #expect(ConnectorCard.make(kind: .claude, scope: here, host: "Hermes", sessionID: "s1", session: session, check: nil).title == "Connected at last report")
        // New Session: the same profile, folder and host keep it, as an earlier session's.
        let fresh = ConnectorCard.make(kind: .claude, scope: here, host: "Hermes", sessionID: nil, session: session, check: nil)
        #expect(fresh == .session(report, current: false))
        #expect(fresh.title == "Last session report")
        // Another profile, command, folder or host: nothing until its next turn reports.
        for other in [ConnectorScope(accountID: "claude-work", command: here.command, folder: here.folder),
                      ConnectorScope(accountID: here.accountID, command: "claude", folder: here.folder),
                      ConnectorScope(accountID: here.accountID, command: here.command, folder: "/elsewhere"),
                      ConnectorScope(accountID: here.accountID, command: here.command, folder: here.folder, hostID: UUID())] {
            #expect(ConnectorCard.make(kind: .claude, scope: other, host: "Hermes", sessionID: "s1", session: session, check: nil) == .notReported)
        }
        #expect(ConnectorCard.make(kind: .claude, scope: here, host: "Hermes", sessionID: nil, session: nil, check: nil).title == "Not reported yet")
    }

    @Test func profileChecksAndUnsupportedContextsSaySo() {
        let check = ConnectorCheck(report: report)
        // On this Mac a check is the profile's, never this session's, whatever session reported.
        let session = SessionConnectorReport(scope: here, sessionID: "s1", report: report)
        #expect(ConnectorCard.make(kind: .codex, scope: here, host: nil, sessionID: "s1", session: nil, check: check) == .profile(check))
        #expect(ConnectorCard.make(kind: .claude, scope: here, host: nil, sessionID: "s1", session: session, check: check) == .profile(check))
        #expect(ConnectorCard.make(kind: .claude, scope: here, host: nil, sessionID: "s1", session: session, check: nil) == .profile(nil))
        #expect(ConnectorCard.profile(nil).title == "Enabled for this profile")
        #expect(ConnectorCard.make(kind: .codex, scope: here, host: "Hermes", sessionID: nil, session: nil, check: check).title == "Not checked on Hermes")
        // Claude Code reports over SSH too.
        #expect(ConnectorCard.make(kind: .claude, scope: here, host: "Hermes", sessionID: "s1", session: session, check: nil) == .session(report, current: true))
        for kind in [AgentKind.antigravity, .muse, .pi] {
            #expect(ConnectorCard.make(kind: kind, scope: here, host: nil, sessionID: "s1", session: session, check: check) == .unavailable(kind))
        }
        #expect(ConnectorCard.unavailable(.antigravity).title == "Discovery unavailable for Antigravity")
    }

    @Test func aFailedCheckKeepsTheListAsStale() {
        let start = Date(timeIntervalSince1970: 1_000)
        let first = ConnectorCheck(triedAt: .distantPast).next(.success(report), at: start)
        #expect(first.report == report && !first.isStale)
        let failed = first.next(.failure(ConnectorFailure("Codex didn’t answer within 20 seconds.")), at: start.addingTimeInterval(120))
        #expect(failed.report == report)
        #expect(failed.isStale)
        #expect(failed.error == "Codex didn’t answer within 20 seconds.")
        let recovered = failed.next(.success(ConnectorReport(connectors: [], at: start.addingTimeInterval(200))), at: start.addingTimeInterval(200))
        #expect(!recovered.isStale && recovered.report?.connectors.isEmpty == true)
        // Never checked: a first failure has no list, only its error.
        let never = ConnectorCheck(triedAt: .distantPast).next(.failure(ConnectorFailure("x")), at: start)
        #expect(never.report == nil && never.error == "x")
    }

    @Test func checksAreOnDemandAndBounded() {
        let at = Date(timeIntervalSince1970: 10_000)
        let check = ConnectorCheck(report: ConnectorReport(connectors: [], at: at), triedAt: at)
        #expect(!check.isDue(at: at.addingTimeInterval(59 * 60)))
        #expect(check.isDue(at: at.addingTimeInterval(61 * 60)))
        #expect(!check.canRetry(at: at.addingTimeInterval(30)))
        #expect(check.canRetry(at: at.addingTimeInterval(61)))
        // A failed first check is tried again on showing, but not more than once a minute.
        let failed = ConnectorCheck(error: "x", triedAt: at)
        #expect(!failed.isDue(at: at.addingTimeInterval(30)))
        #expect(failed.isDue(at: at.addingTimeInterval(61)))
    }
}

@Suite struct ConnectorEvidenceTests {
    let a = ConnectorScope(accountID: "codex-personal", command: "codex-personal", folder: "/bots/a")
    let b = ConnectorScope(accountID: "codex-personal", command: "codex-personal", folder: "/bots/b")
    let start = Date(timeIntervalSince1970: 50_000)

    private func report(_ names: String..., at date: Date) -> ConnectorReport {
        ConnectorReport(connectors: names.map { Connector(name: $0, state: .connected, origin: .codexApp) }, at: date)
    }

    private func card(_ evidence: ConnectorEvidence<String>, _ scope: ConnectorScope) -> ConnectorCard {
        ConnectorCard.make(kind: .codex, scope: scope, host: nil, sessionID: nil, session: nil, check: evidence.checks[scope])
    }

    @Test func aLateCheckOfTheLastContextNeverShowsInTheNext() {
        var evidence = ConnectorEvidence<String>()
        do { let started = evidence.begin(a, now: start); #expect(started) }
        // The inspector moves to B, whose check starts and ends first.
        do { let started = evidence.begin(b, now: start); #expect(started) }
        evidence.finish(b, .success(report("Linear", at: start)), at: start.addingTimeInterval(1))
        // A's answer arrives late: it is A's, and B's card doesn't change.
        evidence.finish(a, .success(report("Gmail", at: start)), at: start.addingTimeInterval(5))
        #expect(card(evidence, b) == .profile(evidence.checks[b]))
        #expect(evidence.checks[b]?.report?.connected.map(\.name) == ["Linear"])
        #expect(evidence.checks[a]?.report?.connected.map(\.name) == ["Gmail"])
        #expect(evidence.checking.isEmpty)
    }

    @Test func oneCheckAtATimeAndAFailureKeepsTheListStale() {
        var evidence = ConnectorEvidence<String>()
        do { let started = evidence.begin(a, now: start); #expect(started) }
        do { let started = evidence.begin(a, force: true, now: start); #expect(!started) }
        evidence.finish(a, .success(report("Gmail", at: start)), at: start)
        // Shown again within the hour: nothing to do; Refresh within a minute: not yet.
        do { let started = evidence.begin(a, now: start.addingTimeInterval(600)); #expect(!started) }
        do { let started = evidence.begin(a, force: true, now: start.addingTimeInterval(30)); #expect(!started) }
        do { let started = evidence.begin(a, force: true, now: start.addingTimeInterval(90)); #expect(started) }
        evidence.finish(a, .failure(ConnectorFailure("Codex didn’t answer within 20 seconds.")), at: start.addingTimeInterval(110))
        let check = evidence.checks[a]
        #expect(check?.isStale == true)
        #expect(check?.report?.connected.map(\.name) == ["Gmail"])
        #expect(check?.report?.at == start)
    }

    @Test func sessionReportsBelongToTheirConversationAndScope() {
        var evidence = ConnectorEvidence<String>()
        let claude = ConnectorScope(accountID: "claude-work", command: "claude-work", folder: "~/apps/x", hostID: UUID())
        evidence.record([Connector(name: "Gmail", state: .connected, origin: .claudeAI)], scope: claude, sessionID: "s1", for: "task")
        let make = { (scope: ConnectorScope, session: String?) in
            ConnectorCard.make(kind: .claude, scope: scope, host: "Hermes", sessionID: session, session: evidence.sessions["task"], check: nil)
        }
        #expect(make(claude, "s1").title == "Connected at last report")
        #expect(make(claude, nil).title == "Last session report")
        var moved = claude
        moved.hostID = UUID()
        #expect(make(moved, "s1") == .notReported)
        #expect(evidence.sessions["home"] == nil)
    }
}

/// `ConnectorClient` against a stand-in `app-server` that logs what it was asked.
@Suite struct ConnectorClientTests {
    private func withServer(_ answers: String, _ body: (_ command: String, _ folder: URL, _ log: URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-connectors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("methods.log")
        let script = directory.appendingPathComponent("server.py")
        try #"""
        import json, sys
        answers = json.loads(sys.argv[1])
        log = open(sys.argv[2], "a")
        log.write("args " + " ".join(sys.argv[3:]) + "\n"); log.flush()
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            log.write(method + " " + json.dumps(request.get("params", {}), sort_keys=True) + "\n"); log.flush()
            if "id" not in request: continue
            key = method + ("#" + request["params"]["cursor"] if request.get("params", {}).get("cursor") else "")
            answer = answers.get(key, {"error": {"code": -32601, "message": "unknown method"}})
            if answer == "hang": continue
            print(json.dumps({"method": "remoteControl/status/changed", "params": {}}))
            print(json.dumps(dict(answer, id=request["id"], jsonrpc="2.0")), flush=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let answersFile = directory.appendingPathComponent("answers.json")
        try answers.write(to: answersFile, atomically: true, encoding: .utf8)
        let command = "/usr/bin/python3 -I \(script.path) \"$(cat \(answersFile.path))\" \(log.path)"
        try await body(command, directory, log)
    }

    private func methods(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init)
    }

    @Test func readsEveryPageAndTheRefreshedAppsOnly() async throws {
        try await withServer(#"""
        {"initialize": {"result": {}},
         "mcpServerStatus/list": {"result": {"data": [{"name": "a", "authStatus": "oAuth", "tools": {"t": {}}}], "nextCursor": "p2"}},
         "mcpServerStatus/list#p2": {"result": {"data": [{"name": "b", "authStatus": "notLoggedIn", "tools": {}}], "nextCursor": null}},
         "app/installed": {"result": {"apps": [{"id": "x", "runtimeName": "Gmail", "enabled": true, "callable": true}]}}}
        """#) { command, folder, log in
            let report = try await ConnectorClient.codex(command: command, folder: folder.path, timeout: 10)
            #expect(report.connected.map(\.name) == ["a", "Gmail"])
            #expect(report.rows.map(\.state) == [.needsAuth])
            // Read-only: no thread, turn or tool call; each page asked for in turn; run as app-server.
            let asked = methods(log)
            #expect(asked.first == "args app-server")
            #expect(asked.dropFirst().map { String($0.split(separator: " ")[0]) }
                    == ["initialize", "initialized", "mcpServerStatus/list", "mcpServerStatus/list", "app/installed"])
            #expect(asked[4].contains(#""cursor": "p2""#))
            #expect(asked[5].contains(#""forceRefresh": true"#))
        }
    }

    @Test func anOlderCodexSaysItCantListRatherThanNone() async throws {
        try await withServer(#"{"initialize": {"result": {}}}"#) { command, folder, _ in
            await #expect(throws: ConnectorFailure.unsupported) {
                _ = try await ConnectorClient.codex(command: command, folder: folder.path, timeout: 10)
            }
        }
    }

    @Test func rawErrorsNeverReachTheCard() async throws {
        try await withServer(#"""
        {"initialize": {"result": {}}, "mcpServerStatus/list": {"error": {"code": -32000, "message": "token sk-private at https://private.example"}}}
        """#) { command, folder, _ in
            do {
                _ = try await ConnectorClient.codex(command: command, folder: folder.path, timeout: 10)
                Issue.record("Expected a failure")
            } catch let failure as ConnectorFailure {
                #expect(!failure.message.contains("private"))
            }
        }
    }

    @Test func aHostThatNeverAnswersTimesOut() async throws {
        try await withServer(#"{"initialize": {"result": {}}, "mcpServerStatus/list": "hang"}"#) { command, folder, _ in
            let started = Date()
            await #expect(throws: ConnectorFailure("Codex didn’t answer within 2 seconds.")) {
                _ = try await ConnectorClient.codex(command: command, folder: folder.path, timeout: 2)
            }
            #expect(Date().timeIntervalSince(started) < 8)
        }
    }

    @Test func claudeIsAskedForItsListOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-connectors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("list.txt")
        try ConnectorSamples.claudeList.write(to: output, atomically: true, encoding: .utf8)
        let log = directory.appendingPathComponent("args.log")
        let command = "sh -c 'pwd > \(log.path); echo \"$@\" >> \(log.path); cat \(output.path)' claude"
        let report = try await ConnectorClient.check(.claude, command: command, folder: directory.path, timeout: 10)
        #expect(report.connected.count == 5)
        let asked = try String(contentsOf: log, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        #expect(asked.last == "mcp list")
        #expect(asked.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == directory.resolvingSymlinksInPath().path)

        await #expect(throws: ConnectorFailure.self) {
            _ = try await ConnectorClient.check(.antigravity, command: "agy", folder: directory.path)
        }
    }

    @Test func aMissingFolderIsntChecked() async {
        await #expect(throws: ConnectorFailure.self) {
            _ = try await ConnectorClient.codex(command: "/bin/false", folder: "/nonexistent-\(UUID().uuidString)", timeout: 2)
        }
    }
}
