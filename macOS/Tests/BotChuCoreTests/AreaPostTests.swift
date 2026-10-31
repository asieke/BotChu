import Foundation
import Testing
@testable import BotChuCore

/// Requests that used to open a task's tab, posted into Project Areas (#404, #399 decision 9).
@Suite struct AreaPostTests {
    let fox = Bot(name: "Product Fox", workspace: "/tmp/fox")
    let builder = Bot(name: "10x Engineer Bot", workspace: "/tmp/builder")

    @Test func aRequestGoesToTheBotsAreaToAnUnownedRepositoryOrToTheOwnersArea() {
        let mine = BotTask(repoArea: "o/r", checkout: "/w/r", for: fox)
        var hidden = BotTask(repoArea: "o/hidden", checkout: "/w/hidden", for: fox)
        hidden.archivedAt = Date()
        let theirs = BotTask(repoArea: "o/other", checkout: "/w/other", for: builder)
        let legacy = BotTask(for: builder, repo: "o/legacy", checkout: "/w/legacy", work: nil, brief: "Go", branch: "feat/go")
        let bots = [(botID: fox.id, tasks: [mine, hidden]), (botID: builder.id, tasks: [theirs, legacy])]

        #expect(AreaPost.placement(repo: "o/r", for: fox.id, among: bots) == .own(area: mine.id))
        #expect(AreaPost.placement(repo: "O/R", for: fox.id, among: bots) == .own(area: mine.id))
        // A hidden area is still the bot's own.
        #expect(AreaPost.placement(repo: "o/hidden", for: fox.id, among: bots) == .own(area: hidden.id))
        // A legacy task on a repository doesn't make it owned.
        #expect(AreaPost.placement(repo: "o/legacy", for: fox.id, among: bots) == .attach)
        #expect(AreaPost.placement(repo: "o/new", for: fox.id, among: bots) == .attach)
        #expect(AreaPost.placement(repo: "o/other", for: fox.id, among: bots) == .owner(botID: builder.id, area: theirs.id))
        #expect(AreaPost.placement(repo: "o/other", for: builder.id, among: bots) == .own(area: theirs.id))
    }

    @Test func thePostedMessageNamesTheIssueOrPullRequestThenTheBrief() {
        let issue = BotTask.Work(number: 12, title: "Crash on launch", url: URL(string: "https://github.com/o/r/issues/12")!, isPullRequest: false)
        let pull = BotTask.Work(number: 7, isPullRequest: true, repo: "o/r")
        #expect(AreaPost.text(brief: "  Fix it  ", work: nil, review: nil) == "Fix it")
        #expect(AreaPost.text(brief: "", work: issue, review: nil) == "Work on issue #12 “Crash on launch” https://github.com/o/r/issues/12")
        #expect(AreaPost.text(brief: "Keep it small", work: issue, review: nil)
            == "Work on issue #12 “Crash on launch” https://github.com/o/r/issues/12\n\nKeep it small")
        #expect(AreaPost.text(brief: "", work: pull, review: nil) == "Continue pull request #7 https://github.com/o/r/pull/7")
        #expect(AreaPost.text(brief: "", work: pull, review: .review) == "Review pull request #7 https://github.com/o/r/pull/7")
        #expect(AreaPost.text(brief: "", work: pull, review: .comment) == "Review and comment on pull request #7 https://github.com/o/r/pull/7")
        #expect(AreaPost.text(brief: "Go", work: nil, review: nil, branch: "fix/12-crash") == "Go\n\nBranch: `fix/12-crash`")
        #expect(AreaPost.text(brief: "", work: nil, review: nil, branch: " ") == "")
    }

    @Test func aRepeatedRequestPostsUnderTheSameMessageID() {
        let request = TaskRequest(repo: "o/r", task: "Fix it", agent: "fox")
        let caller = UUID()
        let handoff = TaskHandoff(invocationID: UUID(), callerBotID: caller, request: request)
        // Asked again, in a later turn of the same conversation: the same key, so the same message.
        let again = TaskHandoff(invocationID: UUID(), callerBotID: caller, request: request)
        let id = AreaPost.messageID(key: handoff.key(for: fox.id))
        #expect(id == AreaPost.messageID(key: again.key(for: fox.id)))
        #expect(id != AreaPost.messageID(key: handoff.key(for: builder.id)))
        #expect(id != AreaPost.messageID(key: TaskHandoff(invocationID: UUID(), callerBotID: caller,
                                                          request: TaskRequest(repo: "o/r", task: "Fix that", agent: "fox")).key(for: fox.id)))
        // The same on every launch: a pure function of the key.
        #expect(AreaPost.messageID(key: "abc") == AreaPost.messageID(key: "abc"))
        #expect(AreaPost.messageID(key: "abc").uuidString.dropFirst(14).first == "8")

        let posted = ChatMessage(id: id, role: .user, text: "Fix it")
        #expect(AreaPost.posted(id, thread: [ChatMessage(role: .user, text: "Hi"), posted], queue: []))
        #expect(AreaPost.posted(id, thread: [], queue: [posted]))
        #expect(!AreaPost.posted(id, thread: [ChatMessage(role: .user, text: "Fix it")], queue: []))
    }

    @Test func theAreasBotHearsWhoAsksAndFromWhere() {
        let link = AgentLink(botID: fox.id, name: "Product Fox")
        let prompt = AreaPost.prompt("Fix it", from: link, place: "Product Fox's Home")
        #expect(prompt == "[Product Fox asks this of you, from Product Fox's Home. Carry it through here as your own work.]\n\nFix it")
    }

    @Test func receiptsSayWhichAreaGotTheRequestAndWhy() {
        let area = BotTask(repoArea: "o/r", checkout: "/w/r", for: builder)
        #expect(TaskReceipt.posted(in: area, of: "10x Engineer Bot") == "Asked 10x Engineer Bot in r")
        #expect(TaskReceipt.posted(in: area, of: "10x Engineer Bot", for: "Product Fox")
            == "Asked 10x Engineer Bot in r for Product Fox: 10x Engineer Bot has o/r")
    }

    @Test func homesAgentsFileListsItsAreasAndHowToPostIntoThem() {
        let repo = BotTask(repoArea: "asieke/BotChu", checkout: "/Users/a/WORKSPACE/BotChu", for: fox, at: Date(timeIntervalSince1970: 1))
        let folder = BotTask(folderArea: "Notes", folder: "/tmp/fox/areas/notes", for: fox, at: Date(timeIntervalSince1970: 2))
        var hidden = BotTask(repoArea: "asieke/Old", checkout: "/w/Old", for: fox)
        hidden.archivedAt = Date()
        let legacy = BotTask(for: fox, repo: "asieke/GitChu", checkout: "/w/GitChu", work: nil, brief: "Go", branch: "feat/go")
        let areas = AreaListing.of([folder, legacy, hidden, repo])
        #expect(areas == [AreaListing(name: "BotChu", repo: "asieke/BotChu", folder: "/Users/a/WORKSPACE/BotChu"),
                          AreaListing(name: "Notes", repo: "", folder: "/tmp/fox/areas/notes")])

        let agents = BotContext.agentsFile(bot: fox, sharedMemoryPath: "/shared", areas: areas)
        #expect(agents.contains("## Project Areas\nThis conversation is your Home"))
        #expect(agents.contains("Yours now:\n- `asieke/BotChu`: `/Users/a/WORKSPACE/BotChu`\n- Notes (a folder): `/tmp/fox/areas/notes`"))
        #expect(agents.contains("posts the request as a turn in the repository's area"))
        #expect(!agents.contains("## Tasks") && !agents.contains("tab beside") && !agents.contains("makes the task's worktree"))
        let none = BotContext.agentsFile(bot: fox, sharedMemoryPath: "/shared")
        #expect(none.contains("You have none yet: asking for work in a repository no bot has attaches its area to you."))
    }

    @Test func sessionPreparationRewritesTheAgentsFileWhenTheAreasChange() {
        let before = SessionPreparation.Input(bot: fox, sharedMemoryPath: "/shared")
        let after = SessionPreparation.Input(bot: fox, sharedMemoryPath: "/shared",
                                             areas: [AreaListing(name: "r", repo: "o/r", folder: "/w/r")])
        #expect(before != after)
    }

    @Test func aHandoffResultForAnAreaSaysSoAndOldResultsStillDecode() throws {
        let area = TaskHandoffResult(id: UUID(), phase: .created, taskID: UUID(), taskTitle: "BotChu", area: true)
        let decoded = try JSONDecoder().decode(TaskHandoffResult.self, from: JSONEncoder().encode(area))
        #expect(decoded.area == true && decoded == area)
        let task = TaskHandoffResult(id: UUID(), phase: .created)
        #expect(task.area == nil)
        #expect(!String(decoding: try JSONEncoder().encode(task), as: UTF8.self).contains("area"))
    }

    @Test func telegramSaysWhichAreaItPostedTo() {
        #expect(TelegramReply.taskPosted(in: "BotChu", bot: "Fox", owner: nil, repo: "asieke/BotChu")
            == "Posted in Fox's area “BotChu” for asieke/BotChu. Its replies stay in BotChu.")
        #expect(TelegramReply.taskPosted(in: "BotChu", bot: "Fox", owner: "Builder", repo: "asieke/BotChu")
            == "Posted in Builder's area “BotChu” for asieke/BotChu, for Fox: Builder has that repository. Its replies stay in BotChu.")
    }
}
