import Foundation
import Testing
@testable import BotChuCore

/// #250: a bot is an agent, which owns tasks and scheduled jobs, or a specialist, which is only
/// called as a sub-agent and keeps its own Home, memory and account all the same.
@Suite struct SpecialistTests {
    let at = JobScheduleTests.at

    func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("botchu-specialist-\(UUID().uuidString)")
    }

    @Test func aBotSavedBeforeRolesLoadsAsAnAgent() throws {
        let bot = Bot(name: "Scout", workspace: "/tmp/scout")
        var object = try #require(try JSONSerialization.jsonObject(with: Store.encoder.encode(bot)) as? [String: Any])
        #expect(object["role"] as? String == "agent")
        object["role"] = nil
        let decoded = try Store.decoder.decode(Bot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.role == .agent && !decoded.isSpecialist && decoded.canOwnTasks)
        // Nothing else changes (dates keep whole seconds in bot.json either way).
        #expect(decoded == (try Store.decoder.decode(Bot.self, from: Store.encoder.encode(bot))))
        // An index from before roles too.
        let entries = try Store.decoder.decode([Store.Entry].self, from: Data(#"[{"id":"\#(bot.id.uuidString)","workspace":"/tmp/scout"}]"#.utf8))
        #expect(entries == [Store.Entry(id: bot.id, workspace: "/tmp/scout")])
        #expect(entries.first?.role == nil)
    }

    @Test func onlyAgentsCanOwnTasks() {
        let agent = Bot(name: "Builder", workspace: "/tmp/builder")
        let specialist = Bot(name: "Mike Ross Esq.", workspace: "/tmp/mike", role: .specialist)
        var remote = Bot(name: "Danny Muse", workspace: "", role: .specialist)
        remote.kind = .remoteQueue
        #expect(agent.canOwnTasks && !agent.isSpecialist && agent.taskOwnershipProblem == nil)
        #expect(!specialist.canOwnTasks && specialist.isSpecialist)
        // A remote queue bot is never a specialist, whatever its saved role: it is messaged.
        #expect(!remote.canOwnTasks && !remote.isSpecialist)
        #expect(remote.taskOwnershipProblem == "Remote queue bots do not run local tasks.")
        #expect(specialist.taskOwnershipProblem
                == "“Mike Ross Esq.” is a specialist and cannot own tasks; call it with botchu-subagent instead.")
        #expect(Bot.Role.allCases == [.agent, .specialist])
    }

    /// Switching keeps everything else: the role is saved in bot.json and index.json, and the bot's
    /// workspace, memory and conversations stay as they were.
    @Test func theRoleRoundTripsWithItsWorkspaceMemoryAndThreads() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root.appendingPathComponent("support"))
        var bot = Bot(name: "David Wallace", title: "CFO", accountID: "codex-work", model: "gpt-5.5", reasoningEffort: .high,
                      workspace: root.appendingPathComponent("david").path, createdAt: at("2026-10-01T09:00:00Z"))
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        let thread = [ChatMessage(role: .user, text: "Budget?"), ChatMessage(role: .assistant, text: "Tight.")]
        let taskID = UUID()
        try home.saveThread(thread)
        try home.saveThread(thread, task: taskID)
        let memory = URL(fileURLWithPath: bot.workspace).appendingPathComponent(BotContext.memoryFile)
        try "# David\n- Prefers quarterly reviews.\n".write(to: memory, atomically: true, encoding: .utf8)

        for role in [Bot.Role.specialist, .agent, .specialist] {
            bot.role = role
            try home.save(bot)
            try store.saveIndex(Store.entries(for: [bot], sections: [bot.id: "Finance"], missing: []))
            let loaded = store.loadBots()
            #expect(loaded.bots == [bot])
            #expect(loaded.bots.first?.role == role)
            #expect(loaded.sections == [bot.id: "Finance"])
            #expect(store.loadIndex().first?.role == (role == .specialist ? .specialist : nil))
            #expect(home.loadThread().map(\.id) == thread.map(\.id) && home.loadThread().map(\.text) == ["Budget?", "Tight."])
            #expect(home.loadThread(task: taskID).map(\.id) == thread.map(\.id))
            #expect(try String(contentsOf: memory, encoding: .utf8) == "# David\n- Prefers quarterly reviews.\n")
        }
        #expect(try String(contentsOf: home.url.appendingPathComponent("bot.json"), encoding: .utf8).contains(#""role" : "specialist""#))
    }

    @Test func aSpecialistsAgentsFileHasNoTasks() {
        let roster = [BotRosterEntry(bot: Bot(name: "Builder", title: "Ships code", workspace: "/tmp/builder"))]
        let agent = BotContext.agentsFile(bot: Bot(name: "Builder", workspace: "/tmp/builder"), sharedMemoryPath: "/shared",
                                          availableBots: roster)
        let specialist = BotContext.agentsFile(bot: Bot(name: "Mike", workspace: "/tmp/mike", role: .specialist),
                                               sharedMemoryPath: "/shared", availableBots: roster)
        #expect(agent.contains("## Tasks") && agent.contains(".botchu/dispatch/"))
        #expect(!agent.contains("## Role"))
        #expect(!specialist.contains("## Tasks") && !specialist.contains(".botchu/dispatch/"))
        #expect(specialist.contains("## Role\nYou are a specialist: other bots call you as a sub-agent with `botchu-subagent`"))
        // The rest of the file is the same.
        #expect(specialist.contains("## Your history") && specialist.contains("## Replies") && specialist.contains("<subagents>"))
        #expect(specialist.contains("never edit them.\n\n## Role\n") && specialist.contains("with `botchu-task create`.\n\n## Replies\n"))
        #expect(agent.contains("never edit them.\n\n## Replies\n"))
    }

    @Test func theDelegationRosterMarksSpecialistsAsSubagentOnly() throws {
        let builder = Bot(name: "Builder", title: "Ships code", workspace: "/tmp/builder")
        let lawyer = Bot(name: "Mike Ross Esq.", title: "Legal", workspace: "/tmp/mike", role: .specialist)
        let roster = [BotRosterEntry(bot: builder), BotRosterEntry(bot: lawyer)]
        #expect(roster.map(\.isSpecialist) == [false, true])
        #expect(roster[0].specialist == nil)
        let section = BotContext.subagentsSection(availableBots: roster)
        #expect(section.contains("- `builder` (Builder; \(builder.id.uuidString.lowercased())) — Ships code\n"))
        #expect(section.contains("- `mike-ross-esq` (Mike Ross Esq.; \(lawyer.id.uuidString.lowercased())) — Legal [specialist: sub-agent only]"))
        #expect(section.contains("Bots marked specialist are sub-agent only: call them with `botchu-subagent`, never `botchu-task create`"))
        // Without a specialist, nothing about them.
        let agentsOnly = BotContext.subagentsSection(availableBots: [roster[0]])
        #expect(!agentsOnly.contains("specialist"))
        // The roster file carries it, and older roster files without it read as agents.
        let decoded = try SubagentIPC.decode([BotRosterEntry].self, from: SubagentIPC.encode(roster))
        #expect(decoded == roster)
        let old = try SubagentIPC.decode(BotRosterEntry.self, from: Data(
            #"{"id":"\#(builder.id.uuidString)","slug":"builder","name":"Builder","title":"","emoji":"🤖"}"#.utf8))
        #expect(!old.isSpecialist)
    }

    /// `botchu-task create --agent` and a dispatch's `agent` refuse a specialist, while
    /// `botchu-subagent` still finds it.
    @Test func aSpecialistIsRefusedATaskButResolvesAsASubagent() throws {
        let builder = Bot(name: "Builder", workspace: "/tmp/builder")
        let lawyer = Bot(name: "Mike Ross Esq.", workspace: "/tmp/mike", role: .specialist)
        var remote = Bot(name: "Danny Muse", workspace: "")
        remote.kind = .remoteQueue
        let bots = [builder, lawyer, remote]
        #expect(try SubagentResolver.resolveTaskOwner("builder", bots: bots) == builder)
        for name in ["Mike Ross Esq.", "mike-ross-esq", lawyer.id.uuidString] {
            #expect(throws: SubagentError.invalid("“Mike Ross Esq.” is a specialist and cannot own tasks; call it with botchu-subagent instead.")) {
                try SubagentResolver.resolveTaskOwner(name, bots: bots)
            }
            // A sub-agent run resolves among the local bots, as SubagentRuntime asks.
            #expect(try SubagentResolver.resolve(name, bots: bots.filter { !$0.isRemoteQueue }, list: "botchu-subagent list") == lawyer)
        }
        // The remote queue bot isn't a Task's owner either.
        #expect(throws: SubagentError.invalid("No BotChu agent matches ‘danny-muse’. Run botchu-task list.")) {
            try SubagentResolver.resolveTaskOwner("danny-muse", bots: bots)
        }
    }

    // MARK: Jobs

    typealias FakeStore = JobEngineTests.FakeStore
    typealias Clock = JobEngineTests.Clock

    func daily(_ bot: UUID, hour: Int = 9) -> Job {
        Job(botID: bot, title: "Triage \(hour)", prompt: "Triage",
            schedule: JobSchedule(kind: .daily, hour: hour, minute: 0, timeZone: JobScheduleTests.newYork), createdAt: at("2026-10-23T14:00:00Z"))
    }

    /// Becoming a specialist pauses the agent's jobs that are on, with a reason of its own; becoming an
    /// agent again resumes only those. A job paused for another reason stays paused, another agent's
    /// jobs are left alone, and nothing runs while it is a specialist, scheduled or Run Now.
    @Test func aRoleSwitchPausesAndResumesOnlyTheJobsItPaused() throws {
        let clock = Clock(at("2026-10-23T14:00:00Z")), store = FakeStore()
        let botID = UUID(), otherID = UUID()
        var specialists: Set<UUID> = []
        let engine = JobEngine(now: { clock.now }, persist: store.persist,
                               refusal: { specialists.contains($0) ? "“Lawyer” is a specialist and cannot own tasks; call it with botchu-subagent instead." : nil })
        try engine.save(daily(botID, hour: 9))
        try engine.save(daily(botID, hour: 10))
        try engine.save(daily(botID, hour: 11))
        try engine.save(daily(otherID, hour: 9))
        let jobs = engine.jobs(of: botID).map(\.id)
        let other = try #require(engine.jobs(of: otherID).first?.id)
        // One paused by the owner, before the switch.
        try engine.setEnabled(jobs[2], false)

        #expect(JobEngine.pausedBySpecialistSwitch(of: botID, in: engine.jobs).map(\.id) == [jobs[0], jobs[1]])
        specialists.insert(botID)
        #expect(try engine.switchRole(of: botID, toSpecialist: true) == [jobs[0], jobs[1]])
        for id in jobs[0...1] {
            #expect(engine.job(id)?.enabled == false)
            #expect(engine.job(id)?.pauseReason == JobEngine.specialistPauseReason)
            #expect(store.saved[id]?.pauseReason == JobEngine.specialistPauseReason)
        }
        #expect(engine.job(jobs[2])?.pauseReason == nil)
        #expect(engine.job(other)?.enabled == true)
        #expect(JobEngine.pausedBySpecialistSwitch(of: botID, in: engine.jobs).isEmpty)

        // While it is a specialist: no scheduled run, no Run Now, no resuming, no new job.
        clock.now = at("2026-10-24T13:00:30Z")
        let launches = engine.tick(busy: { _ in false })
        #expect(launches.map(\.job.id) == [other])
        #expect(throws: JobEngine.Problem.invalid("“Lawyer” is a specialist and cannot own tasks; call it with botchu-subagent instead.")) {
            try engine.runNow(jobs[0], busy: { _ in false })
        }
        #expect(throws: JobEngine.Problem.self) { try engine.setEnabled(jobs[0], true) }
        #expect(throws: JobEngine.Problem.self) { try engine.save(daily(botID, hour: 12)) }
        var renamed = try #require(engine.job(jobs[0]))
        renamed.title = "Renamed"
        try engine.save(renamed)
        #expect(engine.job(jobs[0])?.title == "Renamed" && engine.job(jobs[0])?.enabled == false)
        renamed.enabled = true
        #expect(throws: JobEngine.Problem.self) { try engine.save(renamed) }
        for id in jobs { #expect(engine.job(id)?.runs.isEmpty == true) }

        // An agent again: the two it paused resume, from now; the owner's pause stays.
        specialists.remove(botID)
        clock.now = at("2026-10-24T15:00:00Z")
        #expect(try engine.switchRole(of: botID, toSpecialist: false) == [jobs[0], jobs[1]])
        for id in jobs[0...1] { #expect(engine.job(id)?.enabled == true && engine.job(id)?.pauseReason == nil) }
        #expect(engine.job(jobs[0])?.nextRun(now: clock.now) == at("2026-10-25T13:00:00Z"))
        #expect(engine.job(jobs[1])?.nextRun(now: clock.now) == at("2026-10-25T14:00:00Z"))
        #expect(engine.job(jobs[2])?.enabled == false)
        // Time while it was a specialist isn't made up.
        #expect(engine.tick(busy: { _ in false }).isEmpty)
    }

    @Test func aJobPausedAfterFailuresStaysPausedAcrossASwitch() throws {
        let clock = Clock(at("2026-10-23T14:00:00Z")), store = FakeStore()
        let botID = UUID()
        var specialist = false
        let engine = JobEngine(now: { clock.now }, persist: store.persist, refusal: { _ in specialist ? "specialist" : nil })
        try engine.save(daily(botID))
        let id = try #require(engine.jobs.first?.id)
        for _ in 0..<JobLimits.pauseAfterFailures {
            let launch = try #require(try engine.runNow(id, busy: { _ in false }).first)
            _ = engine.finish(launch.run.id, outcome: .failed, summary: "Failed", busy: { _ in false })
        }
        let reason = try #require(engine.job(id)?.pauseReason)
        #expect(engine.job(id)?.enabled == false)
        specialist = true
        #expect(try engine.switchRole(of: botID, toSpecialist: true).isEmpty)
        specialist = false
        #expect(try engine.switchRole(of: botID, toSpecialist: false).isEmpty)
        #expect(engine.job(id)?.enabled == false && engine.job(id)?.pauseReason == reason)
    }

    /// A run already waiting for a bot that became a specialist (a Run Now of a paused job, or a save
    /// that failed when it switched) never starts: it is recorded skipped, with why.
    @Test func theEngineStartsNoRunOfASpecialist() throws {
        let clock = Clock(at("2026-10-23T14:00:00Z")), store = FakeStore()
        let botID = UUID()
        var specialist = false
        let engine = JobEngine(now: { clock.now }, persist: store.persist, refusal: { _ in specialist ? "“Mike” is a specialist" : nil })
        try engine.save(daily(botID))
        let id = try #require(engine.jobs.first?.id)
        // Busy, so Run Now's run waits.
        #expect(try engine.runNow(id, busy: { _ in true }).isEmpty)
        #expect(engine.job(id)?.activeRun?.outcome == .waiting)
        // The role changes without its jobs being paused (as when their saves fail).
        specialist = true
        clock.now = at("2026-10-24T13:00:30Z")
        #expect(engine.tick(busy: { _ in false }).isEmpty)
        #expect(engine.startWaiting(busy: { _ in false }).isEmpty)
        #expect(engine.job(id)?.activeRun == nil)
        #expect(engine.job(id)?.runs.map(\.outcome) == [.skipped])
        #expect(engine.job(id)?.runs.last?.summary == "“Mike” is a specialist")
        // The occurrence that came due wasn't reserved, so nothing about it is recorded.
        #expect(engine.job(id)?.handledThrough == at("2026-10-23T14:00:00Z"))
    }
}
