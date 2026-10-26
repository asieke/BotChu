import Foundation
import Observation
import BotChuCore

/// The owner's Inbox: what the bots deliver with `botchu-inbox send` (`Delivery`), kept in each
/// sender's `.botchu/inbox/`, and what the owner did with each (`InboxState`, in `inbox.json` beside
/// `index.json`).
///
/// One unread state: reading a delivery clears its conversation's news dot, and showing the
/// conversation reads its deliveries. A reply goes into the conversation that sent the delivery,
/// through its queue, marked with the delivery (`InboxReply`).
@MainActor @Observable
final class InboxModel {
    /// Every delivery, by ID.
    private(set) var deliveries: [UUID: Delivery] = [:]
    private(set) var state = InboxState()
    /// Whether the deliveries have been read from the bots' folders.
    private(set) var isLoaded = false
    /// The delivery chosen in the Inbox's list, kept while other pages show.
    var selected: UUID?
    /// What is typed in each delivery's reply box and not sent yet.
    var drafts: [UUID: String] = [:]
    /// Deliveries opened while they were news, so the reading pane shows the exchange's end.
    @ObservationIgnored var openedAsNews: Set<UUID> = []
    /// Whether the Inbox's page is showing, so the selected delivery is being read.
    @ObservationIgnored var isShowing = false
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let storage: StorageQueue
    /// Deliveries a conversation sent in the turn under way, to show as cards in its chat when the
    /// turn ends (after the reply that announces them).
    @ObservationIgnored private var cards: [ChatTarget: [UUID]] = [:]
    /// Each conversation's deliveries in its turn under way, by title: the same title sent again in
    /// the turn updates the delivery.
    @ObservationIgnored private var titles: [ChatTarget: [String: UUID]] = [:]

    init(model: AppModel, root: URL, storage: StorageQueue) {
        self.model = model
        self.root = root
        self.storage = storage
        state = InboxState.load(from: root)
    }

    var stateLane: String { InboxState.url(in: root).path }

    /// Newest first.
    var all: [Delivery] { deliveries.values.sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) } }
    var unreadCount: Int { state.unreadCount(Array(deliveries.values)) }
    var unfinishedCount: Int { state.unfinishedCount(Array(deliveries.values)) }
    func delivery(_ id: UUID) -> Delivery? { deliveries[id] }
    func target(of delivery: Delivery) -> ChatTarget { ChatTarget(botID: delivery.botID, taskID: delivery.taskID) }
    func isUnread(_ id: UUID) -> Bool { deliveries[id].map(state.isUnread) ?? false }
    func isDone(_ id: UUID) -> Bool { state[id].done }

    /// Reads every bot's deliveries off the main thread.
    func load(bots: [Bot]) {
        let folders = bots.map { (id: $0.id, folder: InboxFolder(home: BotHome(workspace: $0.persistencePath))) }
        Task.detached(priority: .utility) { [weak self] in
            var read: [UUID: Delivery] = [:]
            for (id, folder) in folders {
                for delivery in folder.load() where delivery.botID == id { read[delivery.id] = delivery }
            }
            await self?.loaded(read)
        }
    }

    private func loaded(_ found: [UUID: Delivery]) {
        // What arrived meanwhile is newer than what was read.
        deliveries = found.merging(deliveries) { _, new in new }
        isLoaded = true
        model?.notifier?.inboxLoaded()
    }

    // MARK: Arriving

    /// A sending conversation's turn starts: what it sends is new, whatever its titles.
    func turnStarts(_ target: ChatTarget) {
        titles[target] = nil
    }

    /// Takes a delivery from `botchu-inbox send` in `target`'s turn (a sub-agent's, crediting its
    /// bot): copies its staged files out of the mailbox, saves it in the sender's folder, then shows it.
    func receive(_ request: InboxRequest, in target: ChatTarget, credits: [Delivery.Credit], subagent: Delivery.Credit?,
                 transport: SubagentTransport) async throws -> (delivery: Delivery, updated: Bool) {
        guard let model, let bot = model.bot(target.botID) else { throw InboxRequest.Problem("its bot is gone") }
        var contents: [String: Data] = [:]
        var files: [Delivery.File] = []
        for file in request.files {
            contents[file.name] = try await transport.readStaged(file.staged, request: request.id, limit: InboxRequest.maxFileBytes)
            files.append(Delivery.File(name: file.name, kind: Delivery.File.kind(of: file.name), bytes: contents[file.name]!.count,
                                       source: file.source, credit: subagent))
        }
        let existing = titles[target]?[request.title].flatMap { deliveries[$0] }
        let now = Delivery.stamp()
        let delivery = Delivery(id: existing?.id ?? UUID(), botID: target.botID, taskID: target.taskID, title: request.title,
                                note: request.note, files: files, links: request.links, question: request.question,
                                credits: credits, sentAt: existing?.sentAt ?? now, updatedAt: now)
        let folder = InboxFolder(home: BotHome(workspace: bot.persistencePath))
        let saved = delivery, data = contents
        try await storage.perform(folder.url.path, label: "delivery") { try folder.save(saved, contents: data) }
        try? await transport.removeStaged(request: request.id)
        titles[target, default: [:]][request.title] = delivery.id
        show(delivery, isNew: existing == nil)
        return (delivery, existing != nil)
    }

    /// Puts a delivery BotChu makes for a conversation in the Inbox (a job run's report, #170): saved
    /// in its bot's folder, then shown as one from `botchu-inbox send` is. The same delivery again
    /// replaces it.
    func post(_ delivery: Delivery) async throws {
        guard let bot = model?.bot(delivery.botID) else { throw InboxRequest.Problem("its bot is gone") }
        let folder = InboxFolder(home: BotHome(workspace: bot.persistencePath))
        try await storage.perform(folder.url.path, label: "delivery") { try folder.save(delivery, contents: [:]) }
        show(delivery, isNew: deliveries[delivery.id] == nil)
    }

    /// A delivery saved: it is news, unless it arrives in the conversation the owner is looking at,
    /// and a new one is announced, its card in the conversation (after the turn under way's reply).
    private func show(_ delivery: Delivery, isNew: Bool) {
        guard let model else { return }
        let target = target(of: delivery)
        deliveries[delivery.id] = delivery
        var entry = state[delivery.id]
        entry.done = false
        // Arriving in the conversation the owner is looking at, it is read there.
        entry.read = model.isShown(target)
        state[delivery.id] = entry
        saveState()
        if isNew {
            model.notifier?.arrived(delivery)
            if model.isRunning(target) {
                cards[target, default: []].append(delivery.id)
            } else {
                model.append(delivery.card, to: target)
                model.saveThread(target)
            }
        }
    }

    /// The cards of what the conversation delivered in the turn that is ending.
    func takeCards(for target: ChatTarget) -> [ChatMessage] {
        (cards.removeValue(forKey: target) ?? []).compactMap { deliveries[$0]?.card }
    }

    /// A conversation's turn ended: a delivery it answers from the Inbox is news again, unless the
    /// owner is reading it, and comes back out of Done.
    func turnEnded(_ target: ChatTarget, turn: [ChatMessage]) {
        titles[target] = nil
        let answered = InboxReply.answered(in: turn).filter { deliveries[$0] != nil }
        guard !answered.isEmpty else { return }
        for id in answered {
            var entry = state[id]
            entry.done = false
            if !isReading(id) { entry.read = false }
            state[id] = entry
        }
        saveState()
    }

    // MARK: The owner

    /// Whether the delivery is in the Inbox's reading pane now.
    func isReading(_ id: UUID) -> Bool { isShowing && selected == id }

    /// Reading a delivery clears its conversation's news dot too.
    func markRead(_ id: UUID, _ read: Bool = true) {
        guard let delivery = deliveries[id], state[id].read != read else { return }
        state[id].read = read
        if read { model?.unread.remove(target(of: delivery)) }
        saveState()
    }

    func setDone(_ id: UUID, _ done: Bool) {
        guard deliveries[id] != nil, state[id].done != done else { return }
        state[id].done = done
        if done { state[id].read = true }
        saveState()
    }

    /// The conversation is shown: what it delivered is read.
    func conversationShown(_ target: ChatTarget) {
        let ids = deliveries.values.filter { $0.botID == target.botID && $0.taskID == target.taskID && !state[$0.id].read }.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { state[id].read = true }
        saveState()
    }

    /// Sends a reply into the conversation that sent the delivery, through its queue.
    @discardableResult
    func reply(_ text: String, to id: UUID, accepted: (@MainActor @Sendable (Bool) -> Void)? = nil) -> Bool {
        guard let model, let delivery = deliveries[id] else { return false }
        let target = target(of: delivery)
        // A closed task opens again for the reply, as a job's run becomes the owner's.
        if let task = model.task(target), task.isArchived { model.reopenTask(target) }
        guard model.send(text, to: target, delivery: id, accepted: accepted) else { return false }
        state[id].repliedAt = Delivery.stamp()
        state[id].read = true
        saveState()
        return true
    }

    /// The bot and everything it kept went (`AppModel.delete`).
    func forget(bot id: UUID) {
        let gone = deliveries.values.filter { $0.botID == id }.map(\.id)
        for delivery in gone { deliveries[delivery] = nil; state[delivery] = InboxState.Entry() }
        cards = cards.filter { $0.key.botID != id }
        titles = titles.filter { $0.key.botID != id }
        if let selected, gone.contains(selected) { self.selected = nil }
        if !gone.isEmpty { saveState() }
    }

    private func saveState() {
        let root = root
        storage.replace(stateLane, slot: "inbox", value: state, write: { state in
            try state.save(to: root)
            return 0
        })
    }
}
