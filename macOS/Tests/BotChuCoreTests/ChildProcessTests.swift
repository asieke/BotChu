import Foundation
import Testing
@testable import BotChuCore

/// The one runner for the programs BotChu waits for (#339). Times are generous upper bounds only:
/// what each test guards against is a wait of 30 seconds or forever.
@Suite struct ChildProcessTests {
    private func run(_ script: String, input: Data? = nil, timeout: TimeInterval = 30, outputLimit: Int = ChildProcess.outputLimit,
                     mergeErrors: Bool = false) async -> Shell.Result {
        await ChildProcess.run("/bin/sh", ["-c", script], environment: ["PATH": "/usr/bin:/bin"], input: input, timeout: timeout,
                               outputLimit: outputLimit, mergeErrors: mergeErrors)
    }

    @Test func itKeepsWhatAProgramPrintsAndHowItExited() async {
        let separate = await run("echo out; echo err >&2; exit 3")
        #expect(separate == Shell.Result(status: 3, output: "out\n", errors: "err\n"))
        let merged = await run("echo out; echo err >&2", mergeErrors: true)
        #expect(merged.status == 0)
        #expect(merged.output.split(separator: "\n").sorted() == ["err", "out"])
        #expect(merged.errors.isEmpty)
        let missing = await ChildProcess.run("/nonexistent/botchu-tool", [], environment: [:], timeout: 30)
        #expect(missing.status == -1)
        #expect(!missing.errors.isEmpty)
        #expect(!missing.timedOut)
    }

    @Test func theTimeLimitStopsAProgramThatIgnoresTERM() async {
        let started = Date()
        // The background sleep is in its process group and ignores TERM too, so only KILL ends it.
        let result = await run("trap '' TERM; sleep 30 & echo $!; wait", timeout: 0.2)
        #expect(result.timedOut)
        #expect(result.status == -1)
        #expect(result.errors.hasSuffix("BotChu stopped it: it was still running after 0.2 s."))
        #expect(Date().timeIntervalSince(started) < 10)
        let sleeper = pid_t(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(sleeper > 0)
        let gone = Date().addingTimeInterval(5)
        while kill(sleeper, 0) == 0, Date() < gone { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(kill(sleeper, 0) != 0)
    }

    @Test func somethingLeftHoldingItsOutputIsStoppedAtTheTimeLimit() async {
        let started = Date()
        let result = await run("sleep 30 & echo done", timeout: 0.3)
        #expect(result.output == "done\n")
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func outputPastTheLimitIsReadAndDropped() async {
        let result = await run("yes | head -c 300000; yes | head -c 300000 >&2", outputLimit: 10_000)
        #expect(result.status == 0)
        #expect(!result.timedOut)
        #expect(result.output.utf8.count == 10_000)
        #expect(result.errors.utf8.count == 10_000)
    }

    @Test func inputIsGivenOnStdin() async {
        let input = Data(repeating: 97, count: 300_000)
        #expect(await run("wc -c", input: input).output.trimmingCharacters(in: .whitespacesAndNewlines) == "300000")
        // A program that never reads it isn't held up by it.
        #expect(await run("exit 0", input: input).ok)
    }

    @Test func cancellingTheTaskStopsTheProgram() async throws {
        let started = Date()
        let task = Task { await ChildProcess.run("/bin/sleep", ["30"], environment: [:], timeout: 30) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value
        #expect(result.status == -1)
        #expect(!result.timedOut)
        #expect(result.errors == "BotChu stopped it: cancelled.")
        #expect(Date().timeIntervalSince(started) < 10)
        // Cancelled before it starts, it isn't started.
        let early = Task {
            try? await Task.sleep(for: .seconds(30))
            return await ChildProcess.run("/bin/sleep", ["30"], environment: [:], timeout: 30)
        }
        early.cancel()
        #expect(await early.value.errors == "BotChu stopped it: cancelled.")
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func commandsHereAndOnAHostHaveTheTimeLimit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-child-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = Date()
        for machine in [Machine.thisMac, FakeSSH.machine] {
            let result = await machine.run(["sleep", "30"], in: folder.path, timeout: 0.5)
            #expect(result.timedOut)
            #expect(!result.ok)
            #expect(!result.output.contains(Shell.marker))
        }
        #expect(Date().timeIntervalSince(started) < 20)
    }
}
