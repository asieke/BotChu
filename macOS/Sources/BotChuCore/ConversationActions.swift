import Foundation

/// Changes waiting for a conversation's read or recovery. Reentrant changes go before the
/// remaining work; a read holds history changes, but never holds changes to a recovered queue.
@MainActor public final class ConversationActions {
    public struct Waiting {
        public enum Need { case recovery, idle, history }
        public var need: Need
        public var run: () -> Void
        public var cancel: (() -> Void)?
    }
    public private(set) var waiting: [Waiting] = []
    private var draining = false
    private var insertion = 0

    public init() {}

    private func meets(_ need: Waiting.Need, history: HistoryState, loaded: Bool) -> Bool {
        switch need {
        case .recovery: history.recovery != .recovering
        case .idle: !history.isBusy
        case .history: !history.isBusy && loaded
        }
    }

    @discardableResult public func later(needs: Waiting.Need, history: HistoryState, loaded: Bool,
                                          _ action: @escaping () -> Void, cancel: (() -> Void)? = nil) -> Bool {
        if meets(needs, history: history, loaded: loaded), draining || !waiting.contains(where: { $0.need == needs }) { return false }
        let next = Waiting(need: needs, run: action, cancel: cancel)
        if draining {
            waiting.insert(next, at: min(insertion, waiting.count))
            insertion += 1
        } else { waiting.append(next) }
        return true
    }

    @discardableResult public func drain(state: () -> (history: HistoryState, loaded: Bool)) -> Bool {
        guard !draining else { return false }
        draining = true
        defer { draining = false }
        var index = 0
        while index < waiting.count {
            let next = waiting[index], current = state()
            guard meets(next.need, history: current.history, loaded: current.loaded) else { index += 1; continue }
            waiting.remove(at: index)
            insertion = index
            next.run()
        }
        return true
    }

    public func cancel() {
        let pending = waiting
        waiting = []
        for next in pending { next.cancel?() }
    }

    public func needsRead(history: HistoryState, loaded: Bool) -> Bool {
        !history.isBusy && !loaded && waiting.contains { $0.need == .history }
    }
}

/// The optimistic chat preview belongs to one send. A late save/removal must not clear a newer
/// message's preview; Stop withdraws any preview, leaving the queued message to be resumed.
public enum SendingPreview {
    public static func clear(_ message: ChatMessage?, matching id: UUID? = nil, withdraw: () -> Void) {
        if id == nil || message?.id == id { withdraw() }
    }
}
