import Foundation

/// Runs BotChu's file work off the caller's thread (#107). Each target's work is named by a lane
/// (a path in the bot's `.botchu/`: a conversation's transcript and queue files, a task's or bot's
/// settings, a job run's transcript, a sub-agent run, a bot's logs, a review's record) and runs in
/// the order it was asked for; different lanes run side by side, so a slow write to one never holds
/// up another, nor the main thread.
///
/// Two kinds of work: `submit` runs every piece of work it is given, in order; `replace` keeps only
/// the latest state of something saved whole (a transcript, a queue), which takes the place of a
/// state given before it that hasn't been written yet, and is skipped when it is the state written
/// last (`version`). A replaced state is written at its first place in the lane, never after work
/// asked for later, so an older state never overwrites a newer one; at most one state waits and one
/// is written per slot, which bounds what is kept in memory. Whoever gave a replaced state hears
/// how the newer one went.
///
/// Results reach `done` on the main queue. `settle` waits until everything asked for has run and
/// reported (tests), `wait` blocks until the lanes' work has run (quitting, moving a bot's folder),
/// and `retire` drops what waits under a folder that is going away and refuses more, so a deleted
/// bot's folder is never made again.
public final class StorageQueue: @unchecked Sendable {
    /// One piece of work, as the test hook (`before`) sees it, just before it runs.
    public struct Work: Sendable, Equatable {
        public var lane: String
        /// What it saves: a slot's name (`replace`), or the label given to `submit`.
        public var label: String
    }

    /// What has been done, for measuring (#107's benchmark).
    public struct Statistics: Sendable, Equatable {
        /// Pieces of work run, replaced states written included.
        public var runs = 0
        /// States replaced by a newer one before they were written.
        public var coalesced = 0
        /// States skipped because they were the state written last.
        public var unchanged = 0
        /// Work dropped because its folder was retired first.
        public var dropped = 0
        /// Bytes the replaced states' writes reported.
        public var bytesWritten = 0
        /// The most replaced states kept at once, waiting or being written, across every slot.
        public var peakRetained = 0
        /// The longest a result took on the main thread, in its `done`: storage's own share of it.
        public var longestReport: TimeInterval = 0
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// The folder was deleted or moved before the work ran.
        case retired
        /// A state was dropped for a save that replaces it (`cancel`).
        case superseded

        public var errorDescription: String? {
            switch self {
            case .retired: "its folder was deleted or moved"
            case .superseded: "a newer save replaced it"
            }
        }
    }

    /// The queue the app writes through, one for the process, so a model made again (a relaunch in
    /// tests) reads files only after the writes asked for before (`wait`).
    public static let shared = StorageQueue()

    private let condition = NSCondition()
    private var lanes: [String: Lane] = [:]
    private var retired: [String] = []
    private var statistics = Statistics()
    /// Results waiting for the main queue to take them.
    private var reporting = 0
    /// Replaced states waiting for their delay, by lane and slot.
    private var delayed: Set<SlotKey> = []
    /// Replaced states kept now, and the bytes of each slot's last write.
    private var retained = 0
    private let before: (@Sendable (Work) -> Void)?
    private let qos: DispatchQoS

    /// `before` runs on the lane's thread just before each piece of work: tests slow writes down
    /// with it, or record where they ran.
    public init(qos: DispatchQoS = .userInitiated, before: (@Sendable (Work) -> Void)? = nil) {
        self.qos = qos
        self.before = before
    }

    private final class Lane {
        let queue: DispatchQueue
        /// Work submitted and not finished yet, waiting or running.
        var pending = 0
        var slots: [String: Slot] = [:]
        init(queue: DispatchQueue) { self.queue = queue }
    }

    private struct SlotKey: Hashable {
        var lane: String
        var slot: String
    }

    private struct Slot {
        /// The latest state not written yet, and what writes it; nil once taken.
        var value: Any?
        var write: (@Sendable (Any) throws -> Int)?
        var version: AnyHashable?
        var waiters: [@Sendable (Result<Any, Error>) -> Void] = []
        /// Whether a run that takes the latest state is waiting in the lane (or for its delay).
        var scheduled = false
        /// The version written last, so the same state isn't written twice.
        var written: AnyHashable?
    }

    // MARK: Asking

    /// Runs `work` off the caller's thread, after everything asked for on `lane` before it; `done`
    /// gets its result on the main queue. `label` names it for the test hook.
    public func submit<T>(_ lane: String, label: String = "", work: @escaping @Sendable () throws -> T,
                          done: (@MainActor @Sendable (Result<T, Error>) -> Void)? = nil) {
        enqueue(lane, label: label, work: { try work() }) { [weak self] result in
            guard let done else { return }
            let typed = result.map { $0 as! T }
            self?.report { done(typed) }
        }
    }

    /// Runs `work` as `submit` does and returns its result, without blocking the caller.
    public func perform<T: Sendable>(_ lane: String, label: String = "", _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            enqueue(lane, label: label, work: { try work() }) { result in
                continuation.resume(with: result.map { $0 as! T })
            }
        }
    }

    /// Runs `work` on `lane` after what was asked for there before it, and waits for it: for a read
    /// that may repair its file, in order with that file's writes. It blocks the caller only while
    /// the lane is busy.
    public func sync<T>(_ lane: String, label: String = "", _ work: () throws -> T) rethrows -> T {
        condition.lock()
        let state = self.lane(lane)
        state.pending += 1
        condition.unlock()
        defer {
            condition.lock()
            state.pending -= 1
            condition.broadcast()
            condition.unlock()
        }
        return try state.queue.sync {
            before?(Work(lane: lane, label: label))
            return try work()
        }
    }

    /// Waits, without blocking the caller, until everything asked for on `lane` so far has run.
    public func barrier(_ lane: String) async {
        _ = try? await perform(lane, label: "barrier") { () }
    }

    /// Keeps `value` as the latest state of `slot` on `lane`, and writes it with `write` (which
    /// returns the bytes it wrote) after what was asked for before it on the lane, or `delay`
    /// seconds from now when none is scheduled yet. A state given before it and not written yet
    /// is dropped, and its `done` hears how this one went; one with the same `version` as the state
    /// written last isn't written again. Every `done` of a slot must take the same type of value.
    public func replace<Value: Sendable>(_ lane: String, slot: String, value: Value, version: AnyHashable? = nil,
                                         delay: TimeInterval = 0, write: @escaping @Sendable (Value) throws -> Int,
                                         done: (@MainActor @Sendable (Result<Value, Error>) -> Void)? = nil) {
        let waiter: @Sendable (Result<Any, Error>) -> Void = { [weak self] result in
            guard let done else { return }
            let typed = result.map { $0 as! Value }
            self?.report { done(typed) }
        }
        condition.lock()
        if isRetired(lane) {
            statistics.dropped += 1
            condition.unlock()
            waiter(.failure(Failure.retired))
            return
        }
        let key = SlotKey(lane: lane, slot: slot)
        let laneState = self.lane(lane)
        var state = laneState.slots[slot] ?? Slot()
        if state.value != nil { statistics.coalesced += 1 } else { retain(1) }
        state.value = value
        state.write = { try write($0 as! Value) }
        state.version = version
        state.waiters.append(waiter)
        var schedule = !state.scheduled
        state.scheduled = true
        laneState.slots[slot] = state
        if schedule, delay > 0 { delayed.insert(key) }
        // A state that can't wait takes the place of one waiting for its delay, and goes now.
        if !schedule, delay == 0, delayed.remove(key) != nil { schedule = true }
        condition.unlock()
        guard schedule else { return }
        if delay > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.release(key)
            }
        } else {
            scheduleDrain(key)
        }
    }

    /// Drops the state of `slot` on `lane` that isn't written yet, for a save of its own that
    /// replaces it; its `done` gets `Failure.superseded`. A write of it already running finishes.
    public func cancel(_ lane: String, slot: String) {
        condition.lock()
        guard let laneState = lanes[lane], var state = laneState.slots[slot], state.value != nil else {
            condition.unlock()
            return
        }
        let waiters = state.waiters
        state.value = nil
        state.write = nil
        state.waiters = []
        laneState.slots[slot] = state
        retain(-1)
        // A run already in the lane finds nothing; one waiting for its delay goes now, to find nothing.
        let wasDelayed = delayed.remove(SlotKey(lane: lane, slot: slot)) != nil
        condition.unlock()
        if wasDelayed { scheduleDrain(SlotKey(lane: lane, slot: slot)) }
        for waiter in waiters { waiter(.failure(Failure.superseded)) }
    }

    // MARK: Waiting

    /// Whether nothing is waiting or running under `prefix` (a folder's path), or anywhere for nil.
    public func isIdle(under prefix: String? = nil) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return busyLanes(under: prefix).isEmpty
    }

    /// Writes every replaced state still waiting for its delay now, then blocks until the work under
    /// `prefix` (everywhere, for nil) has run, up to `timeout` seconds. Returns the lanes whose work
    /// hadn't finished by then: empty when everything did. For quitting and for moving a bot's
    /// folder; results aren't reported to the main queue while it waits here.
    @discardableResult
    public func wait(under prefix: String? = nil, timeout: TimeInterval) -> [String] {
        condition.lock()
        let waiting = delayed.filter { Self.contains(prefix, $0.lane) }
        condition.unlock()
        for key in waiting { release(key) }
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !busyLanes(under: prefix).isEmpty {
            if !condition.wait(until: deadline) { break }
        }
        return busyLanes(under: prefix).sorted()
    }

    /// Waits, without blocking the main thread, until everything asked for has run and every
    /// result has reached its `done`, including work that `done` asked for in turn (tests).
    public func settle() async {
        while !isSettled {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private var isSettled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return busyLanes(under: nil).isEmpty && reporting == 0 && delayed.isEmpty
    }

    /// The folder at `prefix` is going away (its bot deleted): work waiting under it is dropped
    /// (its `done` gets `Failure.retired`), new work under it is refused, and this blocks until the
    /// work running there has finished, up to `timeout`. `reopen` takes new work there again.
    @discardableResult
    public func retire(_ prefix: String, timeout: TimeInterval) -> [String] {
        condition.lock()
        retired.append(prefix)
        var dropped: [@Sendable (Result<Any, Error>) -> Void] = []
        for (name, lane) in lanes where Self.contains(prefix, name) {
            for (slot, var state) in lane.slots where state.value != nil || state.scheduled {
                if state.value != nil {
                    statistics.dropped += 1
                    retain(-1)
                }
                dropped += state.waiters
                state.value = nil
                state.write = nil
                state.waiters = []
                // A run already in the lane is dropped there; one waiting for its delay never joins it.
                state.scheduled = false
                lane.slots[slot] = state
                delayed.remove(SlotKey(lane: name, slot: slot))
            }
        }
        condition.unlock()
        for waiter in dropped { waiter(.failure(Failure.retired)) }
        return wait(under: prefix, timeout: timeout)
    }

    public func reopen(_ prefix: String) {
        condition.lock()
        retired.removeAll { $0 == prefix }
        condition.unlock()
    }

    public var stats: Statistics {
        condition.lock()
        defer { condition.unlock() }
        return statistics
    }

    // MARK: Running

    private func lane(_ name: String) -> Lane {
        if let existing = lanes[name] { return existing }
        let made = Lane(queue: DispatchQueue(label: "BotChu.Storage", qos: qos))
        lanes[name] = made
        return made
    }

    private func enqueue(_ lane: String, label: String, work: @escaping @Sendable () throws -> Any,
                         finish: @escaping @Sendable (Result<Any, Error>) -> Void) {
        condition.lock()
        if isRetired(lane) {
            statistics.dropped += 1
            condition.unlock()
            finish(.failure(Failure.retired))
            return
        }
        let state = self.lane(lane)
        state.pending += 1
        condition.unlock()
        state.queue.async { [self] in
            let result: Result<Any, Error>
            condition.lock()
            let drop = isRetired(lane)
            if drop { statistics.dropped += 1 } else { statistics.runs += 1 }
            condition.unlock()
            if drop {
                result = .failure(Failure.retired)
            } else {
                before?(Work(lane: lane, label: label))
                result = Result { try work() }
            }
            finish(result)
            condition.lock()
            state.pending -= 1
            condition.broadcast()
            condition.unlock()
        }
    }

    /// A replaced state's delay has passed (or quitting can't wait for it): its run joins the lane.
    private func release(_ key: SlotKey) {
        condition.lock()
        let wasDelayed = delayed.remove(key) != nil
        condition.unlock()
        if wasDelayed { scheduleDrain(key) }
    }

    /// Queues the run that writes the slot's latest state, whatever it is by then.
    private func scheduleDrain(_ key: SlotKey) {
        enqueue(key.lane, label: key.slot, work: { [self] in
            condition.lock()
            guard let laneState = lanes[key.lane], var state = laneState.slots[key.slot],
                  let value = state.value, let write = state.write else {
                lanes[key.lane]?.slots[key.slot]?.scheduled = false
                condition.unlock()
                return ()
            }
            let version = state.version, waiters = state.waiters
            let unchanged = version != nil && version == state.written
            state.value = nil
            state.write = nil
            state.waiters = []
            state.scheduled = false
            laneState.slots[key.slot] = state
            statistics.peakRetained = max(statistics.peakRetained, retained)
            if unchanged { statistics.unchanged += 1 }
            condition.unlock()
            // The same state as the one written last is what's on disk already.
            let result: Result<Any, Error> = unchanged ? .success(value) : Result { try write(value) }.map { bytes in
                self.condition.lock()
                self.statistics.bytesWritten += bytes
                self.condition.unlock()
                return value
            }
            condition.lock()
            if case .success = result, let laneState = lanes[key.lane] { laneState.slots[key.slot]?.written = version }
            retain(-1)
            condition.unlock()
            for waiter in waiters { waiter(result) }
            return ()
        }, finish: { _ in })
    }

    private func report(_ deliver: @escaping @MainActor @Sendable () -> Void) {
        condition.lock()
        reporting += 1
        condition.unlock()
        DispatchQueue.main.async { [self] in
            let start = DispatchTime.now().uptimeNanoseconds
            MainActor.assumeIsolated { deliver() }
            let took = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            condition.lock()
            reporting -= 1
            statistics.longestReport = max(statistics.longestReport, took)
            condition.unlock()
        }
    }

    /// Caller holds the lock.
    private func retain(_ change: Int) {
        retained += change
    }

    /// Caller holds the lock.
    private func busyLanes(under prefix: String?) -> [String] {
        lanes.compactMap { name, lane in
            Self.contains(prefix, name) && (lane.pending > 0 || lane.slots.values.contains { $0.scheduled }) ? name : nil
        }
    }

    /// Caller holds the lock.
    private func isRetired(_ lane: String) -> Bool {
        retired.contains { Self.contains($0, lane) }
    }

    private static func contains(_ prefix: String?, _ lane: String) -> Bool {
        guard let prefix else { return true }
        return lane == prefix || lane.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }
}
