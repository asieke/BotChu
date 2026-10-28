import Foundation

/// Directory events are hints to drain the mailbox, never acknowledgments. The bounded stream
/// keeps a hint arriving during a drain, and a recovery tick covers lost events and failed reads.
public final class LocalMailboxWatcher: @unchecked Sendable {
    public static let recoveryInterval: TimeInterval = 4.5
    public let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "botchu.mailbox.watch", qos: .utility)
    private let directory: URL
    private let observeChanges: Bool
    private var requestWatch: Watch?
    private var parentWatch: Watch?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var notifications = 0

    private struct Watch {
        let source: DispatchSourceFileSystemObject
        let device: dev_t
        let inode: ino_t
    }

    public convenience init(directory: URL) {
        self.init(directory: directory, recoveryInterval: Self.recoveryInterval, observeChanges: true)
    }

    /// The same recovery path can be clocked explicitly in tests, including with lost events.
    init(directory: URL, recoveryInterval: TimeInterval?, observeChanges: Bool = true) {
        self.directory = directory
        self.observeChanges = observeChanges
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes = stream.stream
        continuation = stream.continuation
        queue.sync {
            // Arm both watches BEFORE asking for the initial scan. A publish during that scan
            // leaves another hint; an already-published request is found by the initial scan.
            refreshWatches()
            if let recoveryInterval {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + recoveryInterval, repeating: recoveryInterval,
                               leeway: .milliseconds(50))
                timer.setEventHandler { [weak self] in self?.recoverOnQueue() }
                self.timer = timer
                timer.resume()
            }
            continuation.yield(())
        }
        continuation.onTermination = { [weak self] _ in self?.cancel() }
    }

    public func cancel() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            requestWatch?.source.cancel()
            parentWatch?.source.cancel()
            requestWatch = nil
            parentWatch = nil
            timer?.cancel()
            timer = nil
            continuation.finish()
        }
    }

    deinit {
        requestWatch?.source.cancel()
        parentWatch?.source.cancel()
        timer?.cancel()
        continuation.finish()
    }

    func recover() { queue.async { [weak self] in self?.recoverOnQueue() } }

    /// Test evidence that completion/cancellation releases both directory registrations.
    var watchedDirectoryCount: Int {
        queue.sync { (requestWatch == nil ? 0 : 1) + (parentWatch == nil ? 0 : 1) }
    }

    var notificationCount: Int { queue.sync { notifications } }

    private func recoverOnQueue() {
        guard !stopped else { return }
        refreshWatches()
        continuation.yield(())
    }

    private func refreshWatches() {
        guard observeChanges else { return }
        parentWatch = refreshed(parentWatch, at: directory.deletingLastPathComponent(), parent: true)
        requestWatch = refreshed(requestWatch, at: directory, parent: false)
    }

    private func refreshed(_ previous: Watch?, at url: URL, parent: Bool) -> Watch? {
        var info = stat()
        let exists = lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        if let previous, exists, previous.device == info.st_dev, previous.inode == info.st_ino {
            return previous
        }
        previous?.source.cancel()
        guard exists else { return nil }
        let descriptor = open(url.path, O_EVTONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            close(descriptor)
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke], queue: queue)
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.notifications += 1
            let oldDevice = self.requestWatch?.device, oldInode = self.requestWatch?.inode
            self.refreshWatches()
            // Heartbeat/result writes also change the parent. Only replacing requests should
            // cause a scan; otherwise these writes would recreate the old idle polling load.
            if !parent || oldDevice != self.requestWatch?.device || oldInode != self.requestWatch?.inode {
                self.continuation.yield(())
            }
        }
        source.resume()
        return Watch(source: source, device: info.st_dev, inode: info.st_ino)
    }
}
