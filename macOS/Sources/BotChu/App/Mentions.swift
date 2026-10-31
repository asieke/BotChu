import Foundation
import BotChuCore

/// `@` agent and `#` project mentions (#84): what the message box completes them from, and what a
/// message with them tells its bot. Everything is read locally: the configured bots and the saved
/// Projects catalog, never GitHub while the owner types.
extension AppModel {
    /// What a conversation's message box completes `@` and `#` from. In an area, `@` offers its own
    /// bot too: a message there is answered by the bots it chooses (#406).
    func mentionSources(for target: ChatTarget) -> MentionSources {
        mentionSources(for: task(target)?.isArea == true ? nil : target.botID, favoring: task(target)?.repo)
    }

    /// What a sheet's text completes `@` and `#` from, for a conversation it starts (#268): every bot
    /// but `botID`, and the projects with `repo`, the one chosen, first.
    func mentionSources(for botID: UUID?, favoring repo: String?) -> MentionSources {
        MentionSources(
            agents: { [weak self] in
                guard let self else { return [] }
                return bots.filter { $0.id != botID }.map { BotRosterEntry(bot: $0, runsOn: $0.isRemoteQueue ? nil : self.runsOn($0)) }
            },
            projects: { [weak self] in self?.projectCatalog ?? [] },
            catalog: { [weak self] in self?.mentionCatalog ?? MentionCatalogState() },
            favoredRepo: repo,
            status: { [weak self] in self?.referenceStatus($0) ?? .resolved },
            loadProjects: { [weak self] in Task { await self?.refreshProjects() } },
            openAgents: { [weak self] in self?.selectSidebar(.library(.agents)) })
    }

    /// The agents `@` offers in a conversation: every configured bot but its own, in the sidebar's order.
    func mentionAgents(for target: ChatTarget) -> [BotRosterEntry] {
        mentionSources(for: target).agents()
    }

    /// The saved Projects catalog as `#` completion describes it.
    var mentionCatalog: MentionCatalogState {
        MentionCatalogState(login: projectsLogin, loaded: repositories != nil, syncing: projectsLoading,
                            syncedAt: repositoriesReadAt, error: repositoriesError)
    }

    /// Whether a mention still points at what was chosen: an agent by its ID, a project in the current
    /// account's catalog.
    func referenceStatus(_ reference: MessageReference) -> ReferenceStatus {
        ReferenceStatus.of(reference, agentIDs: bots.map(\.id), repos: repositories?.map(\.nameWithOwner), login: projectsLogin)
    }

    /// What `references` point at, for `recipient` (`ReferenceContext`); nil without any. `inArea`:
    /// the message is in a Project Area, where an agent mentioned takes its own turn.
    func referenceContext(_ references: [MessageReference], for recipient: UUID?, inArea: Bool = false) -> String? {
        ReferenceContext.section(for: references, recipient: recipient, agents: bots.map(BotRosterEntry.init),
                                 projects: repositories == nil ? nil : projectCatalog, login: projectsLogin, inArea: inArea)
    }

    /// The text a message reaches its bot with: what its mentions point at (`ReferenceContext`), then
    /// the message. A message without mentions goes as it is. `recipient` is the bot answering it in
    /// an area when that isn't the area's own (a cameo turn); nil for the conversation's bot.
    func deliveredText(of message: ChatMessage, for target: ChatTarget, recipient: UUID? = nil) -> String {
        // Another bot's request posted into an area (`AreaPost`) says who asks, and from where.
        if let link = message.fromAgent, link.messageID == nil, target.taskID != nil {
            return AreaPost.prompt(message.text, from: link, place: conversationName(of: link))
        }
        // A remote bot's answer to the bot's message says whose it is, and where its files are.
        if let link = message.fromAgent, let bot = bot(target.botID) {
            let home = BotHome(workspace: bot.persistencePath)
            return AgentMessage.prompt(message.text, from: link, files: message.documents.map(home.fileURL))
        }
        // A reply from the Inbox says which delivery it answers.
        if let id = message.delivery, let delivery = inbox?.delivery(id) {
            var plain = message
            plain.delivery = nil
            return InboxReply.prompt(deliveredText(of: plain, for: target, recipient: recipient), delivery: delivery)
        }
        let inArea = target.taskID != nil && task(target)?.isArea == true
        guard let section = referenceContext(message.mentions, for: recipient ?? target.botID, inArea: inArea) else { return message.text }
        return BotContext.prompt(for: message.text, preamble: nil, updates: section)
    }
}
