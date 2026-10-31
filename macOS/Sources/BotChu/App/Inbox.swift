import Foundation
import Observation
import BotChuCore

/// The owner's Inbox: what the bots deliver with `botchu-inbox send` (`Delivery`), kept in each
/// sender's `.botchu/inbox/`, and what the owner did with each (`InboxState`, in `inbox.json` beside
/// `index.json`).
///
/// One unread state: reading a delivery clears its conversation's news dot, and showing the
/// conversation reads its deliveries. A reply goes into the conversation that sent the delivery,
/// through its queue, marked with the delivery (`InboxReply`); once the queue holds it, the delivery
/// is Done and what the bot does with it shows in that conversation.
@MainActor @Observable
final class InboxModel {
    /// Every delivery, by ID.
    private(set) var deliveries: [UUID: Delivery] = [:]
    private(set) var state = InboxState()
    /// Only unfinished and recently Done deliveries feed the ordinary list; all remain searchable.
    private(set) var listIndex = InboxList.Index()
    private(set) var unreadCount = 0
    private(set) var unfinishedCount = 0
    @ObservationIgnored private var status = InboxStatus()
    @ObservationIgnored private var conversationStatuses: [ChatTarget: InboxConversationStatus] = [:]
    @ObservationIgnored private var entryStatuses: [UUID: InboxEntryStatus] = [:]
    /// `state` as of the last complete mutation, read without observing it to start an entry's.
    @ObservationIgnored private var settledState = InboxState()
    /// Counts whole-Inbox derivations, for the controlled status benchmark (#271).
    @ObservationIgnored private(set) var statusDerivations = 0
    /// Whether the deliveries have been read from the bots' folders.
    private(set) var isLoaded = false
    /// The delivery chosen in the Inbox's list, kept while other pages show.
    var selected: UUID?
    /// What is typed in each delivery's reply box and not sent yet.
    var drafts: [UUID: String] = [:]
    /// Deliveries whose reply is being saved in their conversation's queue: no other goes meanwhile.
    private(set) var sending: Set<UUID> = []
    /// Each delivery's reply the queue couldn't take, to send again.
    private(set) var failed: [UUID: String] = [:]
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
        settledState = state
    }

    var stateLane: String { InboxState.url(in: root).path }

    /// Newest first.
    var all: [Delivery] { deliveries.values.sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) } }
    func delivery(_ id: UUID) -> Delivery? { deliveries[id] }
    func target(of delivery: Delivery) -> ChatTarget { ChatTarget(botID: delivery.botID, taskID: delivery.taskID) }
    func isUnread(_ id: UUID) -> Bool { deliveries[id] != nil && entry(id).isUnread }
    func isDone(_ id: UUID) -> Bool { entry(id).done }

    /// What the owner did with one delivery, observed apart from every other's: a row, its labels
    /// and the toolbar draw again when their own delivery changes, not when another is read or Done.
    func entry(_ id: UUID) -> InboxState.Entry {
        if let existing = entryStatuses[id] { return existing.entry }
        let made = InboxEntryStatus(entry: settledState[id])
        entryStatuses[id] = made
        return made.entry
    }

    /// The conversation's unresolved Needs input deliveries, newest first: it waits on the owner.
    func awaitingInput(_ target: ChatTarget) -> [UUID] {
        conversationStatus(target).pending.map(\.id)
    }

    /// A tab reads only its own questions, never the full delivery dictionary.
    func awaitingInputDates(_ target: ChatTarget) -> [Date] {
        conversationStatus(target).pending.map(\.updatedAt)
    }

    private func conversationStatus(_ target: ChatTarget) -> InboxConversationStatus {
        if let existing = conversationStatuses[target] { return existing }
        let made = InboxConversationStatus()
        made.pending = status.awaitingInput[Delivery.Origin(botID: target.botID, taskID: target.taskID)] ?? []
        conversationStatuses[target] = made
        return made
    }

    /// Once after a complete mutation, even when it changes several state entries or deliveries.
    /// Publish only changed values, so an unrelated question doesn't invalidate another bot's row.
    private func refreshStatus() {
        status = InboxStatus(deliveries: Array(deliveries.values), state: state)
        statusDerivations += 1
        if unreadCount != status.unreadCount { unreadCount = status.unreadCount }
        if unfinishedCount != status.unfinishedCount { unfinishedCount = status.unfinishedCount }
        for (target, conversation) in conversationStatuses {
            let pending = status.awaitingInput[Delivery.Origin(botID: target.botID, taskID: target.taskID)] ?? []
            if conversation.pending != pending { conversation.pending = pending }
        }
        settledState = state
        for (id, observed) in entryStatuses where observed.entry != state[id] { observed.entry = state[id] }
    }

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
        listIndex = InboxList.Index(deliveries.values, state: state, now: .now)
        refreshStatus()
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
    /// It updates the delivery it names (`--update`), else the one with its title sent in the turn.
    func receive(_ request: InboxRequest, in target: ChatTarget, credits: [Delivery.Credit], subagent: Delivery.Credit?,
                 transport: SubagentTransport) async throws -> (delivery: Delivery, updated: Bool) {
        guard let model, let bot = model.bot(target.botID) else { throw InboxRequest.Problem("its bot is gone") }
        var existing = titles[target]?[request.title].flatMap { deliveries[$0] }
        if let id = request.updates {
            guard let named = deliveries[id], self.target(of: named) == target else {
                throw InboxRequest.Problem("this conversation sent no delivery \(id.uuidString.lowercased()) to update")
            }
            existing = named
        }
        var contents: [String: Data] = [:]
        var files: [Delivery.File] = []
        for file in request.files {
            contents[file.name] = try await transport.readStaged(file.staged, request: request.id, limit: InboxRequest.maxFileBytes)
            files.append(Delivery.File(name: file.name, kind: Delivery.File.kind(of: file.name), bytes: contents[file.name]!.count,
                                       source: file.source, credit: subagent))
        }
        let (delivery, renewed) = Delivery.resent(
            Delivery(id: existing?.id ?? UUID(), botID: target.botID, taskID: target.taskID, title: request.title, note: request.note,
                     files: files, links: request.links, question: request.question, purpose: request.purpose, credits: credits),
            replacing: existing)
        let folder = InboxFolder(home: BotHome(workspace: bot.persistencePath))
        let saved = delivery, data = contents
        try await storage.perform(folder.url.path, label: "delivery") { try folder.save(saved, contents: data) }
        try? await transport.removeStaged(request: request.id)
        titles[target, default: [:]][request.title] = delivery.id
        show(delivery, isNew: existing == nil, renewed: renewed)
        return (delivery, existing != nil)
    }

    /// Puts a delivery BotChu makes for a conversation in the Inbox (a job run's report, #170): saved
    /// in its bot's folder, then shown as one from `botchu-inbox send` is. The same delivery again
    /// replaces it.
    func post(_ delivery: Delivery) async throws {
        guard let bot = model?.bot(delivery.botID) else { throw InboxRequest.Problem("its bot is gone") }
        let folder = InboxFolder(home: BotHome(workspace: bot.persistencePath))
        let (saved, renewed) = Delivery.resent(delivery, replacing: deliveries[delivery.id])
        try await storage.perform(folder.url.path, label: "delivery") { try folder.save(saved, contents: [:]) }
        show(saved, isNew: deliveries[delivery.id] == nil, renewed: renewed)
    }

    /// A delivery saved: it is news, unless it arrives in the conversation the owner is looking at,
    /// and a new one is announced, its card in the conversation (after the turn under way's reply).
    /// Sent again saying nothing new, it keeps what the owner did with it.
    private func show(_ delivery: Delivery, isNew: Bool, renewed: Bool) {
        guard let model else { return }
        let target = target(of: delivery)
        deliveries[delivery.id] = delivery
        // Arriving in the conversation the owner is looking at, it is read there.
        state.received(delivery.id, renewed: renewed, shown: model.isShown(target))
        listIndex.update(delivery, state: state, now: .now)
        refreshStatus()
        if renewed { saveState() }
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

    /// A conversation's turn ended. Its answer to a reply from the Inbox stays in the conversation:
    /// only a new delivery asks for the owner again.
    func turnEnded(_ target: ChatTarget) {
        titles[target] = nil
    }

    // MARK: The owner

    /// Whether the delivery is in the Inbox's reading pane now.
    func isReading(_ id: UUID) -> Bool { isShowing && selected == id }

    /// Reading a delivery clears its conversation's news dot too.
    func markRead(_ id: UUID, _ read: Bool = true) {
        guard let delivery = deliveries[id], state[id].read != read else { return }
        state[id].read = read
        refreshStatus()
        if read { model?.unread.remove(target(of: delivery)) }
        saveState()
    }

    func setDone(_ id: UUID, _ done: Bool) {
        guard let delivery = deliveries[id], state[id].done != done else { return }
        state.setDone(id, done, at: .now)
        listIndex.update(delivery, state: state, now: .now)
        refreshStatus()
        saveState()
    }

    /// The open Inbox reaches its next cutoff, or becomes visible after time away.
    func expireDone(at date: Date) {
        listIndex.expire(state: state, now: date)
    }

    /// The conversation is shown: what it delivered is read.
    func conversationShown(_ target: ChatTarget) {
        let ids = deliveries.values.filter { $0.botID == target.botID && $0.taskID == target.taskID && !state[$0.id].read }.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { state[id].read = true }
        refreshStatus()
        saveState()
    }

    /// Sends a reply, word for word, into the conversation that sent the delivery, through its
    /// queue; one at a time. Once the queue holds it the delivery is Done, and read in the Inbox, its
    /// conversation opens. Should the queue not take it, the delivery keeps its draft and choices,
    /// and `failed` holds the reply to send again.
    @discardableResult
    func reply(_ text: String, to id: UUID) -> Bool {
        guard let model, let delivery = deliveries[id], !sending.contains(id),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let target = target(of: delivery)
        // A closed task opens again for the reply, as a job's run becomes the owner's.
        if let task = model.task(target), task.isArchived { model.reopenTask(target) }
        sending.insert(id)
        failed[id] = nil
        let started = model.send(text, to: target, delivery: id) { [weak self] accepted in
            self?.settle(id, text: text, accepted: accepted)
        }
        if !started, sending.remove(id) != nil { failed[id] = text }
        return started
    }

    private func settle(_ id: UUID, text: String, accepted: Bool) {
        guard sending.remove(id) != nil, let delivery = deliveries[id] else { return }
        guard accepted else {
            failed[id] = text
            return
        }
        let reading = isReading(id)
        state.answer(id, at: Delivery.stamp())
        listIndex.update(delivery, state: state, now: .now)
        refreshStatus()
        saveState()
        if drafts[id] == text { drafts[id] = nil }
        model?.unread.remove(target(of: delivery))
        if reading { model?.openOrigin(of: delivery) }
    }

    /// The bot and everything it kept went (`AppModel.delete`).
    func forget(bot id: UUID) {
        let gone = deliveries.values.filter { $0.botID == id }.map(\.id)
        for delivery in gone {
            deliveries[delivery] = nil
            state[delivery] = InboxState.Entry()
            sending.remove(delivery)
            failed[delivery] = nil
        }
        cards = cards.filter { $0.key.botID != id }
        titles = titles.filter { $0.key.botID != id }
        if let selected, gone.contains(selected) { self.selected = nil }
        if !gone.isEmpty {
            listIndex = InboxList.Index(deliveries.values, state: state, now: .now)
            refreshStatus()
            saveState()
        }
    }

    private func saveState() {
        let root = root
        storage.replace(stateLane, slot: "inbox", value: state, write: { state in
            try state.save(to: root)
            return 0
        })
    }
}

/// Stable observation boundary for one conversation's unresolved deliveries. Kept even while
/// empty, so a view already observing it sees the next question arrive.
@MainActor @Observable
private final class InboxConversationStatus {
    var pending: [InboxStatus.Pending] = []
}

/// Stable observation boundary for one delivery's entry (`InboxModel.entry`). Kept even while the
/// entry is the default, so a view already observing it sees the next change.
@MainActor @Observable
private final class InboxEntryStatus {
    var entry: InboxState.Entry
    init(entry: InboxState.Entry) { self.entry = entry }
}
