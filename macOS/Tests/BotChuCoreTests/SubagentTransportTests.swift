import Foundation
import Testing
@testable import BotChuCore

@Suite struct SubagentTransportTests {
    @Test func localMailboxOnlyAcknowledgesAfterRecordingAndPreservesResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-ipc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SubagentTransport(namespace: UUID(), invocationID: UUID(), localRoot: root)
        let endpoint = try await transport.prepare(script: "#!/bin/sh\nprintf ready", roster: Data("[]".utf8))
        let directory = URL(fileURLWithPath: endpoint.ipcDirectory)
        // A local turn runs the app's helper, installed once beside the mailboxes, not copies of its own.
        #expect(endpoint.binDirectory == SubagentIPC(root: root).binDirectory.path)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("bin").path))
        #expect(SubagentIPC().binDirectory == SubagentIPC.defaultBinDirectory)
        let id = UUID(), request = Data("{\"brief\":\"quoted ' and λ\"}".utf8)
        let filename = id.uuidString.lowercased() + ".json"
        try request.write(to: directory.appendingPathComponent("requests/" + filename), options: .atomic)
        try request.write(to: directory.appendingPathComponent("requests/.partial.json"))
        let before = try await transport.poll()
        #expect(before.count == 1)
        #expect(before.first?.data == request)
        #expect(try await transport.poll() == before)
        try await transport.acknowledge(filename: filename)
        #expect(try await transport.poll().isEmpty)
        try await transport.acknowledge(filename: filename)
        let result = Data("{\"handoffOutput\":\"done\"}".utf8)
        try await transport.writeResult(id: id, data: result)
        try await transport.writeStatus(id: id, data: Data("{\"phase\":\"completed\"}".utf8))
        try await transport.close()
        #expect(try Data(contentsOf: directory.appendingPathComponent("results/\(id.uuidString.lowercased()).result.json")) == result)
        let heartbeat = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("heartbeat.json"))) as? [String: Any])
        #expect(heartbeat["closed"] as? Bool == true)
        #expect(heartbeat["updatedAt"] as? String == "1970-01-01T00:00:00Z")
    }

    @Test func rejectsLargeRequestsSymlinksAndPathTraversalWithoutReadingThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-ipc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SubagentTransport(namespace: UUID(), invocationID: UUID(), localRoot: root)
        let endpoint = try await transport.prepare(script: "#!/bin/sh\n", roster: Data("[]".utf8))
        let directory = URL(fileURLWithPath: endpoint.ipcDirectory)
        let privateFile = root.appendingPathComponent("private.txt")
        try Data("must not read".utf8).write(to: privateFile)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("requests/link.json"), withDestinationURL: privateFile)
        try Data(repeating: 120, count: SubagentTransport.maximumRequestBytes + 1).write(to: directory.appendingPathComponent("requests/large.json"))
        let entries = try await transport.poll()
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.problem != nil && $0.data.isEmpty })
        await #expect(throws: SubagentTransport.Failure.self) { try await transport.acknowledge(filename: "../private.json") }
        #expect(try String(contentsOf: privateFile, encoding: .utf8) == "must not read")
    }

    @Test func hostMailboxSupportsLargeHandoffsAndIndependentInvocationNamespaces() async throws {
        let namespace = UUID(), id = UUID(), otherID = UUID()
        let machine = FakeSSH.machine
        let transport = SubagentTransport(machine: machine, namespace: namespace, invocationID: id)
        let other = SubagentTransport(machine: machine, namespace: namespace, invocationID: otherID)
        let endpoint = try await transport.prepare(script: "#!/bin/sh\nprintf remote-ready", roster: Data("[]".utf8))
        let second = try await other.prepare(script: "#!/bin/sh\n", roster: Data("[]".utf8))
        #expect(endpoint.ipcDirectory.hasPrefix("/"))
        #expect(endpoint.ipcDirectory != second.ipcDirectory)
        let folder = URL(fileURLWithPath: endpoint.ipcDirectory).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = URL(fileURLWithPath: endpoint.ipcDirectory)
        let requestID = UUID(), filename = UUID().uuidString.lowercased() + ".json"
        let request = Data("{\"brief\":\"two ' quotes\"}".utf8)
        try request.write(to: directory.appendingPathComponent("requests/" + filename), options: .atomic)
        #expect(try await transport.poll().first?.data == request)
        #expect(try await other.poll().isEmpty)
        try await transport.acknowledge(filename: filename)
        #expect(try await transport.poll().isEmpty)
        // Stdin transfer avoids the shell/exec argument-size ceiling for long handoff reports.
        let large = Data(repeating: 97, count: 400_000)
        try await transport.writeResult(id: requestID, data: large)
        #expect(try Data(contentsOf: directory.appendingPathComponent("results/\(requestID.uuidString.lowercased()).result.json")) == large)
        try await transport.heartbeat()
        try await transport.close()
    }

    @Test func transportCommandsTimeoutAndCancelPromptly() async throws {
        let started = Date()
        let timedOut = await TransportCommand().execute(executable: "/bin/sleep", arguments: ["30"], timeout: 0.15)
        #expect(timedOut.status != 0)
        #expect(Date().timeIntervalSince(started) < 3)
        let command = TransportCommand()
        let task = Task {
            await withTaskCancellationHandler {
                await command.execute(executable: "/bin/sleep", arguments: ["30"], timeout: 30)
            } onCancel: { command.cancel() }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value
        #expect(result.status != 0)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func invocationExportsOnlyDelegationContextAndFindsHelperAfterLogin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SubagentTransport(namespace: UUID(), invocationID: UUID(), localRoot: root)
        let endpoint = try await transport.prepare(script: "", roster: Data("[]".utf8))
        let helper = URL(fileURLWithPath: endpoint.binDirectory).appendingPathComponent("botchu-subagent")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s' \"$BOTCHU_INVOCATION_ID|$BOTCHU_IPC_DIR\"".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let context = "literal ' \" $HOME $(printf injected)"
        let env = ["BOTCHU_INVOCATION_ID": context, "BOTCHU_IPC_DIR": endpoint.ipcDirectory,
                   "BOTCHU_BIN_DIR": endpoint.binDirectory, "OPENROUTER_API_KEY": "not-for-the-host", "BOTCHU_SECRET": "also-private"]
        let prefix = AgentRun.delegationShellPrefix(env)
        #expect(!prefix.contains("not-for-the-host"))
        #expect(!prefix.contains("also-private"))
        #expect(!prefix.contains("OPENROUTER_API_KEY"))
        for machine in [Machine.thisMac, FakeSSH.machine] {
            let lines = try await withCheckedThrowingContinuation { (done: CheckedContinuation<[String], Error>) in
                DispatchQueue.main.async {
                    let invocation = Invocation(arguments: [], environment: env)
                    let run = machine.isRemote
                        ? AgentRun(command: "botchu-subagent", invocation: invocation, on: machine, folder: root.path)
                        : AgentRun(command: "botchu-subagent", invocation: invocation, directory: root)
                    var output: [String] = []
                    run.onLines = { output += $0 }
                    run.onExit = { status, _ in
                        if status == 0 { done.resume(returning: output) }
                        else { done.resume(throwing: SubagentTransport.Failure(message: "Helper exited \(status)")) }
                    }
                    do { try run.start() } catch { done.resume(throwing: error) }
                }
            }
            #expect(lines == [context + "|" + endpoint.ipcDirectory])
        }
    }
}
