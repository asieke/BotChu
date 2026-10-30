import Foundation
import Testing
@testable import BotChuCore

/// #84: `@` mentions agents and `#` projects in the message box.
struct MentionTests {
    let duck = BotRosterEntry(bot: Bot(id: UUID(uuidString: "42C27670-0000-4000-8000-000000000001")!, name: "QA Duck",
                                       emoji: "🦆", title: "A Duck that QAs", workspace: "/tmp/duck"))
    let engineer = BotRosterEntry(bot: Bot(name: "10x Engineer Bot", title: "Principal engineer", workspace: "/tmp/10x"))
    let fox = BotRosterEntry(bot: Bot(name: "Product Fox", title: "Product management, QA triage", workspace: "/tmp/fox"))
    let botchu = ProjectCatalogEntry(name: "BotChu", repo: "asieke/BotChu", status: .active,
                                     location: RepoLocation(path: "/Users/alex/Desktop/WORKSPACE/BotChu"))
    let gitchu = ProjectCatalogEntry(name: "GitChu", repo: "asieke/GitChu", status: .paused)
    let ranch = ProjectCatalogEntry(name: "Ranch Treasurer", repo: "asieke/ranch-treasurer", status: .active)
    let bots = ProjectCatalogEntry(name: "bots", repo: "someone/bots")

    func query(_ marked: String, references: [NSRange] = []) -> MentionQuery? {
        let caret = (marked as NSString).range(of: "|").location
        return MentionQuery.at(caret, in: marked.replacingOccurrences(of: "|", with: ""), outside: references)
    }

    @Test func triggersAreSeparate() {
        #expect(query("Ask @qa|") == MentionQuery(kind: .agent, text: "qa", range: NSRange(location: 4, length: 3)))
        #expect(query("review #bot|") == MentionQuery(kind: .project, text: "bot", range: NSRange(location: 7, length: 4)))
        #expect(query("@|")?.kind == .agent)
        #expect(query("@|")?.text == "")
        #expect(query("see #|")?.kind == .project)
        // The nearest trigger decides: a project query after an agent's name.
        #expect(query("Ask @QA Duck to review #bo|")?.kind == .project)
        #expect(query("Ask @QA Duck to review #bo|")?.text == "bo")
    }

    @Test func queriesStartWordsOnly() {
        // Email addresses, URLs and their fragments.
        #expect(query("mail alex@example.com|") == nil)
        #expect(query("alex@exa|") == nil)
        #expect(query("https://github.com/asieke/BotChu#readme|") == nil)
        #expect(query("https://x.com/#/route|") == nil)
        #expect(query("https://x.com/@someone|") == nil)
        #expect(query("[link](#anchor|") == nil)
        #expect(query("`@available|") == nil)
        // Brackets and quotes may open an agent's mention.
        #expect(query("(@qa|")?.text == "qa")
        #expect(query("“@qa|")?.text == "qa")
        // The trigger must be on the caret's line.
        #expect(query("@qa\nduck|") == nil)
        #expect(query("hello|") == nil)
        #expect(query("|@qa") == nil)
    }

    @Test func issueNumbersAndHeadingsAreNotProjects() {
        #expect(query("fixes #123|") == nil)
        #expect(query("fixes #12|") == nil)
        #expect(query("#123|") == nil)
        #expect(query("#|") == nil)
        #expect(query("Notes\n#|") == nil)
        #expect(query("# |") == nil)
        #expect(query("# Heading|") == nil)
        #expect(query("## Heading|") == nil)
        #expect(query("##|") == nil)
        // Not a heading or an issue number: a project query.
        #expect(query("#12a|")?.text == "12a")
        #expect(query("#bot|")?.text == "bot")
        #expect(query("#asieke/Bot|")?.text == "asieke/Bot")
        #expect(query("#bot chu|") == nil)
    }

    @Test func agentQueriesHaveSpacesButNoProse() {
        #expect(query("Ask @qa duck|")?.text == "qa duck")
        #expect(query("Ask @qa |")?.text == "qa ")
        #expect(query("Ask @ qa|") == nil)
        #expect(query("Ask @qa  duck|") == nil)
        #expect(query("Ask @qa, then|") == nil)
        #expect(query("Ask @qa?|") == nil)
        #expect(query("Ask @" + String(repeating: "a", count: 41) + "|") == nil)
        // A query with a space shows only while something matches; one without shows "no matches".
        #expect(MentionQuery(kind: .agent, text: "qa please", range: NSRange()).showsList(matches: 0) == false)
        #expect(MentionQuery(kind: .agent, text: "qa d", range: NSRange()).showsList(matches: 1))
        #expect(MentionQuery(kind: .agent, text: "zz", range: NSRange()).showsList(matches: 0))
    }

    @Test func aChosenLabelIsNotAQueryAgain() {
        let text = "Ask @QA Duck"
        let label = NSRange(location: 4, length: 8)
        #expect(MentionQuery.at(12, in: text, outside: [label]) == nil)
        #expect(MentionQuery.at(8, in: text, outside: [label]) == nil)
        #expect(MentionQuery.at(12, in: text)?.text == "QA Duck")
        // Typing a new trigger after a chosen label is a query of its own.
        #expect(MentionQuery.at(16, in: "Ask @QA Duck #bo", outside: [label])?.text == "bo")
    }

    @Test func agentsMatchByNameThenTitleInSidebarOrder() {
        let directory = MentionDirectory(agents: [engineer, fox, duck])
        #expect(directory.agents(matching: "").map(\.name) == ["10x Engineer Bot", "Product Fox", "QA Duck"])
        // A name's prefix before a word's prefix before a title.
        #expect(directory.agents(matching: "qa").map(\.name) == ["QA Duck", "Product Fox"])
        #expect(directory.agents(matching: "QA d").map(\.name) == ["QA Duck"])
        #expect(directory.agents(matching: "qa ").map(\.name) == ["QA Duck"])
        #expect(directory.agents(matching: "engineer b").map(\.name) == ["10x Engineer Bot"])
        // After a whole name or word, a space starts prose: nothing matches, and the list closes.
        #expect(directory.agents(matching: "qa duck ").isEmpty)
        #expect(directory.agents(matching: "fox ").isEmpty)
        #expect(directory.agents(matching: "qa t").isEmpty)
        #expect(directory.agents(matching: "duck").map(\.name) == ["QA Duck"])
        #expect(directory.agents(matching: "qa-duck").map(\.name) == ["QA Duck"])
        #expect(directory.agents(matching: "engineer").map(\.name) == ["10x Engineer Bot"])
        #expect(directory.agents(matching: "principal").map(\.name) == ["10x Engineer Bot"])
        #expect(directory.agents(matching: "zzz").isEmpty)
        // Ties keep the sidebar's order, whatever the case.
        let another = BotRosterEntry(bot: Bot(name: "Quality Bot", workspace: "/tmp/q"))
        #expect(MentionDirectory(agents: [another, duck]).agents(matching: "Q").map(\.name) == ["Quality Bot", "QA Duck"])
    }

    @Test func duplicateAgentNamesAreToldApart() {
        let twin = BotRosterEntry(bot: Bot(name: "QA Duck", title: "A Duck that QAs", workspace: "/tmp/duck2"))
        let cousin = BotRosterEntry(bot: Bot(name: "qa duck", title: "Release checks", workspace: "/tmp/duck3"))
        let roster = [duck, twin, cousin]
        #expect(MentionDirectory.detail(of: duck, among: roster) == "A Duck that QAs · ID 42c27670")
        #expect(MentionDirectory.detail(of: twin, among: roster).hasPrefix("A Duck that QAs · ID "))
        #expect(MentionDirectory.detail(of: cousin, among: roster) == "Release checks")
        #expect(MentionDirectory.detail(of: duck, among: [duck, fox]) == "A Duck that QAs")
        // Each binds to its own ID.
        #expect(MessageReference.agent(duck).target != MessageReference.agent(twin).target)
        #expect(MessageReference.agent(duck).label == MessageReference.agent(twin).label)
    }

    /// #324: the list says what each agent runs on, as its row does, in place of its title, which
    /// still matches; a namesake that runs on the same shows the start of its ID.
    @Test func agentsShowWhatTheyRunOn() {
        var duck = duck, engineer = engineer
        duck.runsOn = "Claude Personal · Fable 5.1"
        engineer.runsOn = "Codex Work · GPT-6.1 Sol"
        #expect(MentionDirectory.detail(of: duck, among: [duck, engineer, fox]) == "Claude Personal · Fable 5.1")
        #expect(MentionDirectory.detail(of: fox, among: [duck, engineer, fox]) == "Product management, QA triage")
        #expect(MentionDirectory(agents: [duck, engineer]).agents(matching: "principal").map(\.name) == ["10x Engineer Bot"])
        let twin = BotRosterEntry(bot: Bot(name: "QA Duck", title: "Release checks", workspace: "/tmp/duck2"), runsOn: duck.runsOn)
        let cousin = BotRosterEntry(bot: Bot(name: "qa duck", title: "A Duck that QAs", workspace: "/tmp/duck3"), runsOn: "Muse · Wonderful")
        let roster = [duck, twin, cousin]
        #expect(MentionDirectory.detail(of: duck, among: roster) == "Claude Personal · Fable 5.1 · ID 42c27670")
        #expect(MentionDirectory.detail(of: twin, among: roster).hasPrefix("Claude Personal · Fable 5.1 · ID "))
        #expect(MentionDirectory.detail(of: cousin, among: roster) == "Muse · Wonderful")
    }

    @Test func projectsRankExactAndPrefixFirstThenFavoredThenGiven() {
        let directory = MentionDirectory(projects: [bots, gitchu, ranch, botchu], favoring: nil)
        // Without a query: active projects first, then the rest, each in the catalog's order.
        #expect(directory.projects(matching: "").map(\.repo) == ["asieke/ranch-treasurer", "asieke/BotChu", "someone/bots", "asieke/GitChu"])
        // In a task, its own repository comes first.
        let inTask = MentionDirectory(projects: [bots, gitchu, ranch, botchu], favoring: "ASIEKE/gitchu")
        #expect(inTask.projects(matching: "").first?.repo == "asieke/GitChu")
        // An exact name before a prefix, before a word's start, before anywhere.
        #expect(directory.projects(matching: "bots").map(\.repo) == ["someone/bots"])
        #expect(directory.projects(matching: "bot").map(\.repo) == ["asieke/BotChu", "someone/bots"])
        #expect(directory.projects(matching: "chu").map(\.repo) == ["asieke/BotChu", "asieke/GitChu"])
        #expect(directory.projects(matching: "treas").map(\.repo) == ["asieke/ranch-treasurer"])
        #expect(directory.projects(matching: "ranchtreasurer").map(\.repo) == ["asieke/ranch-treasurer"])
        #expect(directory.projects(matching: "asieke/git").map(\.repo) == ["asieke/GitChu"])
        #expect(directory.projects(matching: "someone").map(\.repo) == ["someone/bots"])
        #expect(directory.projects(matching: "nothing").isEmpty)
        // The same query ranks the same way every time.
        #expect(directory.projects(matching: "a") == directory.projects(matching: "A"))
    }

    @Test func insertingALabelAddsASpaceWhereNeeded() {
        let at = NSRange(location: 4, length: 3)
        #expect(MentionInsertion.make(label: "@QA Duck", replacing: at, in: "Ask @qa") == ("@QA Duck ", 13))
        #expect(MentionInsertion.make(label: "@QA Duck", replacing: at, in: "Ask @qa to review") == ("@QA Duck", 13))
        #expect(MentionInsertion.make(label: "@QA Duck", replacing: at, in: "Ask @qa, then") == ("@QA Duck", 12))
        #expect(MentionInsertion.make(label: "@QA Duck", replacing: at, in: "Ask @qa\nnext") == ("@QA Duck", 12))
        #expect(MentionInsertion.make(label: "@QA Duck", replacing: at, in: "Ask @qaxyz") == ("@QA Duck ", 13))
    }

    @Test func referencesFollowTrimmingAndJoining() {
        let reference = MessageReference.agent(duck, at: 6)
        #expect(MessageReference.standing([reference], in: "  Ask @QA Duck  ") == [reference])
        #expect(MessageReference.standing([reference], in: "  Ask @QA Duk  ").isEmpty)
        // Overlapping or out-of-range references don't stand.
        #expect(MessageReference.standing([reference, reference.moved(by: 2)], in: "  Ask @QA Duck  ") == [reference])
        #expect(MessageReference.standing([reference.moved(by: 40)], in: "  Ask @QA Duck  ").isEmpty)

        let trimmed = MessageReference.trimming(" \n Ask @QA Duck \n", references: [reference.moved(by: 1)])
        #expect(trimmed.text == "Ask @QA Duck")
        #expect(trimmed.references == [reference.moved(by: -2)])
        #expect(MessageReference.trimming("   ", references: [reference]).references.isEmpty)

        let project = MessageReference.project(botchu, login: "asieke", at: 7)
        let joined = MessageReference.joining(("Ask @QA Duck", [reference.moved(by: -2)]), ("Review #asieke/BotChu", [project]))
        #expect(joined.text == "Ask @QA Duck\n\nReview #asieke/BotChu")
        #expect(joined.references.map(\.label) == ["@QA Duck", "#asieke/BotChu"])
        #expect(joined.references.allSatisfy { $0.stands(in: joined.text as NSString) })
        #expect(MessageReference.joining(("Ask @QA Duck", [reference.moved(by: -2)]), ("", [])).text == "Ask @QA Duck")
    }

    /// #268: a New Task brief's mentions, trimmed as the sheet starts the task, stand in its first message.
    @Test func briefReferencesSurviveTrimmingIntoTheTasksOpening() {
        let agent = MessageReference.agent(duck, at: 7)
        let project = MessageReference.project(botchu, login: "asieke", at: 26)
        let brief = "\n  Ask @QA Duck to review #asieke/BotChu  \n"
        #expect((brief as NSString).substring(with: project.range) == "#asieke/BotChu")
        let trimmed = MessageReference.trimming(brief, references: [agent, project])
        let task = BotTask(for: Bot(name: "Scout", workspace: "/tmp/scout"), repo: "asieke/BotChu", checkout: "/tmp/BotChu",
                           work: nil, brief: trimmed.text)
        #expect(task.opening == "Ask @QA Duck to review #asieke/BotChu")
        #expect(MessageReference.standing(trimmed.references, in: task.opening) == [agent.moved(by: -3), project.moved(by: -3)])
    }

    @Test func statusNeverRebindsAReference() {
        let agent = MessageReference.agent(duck)
        #expect(ReferenceStatus.of(agent, agentIDs: [duck.id], repos: nil, login: nil) == .resolved)
        // Renamed: still the same agent, by its ID.
        var renamed = agent
        renamed.label = "@Old Name"
        #expect(ReferenceStatus.of(renamed, agentIDs: [duck.id], repos: nil, login: nil) == .resolved)
        #expect(ReferenceStatus.of(agent, agentIDs: [fox.id], repos: nil, login: nil) == .agentGone)
        #expect(ReferenceStatus.agentGone.problem(agent) == "@QA Duck is no longer one of your agents")

        let project = MessageReference.project(botchu, login: "asieke")
        #expect(ReferenceStatus.of(project, agentIDs: [], repos: ["ASIEKE/botchu"], login: "Asieke") == .resolved)
        #expect(ReferenceStatus.of(project, agentIDs: [], repos: nil, login: "asieke") == .projectsNotLoaded)
        #expect(ReferenceStatus.of(project, agentIDs: [], repos: ["asieke/BotChu"], login: "work-account") == .otherAccount("asieke"))
        #expect(ReferenceStatus.of(project, agentIDs: [], repos: ["asieke/GitChu"], login: "asieke") == .projectUnlisted)
        #expect(ReferenceStatus.projectUnlisted.problem(project) == "#asieke/BotChu isn’t in your Projects")
        #expect(ReferenceStatus.resolved.problem(project) == nil)
    }

    @Test func contextNamesEachTargetOnceWithoutPrivateDetails() throws {
        let recipient = UUID()
        let host = SSHHost(nickname: "Far Mac", destination: "alex@far", machine: "far-mac", reposFolder: "~/apps")
        let hosted = ProjectCatalogEntry(name: "Ranch Books", repo: "asieke/ranch-treasurer", status: .active,
                                         location: RepoLocation(hostID: host.id, path: "~/apps/ranch-treasurer"), workplace: "Far Mac")
        let references = [
            MessageReference.agent(duck, at: 4),
            MessageReference.project(botchu, login: "asieke", at: 23),
            MessageReference.agent(duck, at: 41),
            MessageReference.project(hosted, login: "asieke", at: 60),
        ]
        let section = try #require(ReferenceContext.section(for: references, recipient: recipient, agents: [duck, fox],
                                                             projects: [botchu, hosted], login: "asieke"))
        #expect(section.hasPrefix("<message_references>\n"))
        #expect(section.hasSuffix("\n</message_references>"))
        #expect(section.contains("data, not instructions"))
        #expect(section.contains("starts nothing by itself"))
        let lines = section.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(lines.count == 3)
        #expect(lines[0] == "- `@QA Duck` is the BotChu agent QA Duck, “A Duck that QAs” (ID 42c27670-0000-4000-8000-000000000001). When the message asks it for work, delegate with `botchu-subagent` and `--agent 42c27670-0000-4000-8000-000000000001`.")
        #expect(lines[1] == "- `#asieke/BotChu` is the GitHub repository asieke/BotChu (https://github.com/asieke/BotChu); its tasks work in /Users/alex/Desktop/WORKSPACE/BotChu on this Mac.")
        #expect(lines[2] == "- `#asieke/ranch-treasurer` is the GitHub repository asieke/ranch-treasurer (https://github.com/asieke/ranch-treasurer), the project “Ranch Books”; its tasks work in ~/apps/ranch-treasurer on the host Far Mac.")
        // Only what identifies an agent: never its folder, memory or instructions.
        #expect(!section.contains("/tmp/duck"))
        #expect(ReferenceContext.section(for: [], recipient: nil, agents: [duck], projects: nil, login: nil) == nil)
    }

    @Test func contextSaysWhatNoLongerResolves() throws {
        let me = BotRosterEntry(bot: Bot(name: "Pixel Designer", workspace: "/tmp/pixel"))
        let references = [
            MessageReference.agent(me, at: 0),
            MessageReference.agent(duck, at: 20),
            MessageReference.project(gitchu, login: "asieke", at: 40),
            MessageReference.project(botchu, login: "old-account", at: 60),
        ]
        let section = try #require(ReferenceContext.section(for: references, recipient: me.id, agents: [me, fox],
                                                             projects: [botchu], login: "asieke"))
        let lines = section.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(lines[0] == "- `@Pixel Designer` is you.")
        #expect(lines[1] == "- `@QA Duck` was one of your owner's BotChu agents, which no longer exists: don't take it for another agent.")
        #expect(lines[2] == "- `#asieke/GitChu` is the GitHub repository asieke/GitChu (https://github.com/asieke/GitChu); BotChu's Projects don't list it for the current GitHub account, so nothing more about it is known.")
        // Chosen under another account: its identity, not the current catalog's details.
        #expect(lines[3].hasPrefix("- `#asieke/BotChu` is the GitHub repository asieke/BotChu (https://github.com/asieke/BotChu); BotChu's Projects don't list it"))
        // No catalog at all: still the repository's identity.
        let unloaded = try #require(ReferenceContext.section(for: [references[2]], recipient: nil, agents: [], projects: nil, login: nil))
        #expect(unloaded.contains("https://github.com/asieke/GitChu"))
    }

    @Test func messagesKeepTheirReferencesAndOldThreadsStillLoad() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        let old = #"{"id":"6F2D5C1E-0000-4000-8000-000000000001","role":"user","text":"Hi","date":"2026-01-01T00:00:00Z"}"#
        let message = try decoder.decode(ChatMessage.self, from: Data(old.utf8))
        #expect(message.references == nil)
        #expect(message.mentions.isEmpty)
        // A message without references is saved as before.
        #expect(!String(decoding: try encoder.encode(ChatMessage(role: .user, text: "Hi")), as: UTF8.self).contains("references"))

        let references = [MessageReference.agent(duck, at: 4), MessageReference.project(botchu, login: "asieke", at: 13)]
        let sent = ChatMessage(role: .user, text: "Ask @QA Duck #asieke/BotChu", date: Date(timeIntervalSince1970: 1_800_000_000), references: references)
        let decoded = try decoder.decode(ChatMessage.self, from: encoder.encode(sent))
        #expect(decoded == sent)
        #expect(decoded.mentions == references)
    }

    @Test func queuedAndSavedMessagesKeepTheirReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-mentions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.path)
        let references = [MessageReference.agent(duck, at: 4)]
        let message = ChatMessage(role: .user, text: "Ask @QA Duck", references: references)
        var queue = MessageQueue()
        queue.enqueue(message)
        try home.saveQueue(queue)
        #expect(home.loadQueue(delivered: []).messages.first?.mentions == references)
        try home.saveThread([message])
        #expect(home.loadThread().first?.mentions == references)
        // Delivered, it leaves the queue and stays in the transcript with its references.
        #expect(home.loadQueue(delivered: home.loadThread()).messages.isEmpty)
    }
}
