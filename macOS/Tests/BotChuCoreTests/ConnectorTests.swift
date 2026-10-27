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
        #expect(local.map(\.state) == [.failed, .failed, .pending])
        // The names as configured stay beside the shown ones, for the CLI's own management.
        #expect(connectors.first { $0.name == "Slack" }?.id == "claude.ai Slack")
        #expect(connectors.first { $0.name == "github" }?.id == "plugin:github:github")
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
        #expect(events.last == .connectors([Connector(name: "github", state: .unconfirmed, origin: .plugin, id: "plugin:github:github")]))
    }

    @Test func codexAppsAndServersFromTheCapture() throws {
        let connectors = try ConnectorParser.codex(installed: ConnectorSamples.object(ConnectorSamples.codexInstalled),
                                                   servers: [ConnectorSamples.object(ConnectorSamples.codexServers)])
        let report = ConnectorReport(connectors: connectors)
        // codex_apps is how Codex reaches its apps, so the apps stand for it.
        #expect(!connectors.contains { $0.name == "codex_apps" })
        #expect(report.connected.map(\.name) == ["circleback", "GitHub", "Gmail", "Google Drive", "Linear", "link", "Search Service"])
        // Computer Use lists no tools outside a thread: configured, neither working nor broken.
        #expect(report.rows.map(\.state) == [.needsAuth, .configured])
        #expect(report.rows[0].connectors.map(\.name) == ["knowledge-bridge"])
        #expect(report.rows[1].connectors.map(\.name) == ["Computer Use"])
        #expect(report.rows[1].connectors.map(\.id) == ["computer-use"])
        #expect(connectors.first { $0.name == "Gmail" }?.id == "connector_0002")
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
        {"data":[{"name":"c","authStatus":"unsupported","runtimeStatus":"failed","tools":{}},{"name":"d","authStatus":"unsupported","runtimeStatus":"disabled","tools":{}},{"name":"e","authStatus":"unsupported","runtimeStatus":"starting","tools":{}},{"name":"f","authStatus":"unsupported","toolsError":"boom","tools":{}},{"name":"g","authStatus":"unsupported","pluginId":"p@1","tools":{"t":{}}},{"name":"h","authStatus":"unsupported","tools":{}}],"nextCursor":null}
        """#)
        let connectors = try ConnectorParser.codex(installed: installed, servers: [page1, page2])
        let states = Dictionary(connectors.map { ($0.name, $0.state) }, uniquingKeysWith: { a, _ in a })
        #expect(states == ["Off app": .off, "No tools": .unconfirmed, "connector_x": .connected,
                           "a": .connected, "b": .needsAuth, "c": .failed, "d": .off, "e": .unconfirmed, "f": .failed, "g": .connected,
                           "h": .configured])
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
        #expect(first.report == report && !first.isStale(at: start))
        let failed = first.next(.failure(ConnectorFailure("Codex didn’t answer within 20 seconds.")), at: start.addingTimeInterval(120))
        #expect(failed.report == report)
        #expect(failed.isStale(at: start.addingTimeInterval(120)))
        #expect(failed.error == "Codex didn’t answer within 20 seconds.")
        let recovered = failed.next(.success(ConnectorReport(connectors: [], at: start.addingTimeInterval(200))), at: start.addingTimeInterval(200))
        #expect(!recovered.isStale(at: start.addingTimeInterval(200)) && recovered.report?.connectors.isEmpty == true)
        // Age alone makes a list stale once it is due again.
        #expect(recovered.isStale(at: start.addingTimeInterval(200 + ConnectorCheck.freshFor)))
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
        ConnectorCard.make(kind: .codex, scope: scope, host: nil, sessionID: nil, session: nil, check: evidence.check(for: scope))
    }

    @Test func aLateCheckOfTheLastContextNeverShowsInTheNext() throws {
        var evidence = ConnectorEvidence<String>()
        let first = try required(&evidence, a, now: start)
        // The inspector moves to B, whose check starts and ends first.
        let second = try required(&evidence, b, now: start)
        evidence.finish(b, token: second, .success(report("Linear", at: start)), at: start.addingTimeInterval(1))
        // A's answer arrives late: it is A's, and B's card doesn't change.
        evidence.finish(a, token: first, .success(report("Gmail", at: start)), at: start.addingTimeInterval(5))
        #expect(card(evidence, b) == .profile(evidence.check(for: b)))
        #expect(evidence.check(for: b)?.report?.connected.map(\.name) == ["Linear"])
        #expect(evidence.check(for: a)?.report?.connected.map(\.name) == ["Gmail"])
        #expect(evidence.checking.isEmpty)
    }

    @Test func oneCheckAtATimeAndAFailureKeepsTheListStale() throws {
        var evidence = ConnectorEvidence<String>()
        let token = try required(&evidence, a, now: start)
        // Refresh while it runs coalesces into it: nothing new starts.
        #expect(begun(&evidence, a, force: true, now: start) == nil)
        #expect(evidence.isChecking(a))
        evidence.finish(a, token: token, .success(report("Gmail", at: start)), at: start)
        // Shown again within the hour (A, B, then A again): nothing to do; Refresh within a minute: not yet.
        #expect(begun(&evidence, a, now: start.addingTimeInterval(600)) == nil)
        #expect(begun(&evidence, a, force: true, now: start.addingTimeInterval(30)) == nil)
        let retry = try required(&evidence, a, force: true, now: start.addingTimeInterval(90))
        evidence.finish(a, token: retry, .failure(ConnectorFailure("Codex didn’t answer within 20 seconds.")), at: start.addingTimeInterval(110))
        let check = evidence.check(for: a)
        #expect(check?.isStale(at: start.addingTimeInterval(110)) == true)
        #expect(check?.report?.connected.map(\.name) == ["Gmail"])
        #expect(check?.report?.at == start)
    }

    @Test func managementInvalidatesTheProfileInEveryFolderOnThisMacOnly() throws {
        let other = ConnectorScope(accountID: "codex-work", command: "codex-work", folder: "/bots/a")
        let newCommand = ConnectorScope(accountID: a.accountID, command: "codex-personal --profile x", folder: a.folder)
        var evidence = ConnectorEvidence<String>()
        for scope in [a, b, other, newCommand] {
            let token = try required(&evidence, scope, now: start)
            evidence.finish(scope, token: token, .success(report("Gmail", at: start)), at: start)
        }
        // B's check is under way when the owner opens the provider's settings from A.
        let late = try required(&evidence, b, force: true, now: start.addingTimeInterval(120))
        evidence.invalidate(profileOf: a)
        let soon = start.addingTimeInterval(130)
        // A and B keep their lists, shown as stale, and are due at once, whatever Refresh's limit.
        for scope in [a, b] {
            let check = try #require(evidence.check(for: scope))
            #expect(check.invalidated && check.isStale(at: soon) && check.isDue(at: soon) && check.canRetry(at: soon))
            #expect(check.report?.connected.map(\.name) == ["Gmail"])
        }
        // Another profile, or the same one with another command, is a profile of its own.
        #expect(evidence.check(for: other)?.invalidated == false)
        #expect(evidence.check(for: newCommand)?.invalidated == false)
        // B's check still runs: asking for B now starts none beside it, but queues one after it, once.
        #expect(evidence.isChecking(b))
        #expect(begun(&evidence, b, now: soon) == nil)
        #expect(begun(&evidence, b, force: true, now: soon) == nil)
        #expect(evidence.queued == [b.key])
        // B's late answer, from before the change, doesn't make it current again; the queued check follows.
        #expect(finished(&evidence, b, token: late, .success(report("Old", at: soon)), at: soon) == .init(recorded: false, again: true))
        #expect(evidence.check(for: b)?.invalidated == true)
        #expect(evidence.check(for: b)?.report?.connected.map(\.name) == ["Gmail"])
        #expect(evidence.checking.isEmpty && evidence.overtaken.isEmpty && evidence.queued.isEmpty)
        // The check after it does.
        let fresh = try required(&evidence, b, force: true, now: soon)
        #expect(finished(&evidence, b, token: fresh, .success(report("Slack", at: soon)), at: soon) == .init(recorded: true, again: false))
        #expect(evidence.check(for: b)?.invalidated == false)
        #expect(evidence.check(for: b)?.report?.connected.map(\.name) == ["Slack"])
    }

    @Test func aRemovedProfileOrChangedCommandForgetsItsChecks() throws {
        var evidence = ConnectorEvidence<String>()
        let done = try required(&evidence, a, now: start)
        evidence.finish(a, token: done, .success(report("Gmail", at: start)), at: start)
        let running = try required(&evidence, b, now: start)
        // Managed while it runs, and asked for again: a check is queued after it.
        evidence.invalidate(profileOf: b)
        #expect(begun(&evidence, b, now: start) == nil)
        #expect(evidence.queued == [b.key])
        evidence.retain(profiles: [ConnectorScope.profile(accountID: a.accountID, command: "codex-personal --profile x")])
        // The old command's check is forgotten, and nothing is queued for it; its run still counts as running.
        #expect(evidence.checks.isEmpty && evidence.queued.isEmpty)
        #expect(evidence.isChecking(b) && evidence.overtaken == [b.key])
        // The check that ran for the old command ends: it changes nothing, and nothing follows it.
        #expect(finished(&evidence, b, token: running, .success(report("Gmail", at: start)), at: start) == .init(recorded: false, again: false))
        #expect(evidence.check(for: b) == nil && evidence.checking.isEmpty)
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
        // Providers finds it by its exact scope, never another host's or folder's.
        #expect(evidence.session(in: claude)?.sessionID == "s1")
        #expect(evidence.session(in: moved) == nil)
        var elsewhere = claude
        elsewhere.folder = "~/apps/y"
        #expect(evidence.session(in: elsewhere) == nil)
    }
}

@Suite struct ConnectorCacheTests {
    let start = Date(timeIntervalSince1970: 80_000)

    @Test func savedChecksComeBackByScopeWithoutCommandsOrPaths() throws {
        let scope = ConnectorScope(accountID: "claude-personal", command: "~/.local/bin/claude-personal --secret-flag", folder: "/Users/me/private-folder")
        let report = try ConnectorReport(connectors: ConnectorParser.claudeList(ConnectorSamples.claudeList), at: start)
        var evidence = ConnectorEvidence<String>()
        let token = try required(&evidence, scope, now: start)
        evidence.finish(scope, token: token, .success(report), at: start)
        // A host's session report is the conversation's, never saved.
        evidence.record(report.connectors, scope: ConnectorScope(accountID: "claude-work", command: "c", folder: "/x", hostID: UUID()),
                        sessionID: "s", for: "task")
        let data = try #require(ConnectorCacheFile.encode(evidence.checks, now: start))
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["claude-personal", "secret-flag", "private-folder", "/Users/me", "example", "HTTP", "req_"] {
            #expect(!text.contains(secret), "connectors.json holds \(secret)")
        }
        // Relaunched: the same scope shows the same list at once, with the raw names kept for management.
        var restored = ConnectorEvidence<String>(checks: ConnectorCacheFile.decode(data))
        let check = try #require(restored.check(for: scope))
        #expect(check.report == report)
        #expect(check.report?.connectors.first { $0.name == "Slack" }?.id == "claude.ai Slack")
        #expect(begun(&restored, scope, now: start.addingTimeInterval(600)) == nil)
        // Never for another folder, profile, command or host.
        for other in [ConnectorScope(accountID: scope.accountID, command: scope.command, folder: "/Users/me/other"),
                      ConnectorScope(accountID: "claude-work", command: scope.command, folder: scope.folder),
                      ConnectorScope(accountID: scope.accountID, command: "claude", folder: scope.folder),
                      ConnectorScope(accountID: scope.accountID, command: scope.command, folder: scope.folder, hostID: UUID())] {
            #expect(restored.check(for: other) == nil)
        }
    }

    @Test func aDamagedOrOldCacheStartsEmpty() throws {
        #expect(ConnectorCacheFile.decode(Data("{not json".utf8)).isEmpty)
        #expect(ConnectorCacheFile.decode(Data()).isEmpty)
        #expect(ConnectorCacheFile.decode(Data(#"[{"key":{"scope":"x"}}]"#.utf8)).isEmpty)
        let scope = ConnectorScope(accountID: "codex-dev", command: "codex-dev", folder: "/bots/a")
        let checks = [scope.key: ConnectorCheck(report: ConnectorReport(connectors: [], at: start), triedAt: start)]
        let week = try #require(ConnectorCacheFile.encode(checks, now: start.addingTimeInterval(ConnectorCheck.keptFor + 1)))
        #expect(ConnectorCacheFile.decode(week).isEmpty)
        // An invalidated list stays invalidated across a relaunch.
        var invalidated = checks
        invalidated[scope.key]?.invalidated = true
        let saved = try #require(ConnectorCacheFile.encode(invalidated, now: start))
        #expect(ConnectorCacheFile.decode(saved)[scope.key]?.invalidated == true)
    }
}

@Suite struct ConnectorCategoryTests {
    @Test func theProvidersOwnEntriesAreSystemAndUnknownServicesStay() throws {
        let connectors = try ConnectorParser.codex(installed: ConnectorSamples.object(ConnectorSamples.codexInstalledSystem),
                                                   servers: [ConnectorSamples.object(ConnectorSamples.codexServersSystem)])
        let report = ConnectorReport(connectors: connectors)
        #expect(report.listed(.system).map(\.name) == ["Codex Document Control", "Hotline", "link", "node_repl", "Pets", "Search Service", "cua_repl"])
        #expect(report.listed(.tool).map(\.name) == ["Computer Use"])
        #expect(report.listed(.tool).first?.state == .configured)
        // Services, the owner's MCP servers and a newly bundled app all stay in view.
        #expect(report.listed(.connection).map(\.name) == ["knowledge-bridge", "Circleback", "circleback", "Gmail", "Sites"])
    }

    @Test func namesAreMatchedExactlyAfterNormalizing() {
        func category(_ name: String, _ origin: Connector.Origin, id: String? = nil) -> Connector.Category {
            Connector(name: name, state: .connected, origin: origin, id: id).category
        }
        #expect(category("node-repl", .mcpServer) == .system)
        #expect(category("Node REPL", .plugin) == .system)
        #expect(category("computer_use", .mcpServer) == .tool)
        #expect(category("Computer Use", .claudeAI) == .tool)
        // Close isn't the same: these are the owner's.
        #expect(category("linkedin", .mcpServer) == .connection)
        #expect(category("pets-store", .mcpServer) == .connection)
        #expect(category("Link", .claudeAI) == .connection)
        #expect(category("Pets", .codexApp, id: "asdk_app_1") == .connection)
        #expect(category("Pets", .codexApp, id: "connector_openai_chatgpt_pets") == .system)
        // Codex's computer-use runtime and its apps' bridge, by their exact names; Computer Use stays a tool.
        #expect(category("cua_repl", .mcpServer) == .system)
        #expect(category("codex_app", .mcpServer) == .system)
        #expect(category("codex_apps", .mcpServer) == .system)
        #expect(category("cua", .mcpServer) == .connection)
        #expect(category("cua_repl_tools", .mcpServer) == .connection)
        #expect(category("codex_app_store", .mcpServer) == .connection)
    }

    @Test func listsPutWhatNeedsTheOwnerFirst() {
        let report = ConnectorReport(connectors: [
            Connector(name: "Zeta", state: .connected, origin: .claudeAI), Connector(name: "Alpha", state: .off, origin: .claudeAI),
            Connector(name: "Mid", state: .failed, origin: .claudeAI), Connector(name: "Beta", state: .needsAuth, origin: .claudeAI),
            Connector(name: "Gamma", state: .connected, origin: .claudeAI), Connector(name: "Local", state: .pending, origin: .mcpServer),
        ])
        #expect(report.listed(.connection).map(\.name) == ["Beta", "Mid", "Local", "Gamma", "Zeta", "Alpha"])
    }
}

@Suite struct ConnectorActionTests {
    private func action(_ state: Connector.State, _ origin: Connector.Origin, kind: AgentKind = .claude, local: Bool = true,
                        id: String = "x") -> ConnectorAction? {
        ConnectorAction.make(for: Connector(name: "X", state: state, origin: origin, id: id), kind: kind, local: local)
    }

    @Test func eachStateGetsWhatItsProviderSupports() {
        // Sign-in needed: the CLI's own login for a server or a claude.ai connector; ChatGPT for a Codex app.
        #expect(action(.needsAuth, .claudeAI) == .signIn)
        #expect(action(.needsAuth, .mcpServer, kind: .codex) == .signIn)
        #expect(action(.needsAuth, .codexApp, kind: .codex) == .settings(.chatGPT))
        // Failed: check again; pending approval: the CLI, where /mcp approves it.
        #expect(action(.failed, .mcpServer) == .retry)
        #expect(action(.pending, .mcpServer) == .terminal)
        // Off: where it was turned off.
        #expect(action(.off, .claudeAI) == .settings(.claudeAI))
        #expect(action(.off, .codexApp, kind: .codex) == .settings(.chatGPT))
        #expect(action(.off, .mcpServer) == .terminal)
        // An app enabled without a callable tool isn't assumed to need a sign-in.
        #expect(action(.unconfirmed, .codexApp, kind: .codex) == .settings(.chatGPT))
        #expect(action(.unconfirmed, .mcpServer) == nil)
        // Working, or configured with nothing reported: nothing to do.
        #expect(action(.connected, .claudeAI) == nil)
        #expect(action(.configured, .mcpServer) == nil)
        // No discovery, no actions.
        #expect(action(.needsAuth, .mcpServer, kind: .pi) == nil)
    }

    @Test func aHostsCLIIsNeverRunFromHere() {
        #expect(action(.needsAuth, .claudeAI, local: false) == .settings(.claudeAI))
        #expect(action(.needsAuth, .mcpServer, local: false) == nil)
        #expect(action(.failed, .mcpServer, local: false) == nil)
        #expect(action(.pending, .mcpServer, local: false) == nil)
        #expect(action(.off, .claudeAI, local: false) == .settings(.claudeAI))
    }

    @Test func anIdentifierThatCantBePassedSafelyGetsNoCLIAction() {
        #expect(action(.needsAuth, .mcpServer, id: "bad\nname") == nil)
        #expect(action(.needsAuth, .claudeAI, id: "bad\u{1B}[0m") == .settings(.claudeAI))
        #expect(action(.pending, .mcpServer, id: "") == nil)
    }

    @Test func settingsNeverClaimTheProfilesAccount() {
        #expect(ConnectorSettings.claudeAI.url.absoluteString == "https://claude.ai/customize/connectors")
        #expect(ConnectorSettings.chatGPT.url.absoluteString == "https://chatgpt.com/#settings/Connectors")
        for settings in [ConnectorSettings.claudeAI, .chatGPT] {
            #expect(settings.title.hasPrefix("Manage") || settings.title.hasPrefix("Open"))
            #expect(!settings.title.localizedCaseInsensitiveContains("sign"))
        }
        #expect(ConnectorSettings(.claude) == .claudeAI && ConnectorSettings(.codex) == .chatGPT && ConnectorSettings(.muse) == nil)
    }
}

@Suite struct ConnectorHandoffTests {
    @Test func theLoginRunsAsTheProfileInItsFolderWithEachArgumentQuoted() throws {
        let slack = Connector(name: "Slack", state: .needsAuth, origin: .claudeAI, id: "claude.ai Slack")
        let arguments = try #require(ConnectorHandoff.arguments(for: .signIn, connector: slack))
        let script = try #require(ConnectorHandoff.script(command: "~/.local/bin/claude-personal", folder: "/Users/me/Bot's $HOME `x`",
                                                          arguments: arguments))
        let lines = script.split(separator: "\n").map(String.init)
        #expect(lines == [
            "#!/bin/zsh -l",
            #"rm -f -- "$0""#,
            #"cd -- '/Users/me/Bot'\''s $HOME `x`' || exit 1"#,
            "~/.local/bin/claude-personal 'mcp' 'login' 'claude.ai Slack'",
        ])
        #expect(ConnectorHandoff.arguments(for: .terminal, connector: nil) == [])
        #expect(ConnectorHandoff.arguments(for: .retry, connector: slack) == nil)
    }

    @Test func theScriptRunsWhatItSaysInAShell() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-handoff-\(UUID().uuidString) it's")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = "/usr/bin/printf '%s|' \"$PWD\""
        let script = try #require(ConnectorHandoff.script(command: command, folder: directory.path, arguments: ["mcp", "login", "a'b; touch pwned $(id)"]))
        let file = directory.appendingPathComponent("run.command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", file.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed.hasSuffix("|mcp|login|a'b; touch pwned $(id)|"))
        #expect(URL(fileURLWithPath: String(printed.split(separator: "|")[0])).resolvingSymlinksInPath() == directory.resolvingSymlinksInPath())
        // The script removed itself, and nothing in it ran as a command of its own.
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("pwned").path))
    }

    @Test func unsafeValuesMakeNoScript() {
        #expect(ConnectorHandoff.script(command: "claude\nrm -rf ~", folder: "/tmp") == nil)
        #expect(ConnectorHandoff.script(command: "claude", folder: "/tmp\n") == nil)
        #expect(ConnectorHandoff.script(command: "claude", folder: "/tmp", arguments: ["mcp", "login", "a\rb"]) == nil)
        #expect(ConnectorHandoff.script(command: "  ", folder: "/tmp") == nil)
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

/// `begin` and `finish` for expectations, which can't call mutating methods.
private func begun<T>(_ evidence: inout ConnectorEvidence<T>, _ scope: ConnectorScope, force: Bool = false, now: Date) -> Int? {
    evidence.begin(scope, force: force, now: now)
}

private func required<T>(_ evidence: inout ConnectorEvidence<T>, _ scope: ConnectorScope, force: Bool = false, now: Date) throws -> Int {
    let token = evidence.begin(scope, force: force, now: now)
    return try #require(token)
}

private func finished<T>(_ evidence: inout ConnectorEvidence<T>, _ scope: ConnectorScope, token: Int,
                         _ result: Result<ConnectorReport, ConnectorFailure>, at date: Date) -> ConnectorEvidence<T>.Finish {
    evidence.finish(scope, token: token, result, at: date)
}
