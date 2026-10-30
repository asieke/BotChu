import Foundation
import BotChuCore

/// Drafts kept between launches (#357): what is typed in a conversation's message box, with its
/// `@` and `#` references, is saved as it changes and put back in that conversation's box at
/// launch (`DraftStore`, in BotChu's own folder, not the bot's). Attachments stay in memory.
extension AppModel {
    var savedDrafts: DraftStore { DraftStore(root: store.root) }

    /// Saves the conversation's draft off the main thread, a moment after it last changed, or
    /// removes it at once when it was sent or cleared.
    func saveDraft(_ target: ChatTarget) {
        // A deleted bot's drafts are gone and stay gone.
        guard bot(target.botID) != nil, let state = conversations[target] else { return }
        let draft = state.draft.map { ComposerDraft(text: $0, references: state.draftReferences ?? []) }
        savedDrafts.save(draft, for: DraftStore.Key(bot: target.botID, task: target.taskID), storage: storage)
    }

    /// At launch, puts each draft back in its conversation's box, without saving it again, and
    /// removes those of bots and tasks that are gone: a task whose record couldn't be read keeps
    /// its draft while its folder is there.
    func restoreDrafts() {
        let tasks = Dictionary(bots.map { ($0.id, Set(self.tasks[$0.id, default: []].map(\.id))) }, uniquingKeysWith: { first, _ in first })
        let homes = Dictionary(bots.map { ($0.id, BotHome(workspace: $0.persistencePath)) }, uniquingKeysWith: { first, _ in first })
        let restored = savedDrafts.restore(tasks: tasks, missing: Set(missing.map(\.id))) { key in
            guard let task = key.task, let home = homes[key.bot] else { return true }
            return !FileManager.default.fileExists(atPath: home.taskURL(task).path)
        }
        for (key, draft) in restored {
            let conversation = conversation(ChatTarget(botID: key.bot, taskID: key.task))
            conversation.draft = draft.text
            conversation.draftReferences = draft.references
        }
    }
}
