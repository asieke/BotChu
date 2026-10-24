import Foundation
import BotChuCore

/// `@` agent and `#` project mentions (#84): what the message box completes them from, and what a
/// message with them tells its bot. Everything is read locally: the configured bots and the saved
/// Projects catalog, never GitHub while the owner types.
extension AppModel {
    /// What a conversation's message box completes `@` and `#` from.
    func mentionSources(for target: ChatTarget) -> MentionSources {
        MentionSources(
            agents: { [weak self] in self?.mentionAgents(for: target) ?? [] },
            projects: { [weak self] in self?.projectCatalog ?? [] },
            catalog: { [weak self] in self?.mentionCatalog ?? MentionCatalogState() },
            favoredRepo: task(target)?.repo,
            status: { [weak self] in self?.referenceStatus($0) ?? .resolved },
            loadProjects: { [weak self] in Task { await self?.refreshProjects() } },
            openAgents: { [weak self] in self?.selectSidebar(.library(.agents)) })
    }

    /// The agents `@` offers in a conversation: every configured bot but its own, in the sidebar's order.
    func mentionAgents(for target: ChatTarget) -> [BotRosterEntry] {
        bots.filter { $0.id != target.botID }.map(BotRosterEntry.init)
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

    /// The text a message reaches its bot with: what its mentions point at (`ReferenceContext`), then
    /// the message. A message without mentions goes as it is.
    func deliveredText(of message: ChatMessage, for target: ChatTarget) -> String {
        guard !message.mentions.isEmpty,
              let section = ReferenceContext.section(for: message.mentions, recipient: target.botID, agents: bots.map(BotRosterEntry.init),
                                                     projects: repositories == nil ? nil : projectCatalog, login: projectsLogin)
        else { return message.text }
        return BotContext.prompt(for: message.text, preamble: nil, updates: section)
    }
}
