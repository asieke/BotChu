import Foundation
import Testing
@testable import BotChuCore

/// #107's measurements, opt-in and not part of `check`: what saving a conversation costs the main
/// actor now and before, how long a save takes to be written, how many bytes it writes and how many
/// states it keeps, for 1,500- and 5,000-message histories and multi-megabyte tool output; and what
/// handing a 300-call turn to run reviews costs the main actor. It asserts nothing about time.
///
///     BOTCHU_PERSISTENCE_BENCHMARK=/tmp/persistence.txt swift test --configuration release \
///         --package-path macOS --filter persistenceBenchmark
@MainActor @Suite struct PersistenceBenchmarkTests {
    struct Sample {
        var values: [Double] = []
        mutating func add(_ value: Double) { values.append(value) }
        var line: String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "–" }
            let median = sorted[sorted.count / 2]
            let p95 = sorted.count >= 30 ? String(format: "%.3f", sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1]) : "–"
            return String(format: "%.3f / %@ / %.3f (n=%d)", median, p95, sorted.last!, sorted.count)
        }
    }

    static func ms(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

    static func history(_ count: Int, payload: Int) -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(role: index % 3 == 0 ? .assistant : .tool, text: index % 3 == 0 ? "A short synthetic answer." : "",
                        toolID: "call-\(index)", toolName: "read_file", toolInput: "synthetic.swift",
                        toolOutput: String(repeating: "x", count: payload), toolState: .done)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTCHU_PERSISTENCE_BENCHMARK"] != nil))
    func persistenceBenchmark() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-persistence-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var lines = ["#107 persistence benchmark · \(ProcessInfo.processInfo.hostName) · \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "\(ProcessInfo.processInfo.activeProcessorCount) cores · warm file cache (each file written before timing) · synthetic data",
                     "Times in ms, median / p95 / max (p95 only with 30 or more samples).", ""]
        lines.append("messages | file MiB | main actor, before (sync checkpoint) | main actor, now (ask) | written after asking | burst of 30: writes, coalesced, bytes, peak states kept")
        for (count, payload) in [(1_500, 1_024), (5_000, 1_024), (1_500, 8_192)] {
            let home = BotHome(workspace: root.appendingPathComponent("\(count)-\(payload)").path)
            let messages = Self.history(count, payload: payload)
            try home.saveThread(messages)
            let bytes = (try FileManager.default.attributesOfItem(atPath: home.threadURL.path)[.size] as? NSNumber)?.intValue ?? 0
            var before = Sample()
            var queue = MessageQueue()
            for _ in 0..<30 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = home.checkpoint(messages, queue: &queue)
                before.add(Self.ms(since: start))
            }
            let storage = StorageQueue()
            let files = ConversationStorage(storage: storage, home: home, task: nil)
            let access = ConversationStorage.Queue(get: { nil }, set: { _ in }, files: { nil })
            var asking = Sample(), written = Sample()
            for _ in 0..<30 {
                let start = DispatchTime.now().uptimeNanoseconds
                let elapsed: Double = await withCheckedContinuation { continuation in
                    files.saveTranscript(messages, queue: access, failed: { _ in }) { _ in continuation.resume(returning: Self.ms(since: start)) }
                    asking.add(Self.ms(since: start))
                }
                written.add(elapsed)
            }
            // A burst: 30 saves asked for one after another, each with one more message.
            let burst = StorageQueue()
            let burstFiles = ConversationStorage(storage: burst, home: home, task: nil)
            var growing = messages
            for n in 0..<30 {
                growing.append(ChatMessage(role: .note, text: "note \(n)"))
                burstFiles.saveTranscript(growing, version: n, queue: access, failed: { _ in })
            }
            await burst.settle()
            let stats = burst.stats
            lines.append(String(format: "%d × %d B | %.2f | %@ | %@ | %@ | %d, %d, %.1f MiB, %d", count, payload, Double(bytes) / 1_048_576,
                                before.line, asking.line, written.line, stats.runs, stats.coalesced, Double(stats.bytesWritten) / 1_048_576, stats.peakRetained))
        }

        // Handing a 300-call task turn to run reviews: the main actor claims it; the request is built off it.
        lines += ["", "run review handover, 300 tool calls | main actor (claim and hand over) | request built off the main actor"]
        let bot = Bot(name: "Bench", workspace: root.appendingPathComponent("bench-bot").path)
        try BotHome(workspace: bot.workspace).save(bot)
        let task = BotTask(for: bot, repo: "asieke/BotChu", checkout: "/tmp/x", work: nil, brief: "Fix the thing")
        var thread: [ChatMessage] = [ChatMessage(role: .user, text: "Fix the thing")]
        for i in 0..<300 {
            thread.append(ChatMessage(role: .tool, text: "", toolID: "t\(i)", toolName: i % 2 == 0 ? "Bash" : "Read",
                                      toolInput: "cd /Users/x/Desktop/WORKSPACE/BotChu && rg -n \"token\" macOS/Sources | head -50 # \(i)",
                                      toolOutput: String(repeating: "macOS/Sources/BotChuCore/Store.swift:42: let token = value\n", count: 30),
                                      toolState: i % 17 == 0 ? .failed : .done))
            if i % 10 == 0 { thread.append(ChatMessage(role: .assistant, text: String(repeating: "Progress note with `code`. ", count: 20))) }
        }
        let evaluator = RunEvaluator(workspace: { _ in bot.workspace }, sharedMemoryPath: { "" }, teamPath: { "" })
        evaluator.runner = { _ in "" }
        evaluator.limits.delay = 3_600
        var handover = Sample(), build = Sample()
        for _ in 0..<30 {
            // A turn of its own each time (its first message names it).
            let turn = [thread[0], ChatMessage(role: .assistant, text: "Starting.")] + thread.dropFirst()
            let subject = try #require(EvaluationRequest.taskTurnSubject(task, of: bot, thread: turn, turnStart: 1))
            let start = DispatchTime.now().uptimeNanoseconds
            evaluator.enqueue(subject, workspace: bot.workspace, account: task.account) { toolFree in
                EvaluationRequest.taskTurn(task, of: bot, thread: turn, turnStart: 1, ending: .finished, error: nil, machine: "This Mac", snapshot: toolFree)
            }
            handover.add(Self.ms(since: start))
            let built = DispatchTime.now().uptimeNanoseconds
            _ = EvaluationRequest.taskTurn(task, of: bot, thread: turn, turnStart: 1, ending: .finished, error: nil, machine: "This Mac")
            build.add(Self.ms(since: built))
        }
        await evaluator.settle()
        lines.append("\(thread.count) messages | \(handover.line) | \(build.line)")

        let text = lines.joined(separator: "\n") + "\n"
        print(text)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_PERSISTENCE_BENCHMARK"], path.hasPrefix("/") {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
