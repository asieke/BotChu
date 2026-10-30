import Foundation
import Testing
@testable import BotChuCore

/// `timeout` on every CLI session's PATH (#366). Times are generous upper bounds, except where the
/// limit itself is what's checked.
@Suite struct TimeoutShimTests {
    /// A helpers' bin folder with the shim installed as the app installs it, removed afterwards.
    private func withShim(_ body: (URL) async throws -> Void) async throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-timeout-\(UUID().uuidString)/bin")
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }
        try SubagentHookInstaller.install(binDirectory: bin)
        try await body(bin)
    }

    private func timeout(_ bin: URL, _ arguments: [String], path: String = "/usr/bin:/bin") async -> Shell.Result {
        let shim = bin.appendingPathComponent(TimeoutShim.folder).appendingPathComponent(TimeoutShim.name)
        return await ChildProcess.run(shim.path, arguments, environment: ["PATH": path], timeout: 30)
    }

    /// Whether every process in `pids` has ended within `seconds`.
    private func gone(_ pids: [pid_t], within seconds: TimeInterval) async -> Bool {
        let limit = Date().addingTimeInterval(seconds)
        while pids.contains(where: { kill($0, 0) == 0 }), Date() < limit { try? await Task.sleep(for: .milliseconds(20)) }
        return !pids.contains { kill($0, 0) == 0 }
    }

    @Test func itIsInstalledWithTheHelpersAndLastOnPATH() async throws {
        try await withShim { bin in
            let folder = bin.appendingPathComponent(TimeoutShim.folder)
            let shim = folder.appendingPathComponent(TimeoutShim.name)
            #expect(try String(contentsOf: shim, encoding: .utf8) == TimeoutShim.script)
            #expect((try FileManager.default.attributesOfItem(atPath: shim.path)[.posixPermissions] as? Int) == 0o755)
            #expect((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) == 0o700)
            // After login, as a turn's shell: the helpers first, the shim last, so a real timeout wins.
            let prefix = AgentRun.delegationShellPrefix(["BOTCHU_BIN_DIR": bin.path])
            let real = bin.deletingLastPathComponent().appendingPathComponent("coreutils")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(to: real.appendingPathComponent("timeout"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.appendingPathComponent("timeout").path)
            for (path, found) in [("/usr/bin:/bin", shim.path), (real.path + ":/usr/bin:/bin", real.appendingPathComponent("timeout").path)] {
                let result = await ChildProcess.run("/bin/zsh", ["-f", "-c", prefix + "printf '%s\\n' \"$PATH\"; command -v timeout"],
                                                    environment: ["PATH": path], timeout: 30)
                let lines = result.output.split(separator: "\n").map(String.init)
                #expect(lines.first.map { $0.hasPrefix(bin.path + ":") && $0.hasSuffix(":" + folder.path) } == true, "\(lines)")
                #expect(lines.last == found)
            }
        }
    }

    @Test func atItsLimitItEndsTheCommandAndWhatItStartedWith124() async throws {
        try await withShim { bin in
            let started = Date()
            let result = await timeout(bin, ["1", "/bin/sh", "-c", "sleep 30 & echo $$ $!; wait"])
            let took = Date().timeIntervalSince(started)
            #expect(result.status == 124)
            #expect(took >= 1 && took < 10, "\(took)")
            let pids = result.output.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            #expect(pids.count == 2)
            #expect(await gone(pids, within: 1))
        }
    }

    @Test func itExitsAsGNUsDoes() async throws {
        try await withShim { bin in
            #expect(await timeout(bin, ["5", "/bin/sh", "-c", "exit 7"]).status == 7)
            #expect(await timeout(bin, ["0", "/usr/bin/true"]).status == 0)
            #expect(await timeout(bin, ["5", "/bin/sh", "-c", "kill -USR1 $$"]).status == 128 + SIGUSR1)
            #expect(await timeout(bin, ["5", "/bin/echo", "-n", "passed", "on"]).output == "passed on")
            // KILL at the limit shows as 137; --preserve-status gives the command's own status.
            #expect(await timeout(bin, ["-s", "KILL", "0.2", "/bin/sleep", "30"]).status == 137)
            #expect(await timeout(bin, ["-k", "0.2", "0.2", "/bin/sh", "-c", "trap '' TERM; sleep 30"]).status == 137)
            #expect(await timeout(bin, ["--preserve-status", "0.2s", "/bin/sleep", "30"]).status == 128 + SIGTERM)
            #expect(await timeout(bin, ["--signal=INT", "0.2", "/bin/sleep", "30"]).status == 124)
            #expect(await timeout(bin, ["1", "/nonexistent/botchu-command"]).status == 127)
            #expect(await timeout(bin, ["1", "/tmp"]).status == 126)
            let unsupported = await timeout(bin, ["--bogus", "1", "/usr/bin/true"])
            #expect(unsupported.status == 125)
            #expect(unsupported.errors.contains("-s SIGNAL, -k DURATION"))
            #expect(await timeout(bin, ["1x", "/usr/bin/true"]).status == 125)
            #expect(await timeout(bin, ["1"]).status == 125)
        }
    }

    @Test func aStopSignalReachesTheCommandsGroup() async throws {
        try await withShim { bin in
            let file = bin.deletingLastPathComponent().appendingPathComponent("sleeper")
            let process = Process()
            process.executableURL = bin.appendingPathComponent(TimeoutShim.folder).appendingPathComponent(TimeoutShim.name)
            process.arguments = ["30", "/bin/sh", "-c", "sleep 30 & echo $! > \"$0\"; wait", file.path]
            process.environment = ["PATH": "/usr/bin:/bin"]
            try process.run()
            let limit = Date().addingTimeInterval(10)
            while (try? String(contentsOf: file, encoding: .utf8))?.hasSuffix("\n") != true, Date() < limit {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let sleeper = pid_t((try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            #expect(sleeper > 0)
            // As a CLI ending its tool command: TERM to the shim, which passes it on.
            process.terminate()
            while process.isRunning, Date() < limit { try? await Task.sleep(for: .milliseconds(20)) }
            #expect(process.terminationStatus == 128 + SIGTERM)
            #expect(await gone([sleeper], within: 1))
        }
    }

    @Test func gtimeoutRunsInsteadWhenThereIsOne() async throws {
        try await withShim { bin in
            let coreutils = bin.deletingLastPathComponent().appendingPathComponent("coreutils")
            try FileManager.default.createDirectory(at: coreutils, withIntermediateDirectories: true)
            let gtimeout = coreutils.appendingPathComponent("gtimeout")
            try "#!/bin/sh\necho \"gtimeout $*\"\n".write(to: gtimeout, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gtimeout.path)
            let result = await timeout(bin, ["5", "/bin/echo", "hi"], path: coreutils.path + ":/usr/bin:/bin")
            #expect(result.output == "gtimeout 5 /bin/echo hi\n")
        }
    }

    @Test func aHostGetsItBesideItsHelpers() async throws {
        let transport = SubagentTransport(machine: FakeSSH.machine, namespace: UUID(), invocationID: UUID())
        let endpoint = try await transport.prepare(script: "#!/bin/sh\n", roster: Data("[]".utf8))
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: endpoint.ipcDirectory).deletingLastPathComponent()) }
        let shim = URL(fileURLWithPath: endpoint.binDirectory).appendingPathComponent(TimeoutShim.folder).appendingPathComponent(TimeoutShim.name)
        #expect(try String(contentsOf: shim, encoding: .utf8) == TimeoutShim.script)
        #expect(FileManager.default.isExecutableFile(atPath: shim.path))
        try await transport.close()
    }
}
