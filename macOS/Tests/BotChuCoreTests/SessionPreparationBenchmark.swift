import Foundation
import Testing
@testable import BotChuCore

/// Opt-in, reproducible file workload. The latency probe measures a queued MainActor input/Stop
/// callback, not AppKit drawing; the runtime tests separately exercise draft edits and Stop.
@Suite struct SessionPreparationBenchmark {
    struct Sample: Codable {
        let mode: String
        let preparationMS: Double
        let mainCallbackMS: Double
    }

    @Test func sessionPreparationBenchmark() async throws {
        guard let output = ProcessInfo.processInfo.environment["BOTCHU_PREPARATION_BENCHMARK"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-preparation-benchmark-\(UUID()).noindex")
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = Bot(name: "Benchmark", workspace: root.appendingPathComponent("bot").path)
        let shared = root.appendingPathComponent("MEMORY.md").path
        let input = SessionPreparation.Input(bot: bot, sharedMemoryPath: shared)
        try await Task.detached {
            try Workspace.seed(bot: bot, sharedMemoryPath: shared)
            for file in [bot.workspace + "/INSTRUCTIONS.md", bot.workspace + "/MEMORY.md", bot.workspace + "/SOUL.md",
                         shared, root.appendingPathComponent("TEAM.md").path] {
                try String(repeating: "Context line with instructions and facts.\n", count: 500).write(toFile: file, atomically: true, encoding: .utf8)
            }
            let skills = Skills.sharedFolder(besideSharedMemory: shared)
            for index in 0..<24 {
                let folder = skills.appendingPathComponent("skill-\(index)")
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("references/deep"), withIntermediateDirectories: true)
                try "---\nname: skill-\(index)\ndescription: A benchmark workflow\n---\nSteps".write(
                    to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                for file in 0..<100 {
                    try Data("reference".utf8).write(to: folder.appendingPathComponent("references/deep/\(file).md"))
                }
            }
        }.value
        var samples: [Sample] = []
        // Reproduce the previous launch path: discovery with resource walks once for AGENTS,
        // again for the prompt, plus the five context reads, all on MainActor.
        for _ in 0..<6 {
            samples.append(try await measure("before") {
                try Workspace.seed(bot: bot, sharedMemoryPath: shared)
                let folder = Skills.sharedFolder(besideSharedMemory: shared)
                let skills = Skills.active(for: bot, shared: Skills.discover(in: folder, scope: .shared),
                                           own: Skills.discover(in: Skills.folder(of: bot), scope: .bot))
                try Workspace.prepareOwned(bot: bot, sharedMemoryPath: shared,
                    instructions: Workspace.read(bot.workspace + "/INSTRUCTIONS.md"), team: Workspace.read(root.appendingPathComponent("TEAM.md").path),
                    repositoriesPath: nil, machines: [], availableBots: [], skills: skills)
                try BotHome(workspace: bot.workspace).prepareDispatch()
                for path in [bot.workspace + "/INSTRUCTIONS.md", bot.workspace + "/MEMORY.md", bot.workspace + "/SOUL.md",
                             shared, root.appendingPathComponent("TEAM.md").path] { _ = Workspace.read(path) }
                _ = Skills.active(for: bot, shared: Skills.discover(in: folder, scope: .shared),
                                  own: Skills.discover(in: Skills.folder(of: bot), scope: .bot))
            })
        }
        let preparation = SessionPreparation(storage: StorageQueue())
        for index in 0..<6 {
            samples.append(try await measure(index == 0 ? "after-cold" : "after-reused") {
                _ = try await preparation.prepare(input)
            })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(samples).write(to: URL(fileURLWithPath: output), options: .atomic)
        print("Preparation benchmark: 24 skills, 2,400 resources, five 20 KB context files; \(preparation.statistics.prepared) preparation, \(preparation.statistics.reused) reuses. \(output)")
    }

    @MainActor private func measure(_ mode: String, operation: @MainActor () async throws -> Void) async throws -> Sample {
        let started = Date()
        let probe = Task { @MainActor in Date().timeIntervalSince(started) * 1_000 }
        try await operation()
        let duration = Date().timeIntervalSince(started) * 1_000
        return Sample(mode: mode, preparationMS: duration, mainCallbackMS: await probe.value)
    }
}
