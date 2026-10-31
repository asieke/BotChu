import Foundation
import BotChuCore

/// New Issue (#245), opened with I in Projects or its header's button: what to file, in which
/// repository, and which bot writes it up on which profile (Product Fox on its own, until another
/// is chosen). Filing goes on in the background (`IssueFiling`), so the sheet closes at once.
@MainActor @Observable
final class NewIssueRequest: Identifiable {
    let id = UUID()
    var repo: String?
    var botID: UUID?
    var accountID: String?
    var text = ""
    /// The agents and projects chosen in `text` from `@` and `#` completion.
    var references: [MessageReference] = []
    let images = DraftImages()

    init(repo: String?, botID: UUID?, accountID: String?) {
        self.repo = repo
        self.botID = botID
        self.accountID = accountID
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// An issue being written up and filed in the background, shown in Projects' header until it is
/// filed (for a moment, then it is in the Inbox) or, when it fails, until it is tried again or dismissed.
struct IssueFiling: Identifiable, Equatable {
    enum State: Equatable {
        case writing
        case filed(URL?, title: String)
        case failed(String)
    }

    let id = UUID()
    let repo: String
    let botID: UUID
    let botName: String
    let accountID: String
    let model: String
    /// What was asked for, with its mentions and images, to try again.
    let request: String
    var references: [MessageReference] = []
    let images: [Data]
    var state = State.writing
}

extension AppModel {
    /// How long a filed issue stays in Projects' header, in seconds.
    static let filedIssueShownFor: Duration = .seconds(12)

    /// Whether New Issue can open: not over another sheet, and with a bot to write it.
    var canStartNewIssue: Bool {
        editor == nil && documentEditor == nil && issueReport == nil && newIssue == nil && !openingReport
            && jobs.editor == nil && jobs.history == nil && IssueDraft.defaultBot(in: bots) != nil
    }

    /// The bots that can write an issue: those on this Mac.
    var issueWriters: [Bot] { bots.filter { !$0.isRemoteQueue } }

    /// Opens New Issue for `repo`, else the repository selected in Projects, with Product Fox (or
    /// the first bot) on its own profile when that can write one.
    func startNewIssue(repo: String? = nil) {
        guard canStartNewIssue, let bot = IssueDraft.defaultBot(in: bots) else { return }
        let account = IssueDraft.defaultAccount(for: bot, among: settings.accounts, quick: settings.quickTasks)
        newIssue = NewIssueRequest(repo: repo ?? projectSelection?.repo, botID: bot.id, accountID: account?.id)
    }

    /// Chooses the bot that writes the issue, and with it that bot's own profile when it can.
    func chooseIssueWriter(_ botID: UUID, for request: NewIssueRequest) {
        guard let bot = bot(botID) else { return }
        request.botID = botID
        request.accountID = IssueDraft.defaultAccount(for: bot, among: settings.accounts, quick: settings.quickTasks)?.id
    }

    /// Why New Issue can't be filed yet, or nil when it can.
    func newIssueProblem(_ request: NewIssueRequest) -> String? {
        if request.repo == nil { return "Choose a repository" }
        if request.botID.flatMap(bot) == nil { return "Choose a bot" }
        if request.accountID.flatMap({ id in IssueDraft.accounts(settings.accounts).first { $0.id == id } }) == nil { return "Choose a provider" }
        if request.isEmpty { return "Say what the issue is about" }
        if request.images.images.count > IssueReport.imageLimit { return "Attach up to \(IssueReport.imageLimit) images" }
        return nil
    }

    /// Closes New Issue and files it in the background.
    func fileNewIssue(_ request: NewIssueRequest) {
        guard newIssueProblem(request) == nil, let repo = request.repo, let bot = request.botID.flatMap(bot),
              let account = request.accountID.flatMap({ id in settings.accounts.first { $0.id == id } }) else { return }
        let (text, references) = MessageReference.trimming(request.text, references: request.references)
        let filing = IssueFiling(repo: repo, botID: bot.id, botName: bot.name, accountID: account.id,
                                 model: IssueDraft.model(for: bot, account: account, quick: settings.quickTasks),
                                 request: text, references: references, images: request.images.images.map(\.png))
        newIssue = nil
        issueFilings.append(filing)
        run(filing)
    }

    /// Tries a filing that failed again, as it was asked for.
    func retryFiling(_ id: UUID) {
        guard let i = issueFilings.firstIndex(where: { $0.id == id }), case .failed = issueFilings[i].state else { return }
        issueFilings[i].state = .writing
        run(issueFilings[i])
    }

    func dismissFiling(_ id: UUID) {
        issueFilings.removeAll { $0.id == id && $0.state != .writing }
    }

    private func run(_ filing: IssueFiling) {
        guard !terminating, let bot = bot(filing.botID) else {
            finish(filing.id, .failed("Its bot is gone"))
            return
        }
        let account = settings.account(filing.accountID)
        let description = repositories?.first { $0.nameWithOwner.caseInsensitiveCompare(filing.repo) == .orderedSame }?.description ?? ""
        let open = (openItems ?? []).filter { !$0.isPullRequest && $0.repo.caseInsensitiveCompare(filing.repo) == .orderedSame }
            .map { IssueDraft.OpenIssue(number: $0.number, title: $0.title) }
        let instructions = BotContext.instructions(of: bot, file: Workspace.read((bot.workspace as NSString).appendingPathComponent(BotContext.instructionsFile)))
        let prompt = IssueDraft.prompt(request: filing.request, references: referenceContext(filing.references, for: bot.id),
                                       repository: filing.repo, description: description, openIssues: open,
                                       images: filing.images.count, botName: bot.name, instructions: instructions,
                                       team: Workspace.read(settings.teamPath))
        let job = IssueDraft.job(key: filing.id.uuidString, bot: bot, account: account, model: filing.model, prompt: prompt)
        let runner = issueRunner ?? liveIssueRunner()
        let create = issueCreate
        Task { [weak self] in
            let outcome = await IssueDraft.file(job, repository: filing.repo, botName: filing.botName, images: filing.images,
                                                runner: runner, create: create)
            self?.finish(filing.id, outcome)
        }
    }

    /// Shows how a filing went; a filed issue goes to the Inbox as its bot's, the projects are
    /// synced so it shows in their lists, and it leaves the header after a moment.
    private func finish(_ id: UUID, _ outcome: IssueDraft.Outcome) {
        guard let i = issueFilings.firstIndex(where: { $0.id == id }) else { return }
        let filing = issueFilings[i]
        switch outcome {
        case .failed(let reason):
            issueFilings[i].state = .failed(reason)
        case .filed(let url, let title, let problem):
            issueFilings[i].state = .filed(url, title: title)
            let number = url.flatMap(IssueReport.number(of:))
            let note = [url.map { "Filed in \(filing.repo): \($0.absoluteString)" } ?? "Filed in \(filing.repo).", problem]
                .compactMap { $0 }.joined(separator: "\n\n")
            let delivery = Delivery(botID: filing.botID, title: number.map { "Filed #\($0): \(title)" } ?? "Filed: \(title)", note: note,
                                    links: number.map { [Delivery.Link(repo: filing.repo, number: $0, isPullRequest: false)] } ?? [],
                                    purpose: .completed)
            Task { [weak self] in
                try? await self?.inbox?.post(delivery)
                await self?.refreshProjects()
            }
            Task { [weak self] in
                try? await Task.sleep(for: Self.filedIssueShownFor)
                self?.issueFilings.removeAll { $0.id == id }
            }
        }
    }

    /// Writes the issue on this Mac with the profile's command from Settings, logged in its bot's
    /// turn log as an "issue draft".
    private func liveIssueRunner() -> RunEvaluator.Runner {
        { [weak self] job in
            guard let launch = await self?.issueLaunch(for: job) else { throw EvaluationRunError("BotChu is closing") }
            return try await EvaluationCLI.run(job, command: launch.command, model: launch.model, log: launch.home, what: "issue draft")
        }
    }

    private func issueLaunch(for job: EvaluationJob) -> (command: String, model: String, home: BotHome?) {
        (settings.command(for: job.account), job.model, bot(job.botID).map { BotHome(workspace: $0.persistencePath) })
    }
}
