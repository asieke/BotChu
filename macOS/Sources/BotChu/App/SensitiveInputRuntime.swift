import Foundation
import Observation
import BotChuCore

/// Keeps metadata and completions only. The field's value stays in its view until direct delivery.
@MainActor @Observable
final class SensitiveInputRuntime {
    struct Prompt: Identifiable {
        var request: SensitiveInputRequest
        var botName: String
        var id: UUID { request.id }
    }
    private(set) var prompts: [Prompt] = [] {
        didSet { if prompts.first?.id != oldValue.first?.id { present(current) } }
    }
    @ObservationIgnored var present: (Prompt?) -> Void = { _ in }

    @ObservationIgnored private let write: @Sendable (String, String) throws -> Void

    init(write: @escaping @Sendable (String, String) throws -> Void = { try SensitiveInputDestination.save($0, to: $1) }) {
        self.write = write
        let panel = SensitiveInputPanel(runtime: self)
        present = { panel.show($0) }
    }

    var current: Prompt? { prompts.first }
    @ObservationIgnored private var replies: [UUID: (SensitiveInputResult.Status) -> Void] = [:]
    private(set) var saving: Set<UUID> = []
    @ObservationIgnored private var deliveries: [UUID: Task<Void, Error>] = [:]
    @ObservationIgnored private var cancellations: [UUID: SensitiveInputResult.Status] = [:]
    /// A cancellation can reach the mailbox before the request it withdraws.
    @ObservationIgnored private var withdrawn: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]

    func enqueue(_ request: SensitiveInputRequest, botName: String,
                 reject: ((SensitiveInputResult.Reason) -> Void)? = nil,
                 reply: @escaping (SensitiveInputResult.Status) -> Void) {
        guard replies[request.id] == nil else { return }
        if withdrawn[request.invocationID]?.contains(request.id) == true { reply(.cancelled); return }
        // Bound metadata retained by a turn that repeatedly creates then withdraws requests.
        guard (withdrawn[request.invocationID]?.count ?? 0) < 1024 else {
            if let reject { reject(.withdrawnLimit) } else { reply(.rejected) }; return
        }
        guard replies.count < 8 else {
            if let reject { reject(.queueFull) } else { reply(.rejected) }; return
        }
        replies[request.id] = reply
        prompts.append(Prompt(request: request, botName: botName))
        let remaining = max(0, request.createdAt.addingTimeInterval(SensitiveInputRequest.lifetime).timeIntervalSinceNow)
        timers[request.id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            self?.finish(request.id, status: .expired)
        }
    }

    func submit(_ value: String, id: UUID) async throws {
        guard let prompt = current, prompt.id == id, !saving.contains(id) else { throw SensitiveInputError.expired }
        guard Date() < prompt.request.createdAt.addingTimeInterval(SensitiveInputRequest.lifetime) else {
            finish(id, status: .expired)
            throw SensitiveInputError.expired
        }
        let destination = prompt.request.destination, write = self.write
        let delivery = Task.detached(priority: .userInitiated) {
            try write(value, destination)
        }
        saving.insert(id)
        deliveries[id] = delivery
        do {
            try await delivery.value
            deliveries[id] = nil
            saving.remove(id)
            cancellations[id] = nil
            // If Cancel arrived after the writer committed, delivery still succeeded. Report
            // that actual outcome instead of claiming cancellation while leaving a saved file.
            finish(id, status: .saved)
        } catch {
            deliveries[id] = nil
            saving.remove(id)
            if let cancelled = cancellations.removeValue(forKey: id) {
                finish(id, status: cancelled)
            } else { throw error }
        }
    }

    func finish(_ id: UUID, status: SensitiveInputResult.Status = .cancelled) {
        let delivery = deliveries[id]
        if let delivery {
            if cancellations[id] == nil { cancellations[id] = status }
            delivery.cancel()
        }
        let reply = delivery == nil ? replies.removeValue(forKey: id) : nil
        timers.removeValue(forKey: id)?.cancel()
        prompts.removeAll { $0.id == id }
        // The writer removes a partial file before the cancellation receipt is sent.
        if delivery != nil { return }
        reply?(status)
    }

    /// A helper can withdraw only a request in its own invocation's mailbox.
    func cancel(_ id: UUID, invocationID: UUID) {
        if let prompt = prompts.first(where: { $0.id == id }), prompt.request.invocationID != invocationID { return }
        if (withdrawn[invocationID]?.count ?? 0) < 1024 { withdrawn[invocationID, default: []].insert(id) }
        finish(id)
    }

    func cancel(invocationID: UUID) {
        for prompt in prompts.filter({ $0.request.invocationID == invocationID }) { finish(prompt.id) }
        withdrawn[invocationID] = nil
    }
}
