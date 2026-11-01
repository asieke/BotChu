import Foundation

/// The stop traversal is independent of where each CLI runs. Children are stopped before their
/// parent; an exiting CLI keeps its first cause and finishes after its workspace has been read.
@MainActor public enum SubagentStopTree {
    public static func stop(_ id: UUID, cause: SubagentInterruption.Cause = .owner,
                            recordCause: (UUID, SubagentInterruption.Cause) -> Void,
                            exiting: (UUID) -> Bool, children: (UUID) -> [UUID], stopRun: (UUID) -> Void) {
        recordCause(id, cause)
        guard !exiting(id) else { return }
        for child in children(id) {
            stop(child, cause: .parentStopped, recordCause: recordCause, exiting: exiting, children: children, stopRun: stopRun)
        }
        stopRun(id)
    }

    /// Stop in a conversation: its runs, but not another bot's cameo turns there and the runs
    /// beneath them, which have Stop of their own (#424).
    public static func stopRoot(_ runs: [SubagentRun], stop: (UUID, SubagentInterruption.Cause) -> Void) {
        let cameos = CameoRouting.cameoTrees(in: runs)
        for run in runs where run.phase.isActive && !cameos.contains(run.id) { stop(run.id, run.parentSubagentID == nil ? .owner : .parentStopped) }
    }
}

/// Terminal transcript and record must describe the same interruption, including its workspace.
public enum SubagentTerminalOutcome {
    /// `pausesOnLimit`: a run that failed on a usage limit naming its reset is paused until then
    /// (`SubagentInterruption.resetsAt`, #442) rather than failed for good.
    public static func apply(to record: inout SubagentRun, messages: inout [ChatMessage], toolCalls: Int,
                             cause: SubagentInterruption.Cause?, workspace: SubagentWorkspaceState?,
                             pausesOnLimit: Bool = false, now: Date = Date()) {
        ThreadAssembler.closeRunningTools(&messages)
        if record.phase == .completed { record.interruption = nil }
        if record.phase == .stopped || record.phase == .failed && record.startedAt != nil
            && !(record.errorMessage?.hasPrefix("Couldn't save the sub-agent transcript") ?? false) {
            var interruption = SubagentInterruption.of(messages, toolCalls: toolCalls,
                cause: record.phase == .failed ? .failed : cause ?? .owner, root: record.workingDirectory, workspace: workspace, at: now)
            if pausesOnLimit, record.phase == .failed {
                interruption.resetsAt = UsageLimit.resetDate(in: record.errorMessage ?? "", now: now)
            }
            record.interruption = interruption
            record.errorMessage = interruption.outcome(for: record, failure: record.errorMessage)
        }
        if let error = record.errorMessage { messages.append(ChatMessage(role: record.phase == .stopped ? .note : .error, text: error)) }
    }
}

/// The asynchronous part of Resume. Every suspension can invalidate the run or its caller; no
/// in-memory replacement is published until its snapshot has been saved and checked again.
@MainActor public enum SubagentResumeTransaction {
    public enum Stage { case loaded, saved }
    public struct Problem: Error { public let message: String; public init(_ message: String) { self.message = message } }

    public static func run<Prepared>(ids: [UUID], place: String,
        processes: ([UUID]) async -> Result<[Int32], SubagentLiveness.Problem>,
        workspace: () async -> SubagentWorkspaceState?,
        load: () async throws -> Void,
        validate: (Stage) -> String?,
        prepare: (SubagentWorkspaceState?) throws -> Prepared,
        save: (Prepared) async throws -> Void,
        replace: (Prepared) -> Void) async -> String? {
        switch await processes(ids) {
        case .failure(let problem): return problem.message + " Resume it again once it can be checked."
        case .success(let found) where !found.isEmpty:
            return "A CLI of it still runs on \(place) (pid \(found.prefix(5).map(String.init).joined(separator: ", "))). "
                + "Stop it, or let it end, then resume it."
        case .success: break
        }
        let state = await workspace()
        do { try await load() }
        catch let problem as Problem { return problem.message }
        catch { return "Couldn't read its transcript: \(error.localizedDescription)" }
        if let problem = validate(.loaded) { return problem }
        let prepared: Prepared
        do {
            prepared = try prepare(state)
            try await save(prepared)
        } catch { return "Couldn't save it: \(error.localizedDescription)" }
        if let problem = validate(.saved) { return problem }
        replace(prepared)
        return nil
    }

    public static func problem(current: SubagentRun?, finalizing: Bool, running: Bool, preparing: Bool,
                               callerAlive: Bool) -> String? {
        guard current?.isResumable == true, !finalizing, !running, !preparing else { return "It changed while it was being resumed." }
        guard callerAlive else { return "The asking turn has ended." }
        return nil
    }
}
