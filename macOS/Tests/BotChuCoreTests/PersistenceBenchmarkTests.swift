import Foundation
import Testing
@testable import BotChuCore

/// #107's measurements, opt-in and not part of `check`: what saving a conversation costs the main
/// actor now and before, how long a save takes to be written, how many bytes it writes and how many
/// states it keeps, for 1,500- and 5,000-message histories and multi-megabyte tool output; and what
/// handing a 300-call turn to run reviews costs the main actor, and reading it as a review starts. It asserts nothing about time.
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

        // Handing a 300-call task turn to run reviews: the main actor only extends the task's
        // stretch (#138); its day is read off the main actor, from the saved transcript, as a review starts.
        lines += ["", "run review handover, 300 tool calls | main actor (extend the stretch) | the day read off the main actor"]
        let bot = Bot(name: "Bench", workspace: root.appendingPathComponent("bench-bot").path)
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        var thread: [ChatMessage] = [ChatMessage(role: .user, text: "Fix the thing")]
        for i in 0..<300 {
            thread.append(ChatMessage(role: .tool, text: "", toolID: "t\(i)", toolName: i % 2 == 0 ? "Bash" : "Read",
                                      toolInput: "cd /Users/x/Desktop/WORKSPACE/BotChu && rg -n \"token\" macOS/Sources | head -50 # \(i)",
                                      toolOutput: String(repeating: "macOS/Sources/BotChuCore/Store.swift:42: let token = value\n", count: 30),
                                      toolState: i % 17 == 0 ? .failed : .done))
            if i % 10 == 0 { thread.append(ChatMessage(role: .assistant, text: String(repeating: "Progress note with `code`. ", count: 20))) }
        }
        let evaluator = RunEvaluator(bot: { $0 == bot.id ? bot : nil }, sharedMemoryPath: { "" }, teamPath: { "" })
        evaluator.runner = { _ in "" }
        var handover = Sample(), build = Sample()
        for _ in 0..<30 {
            // A task of its own each time, its turn saved as its end saves it.
            let task = BotTask(for: bot, repo: "asieke/BotChu", checkout: "/tmp/x", work: nil, brief: "Fix the thing")
            try home.save(task)
            let turn = thread.map { message in
                var message = message
                message.id = UUID()
                return message
            }
            try home.saveThread(turn, task: task.id)
            let conversation = ReviewConversation(botID: bot.id, taskID: task.id)
            let start = DispatchTime.now().uptimeNanoseconds
            evaluator.turnEnded(conversation, prompt: turn[0].id, last: turn.last!.id, accountID: task.accountID)
            handover.add(Self.ms(since: start))
            let stretch = try #require(evaluator.states[bot.id]?.stretches.first { $0.conversation == conversation })
            let input = ReviewDayInput(botID: bot.id, botName: bot.name, workspace: bot.workspace,
                                       sources: [ReviewDayInput.Source(stretch: stretch, workspace: bot.workspace, owner: bot.name)])
            let built = DispatchTime.now().uptimeNanoseconds
            _ = ReviewDay.build(input, limits: evaluator.limits)
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
