import AppKit
import BotChuCore

/// A skill and the bot it belongs to: nil for a shared one, in the bots folder.
struct SkillEntry: Identifiable, Hashable {
    let skill: Skill
    let bot: Bot?
    var id: String { skill.id }
}

/// Skills (`Skills` in BotChuCore): the shared ones in the bots folder's `skills/`, and each bot's own
/// in its workspace's.
extension AppModel {
    var sharedSkillsFolder: URL { Skills.sharedFolder(besideSharedMemory: settings.sharedMemoryPath) }
    var skillWriters: [Bot] { bots.filter { !$0.isRemoteQueue } }

    /// The shared skills, then each bot's own in sidebar order, or only `botID`'s.
    func skillEntries(of botID: UUID? = nil) -> [SkillEntry] {
        Skills.discover(in: sharedSkillsFolder, scope: .shared).map { SkillEntry(skill: $0, bot: nil) }
            + bots.filter { !$0.isRemoteQueue && (botID == nil || $0.id == botID) }.flatMap { bot in
                Skills.discover(in: Skills.folder(of: bot), scope: .bot).map { SkillEntry(skill: $0, bot: bot) }
            }
    }

    func setSharedSkill(_ slug: String, enabled: Bool, for botID: UUID) {
        guard let i = bots.firstIndex(where: { $0.id == botID }), bots[i].usesSharedSkill(slug) != enabled else { return }
        bots[i].setSharedSkill(slug, enabled: enabled)
        save(bots[i])
    }

    func editSkill(_ entry: SkillEntry) {
        documentEditor = DocumentEditorRequest(skill: entry.skill, bot: entry.bot)
    }

    /// The bot writes the skill; BotChu sends an ordinary visible message in its Home.
    @discardableResult
    func askToWriteSkill(name: String, description: String, for botID: UUID, shared: Bool) -> Bool {
        guard let bot = bot(botID), !bot.isRemoteQueue,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let folder = shared ? sharedSkillsFolder : Skills.folder(of: bot)
        let target = ChatTarget.home(bot.id)
        show(target)
        return send(Skills.writingRequest(name: name, description: description, in: folder), to: target)
    }

    /// Puts the skill's folder in the Trash. A shared skill's slug no longer stays turned off for
    /// any bot, so another skill of that name starts on.
    func deleteSkill(_ entry: SkillEntry) throws {
        try entry.skill.trash()
        guard entry.bot == nil else { return }
        for bot in bots where !bot.usesSharedSkill(entry.skill.slug) {
            setSharedSkill(entry.skill.slug, enabled: true, for: bot.id)
        }
    }

    /// Shows a skill in Finder, or the folder skills go in when there is none.
    func revealSkill(_ entry: SkillEntry?, folder: URL? = nil) {
        if let entry {
            NSWorkspace.shared.activateFileViewerSelecting([entry.skill.url])
        } else {
            let folder = folder ?? sharedSkillsFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}

extension DocumentEditorRequest {
    init(skill: Skill, bot: Bot?) {
        name = skill.name
        owner = bot?.name ?? "Every bot"
        url = skill.url
        seed = skill.text
        placeholder = "Frontmatter, then the runbook…"
    }
}
