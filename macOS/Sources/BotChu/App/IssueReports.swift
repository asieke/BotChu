import AppKit
import BotChuCore

/// The Report a Bug or Feature sheet: the report being written, with its images (the first a
/// screenshot of the window it was opened from, until it is removed), the app's state as it was
/// when the sheet opened (what the sheet shows is what the issue gets), and how filing went.
@MainActor @Observable
final class IssueReportRequest: Identifiable {
    enum State: Equatable {
        case writing
        case filing
        /// The new issue's address (nil when gh made it without printing one), and what went wrong
        /// once it was made, such as an image that didn't upload.
        case filed(URL?, problem: String? = nil)
        /// Why it wasn't filed; the report stays, to try again.
        case failed(String)
    }

    let id = UUID()
    let snapshot: IssueSnapshot
    var text = ""
    /// The Title field (#232); left empty, the issue is titled from the report's first line.
    var typedTitle = ""
    let images: DraftImages
    /// Why the report has no screenshot of its window, when BotChu couldn't take one.
    let screenshotProblem: String?
    private let screenshotID: UUID?
    private(set) var state = State.writing

    /// What the screenshot is called where it shows among the report's images.
    static let screenshotName = "Screenshot of this window"

    /// - Parameter screenshot: the window's picture as PNG, or why there is none; nil when none was taken.
    init(snapshot: IssueSnapshot, text: String = "", screenshot: Result<Data, any Error>? = nil) {
        self.snapshot = snapshot
        self.text = text
        let images = DraftImages()
        var problem: String?
        var id: UUID?
        do { id = try screenshot.map { try images.add(png: $0.get(), name: Self.screenshotName) } }
        catch { problem = error.localizedDescription }
        self.images = images
        screenshotID = id
        screenshotProblem = problem
    }

    /// Whether the window's screenshot is still among the images, to go with the report.
    var hasScreenshot: Bool { images.images.contains { $0.id == screenshotID } }

    /// The issue's title: as typed, else from the report's first line.
    var title: String { IssueReport.title(typed: typedTitle, report: text) }
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Who can see what the report sends, as the sheet's header says it.
    var visibility: String {
        IssueReport.visibility(screenshot: hasScreenshot, images: images.images.count - (hasScreenshot ? 1 : 0))
    }

    var canSubmit: Bool {
        guard case .filed = state else { return state != .filing && !isEmpty }
        return false
    }

    func submit(with filer: IssueFiler) async {
        guard canSubmit else { return }
        state = .filing
        switch await filer.file(text, title: typedTitle, images: images.images.map(\.png), snapshot: snapshot) {
        case .filed(let url, let problem): state = .filed(url, problem: problem)
        case .failed(let problem): state = .failed(problem)
        }
    }
}

extension AppModel {
    /// Whether Report a Bug or Feature can open: not over another sheet, nor while one is opening.
    var canReportIssue: Bool {
        editor == nil && taskSheet == nil && documentEditor == nil && issueReport == nil && !openingReport
    }

    /// Opens Report a Bug or Feature (`openReport(text:)`).
    func reportIssue(text: String = "") {
        Task { await openReport(text: text) }
    }

    /// Opens Report a Bug or Feature with the app's state as it is now and a screenshot of the
    /// window it is reported from, taken before the sheet covers any of it. When that can't be
    /// taken, the sheet still opens, without one, and says so. Every report takes its own.
    @discardableResult
    func openReport(text: String = "") async -> IssueReportRequest? {
        guard canReportIssue else { return nil }
        openingReport = true
        defer { openingReport = false }
        let window = reportWindow
        let snapshot = issueSnapshot(window: window)
        let screenshot = await WindowCapture.take(window, with: windowCapture)
        // Another sheet opened meanwhile.
        guard editor == nil, taskSheet == nil, documentEditor == nil else { return nil }
        let request = IssueReportRequest(snapshot: snapshot, text: text, screenshot: screenshot)
        issueReport = request
        return request
    }

    /// The window a report is made from: the key or main window when it is one of BotChu's main
    /// windows (as when its toolbar button or the Help menu is used), else the first of those shown.
    var reportWindow: NSWindow? {
        let windows = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
        return [NSApp.keyWindow, NSApp.mainWindow].lazy.compactMap { $0 }.first { windows.contains($0) }
            ?? windows.first ?? NSApp.mainWindow
    }

    /// What a report says about the app (see `IssueSnapshot`): the screen, and for a conversation
    /// its kind, account family and state, with the window's size and appearance (`window`, else
    /// `reportWindow`). `defaults` holds the status sidebar's settings, as the views store them.
    func issueSnapshot(defaults: UserDefaults = .standard, window: NSWindow? = nil) -> IssueSnapshot {
        var screen = IssueSnapshot.Screen.noBot
        var conversation: IssueSnapshot.Conversation?
        if let destination {
            switch destination {
            case .inbox: screen = .inbox
            case .projects: screen = .projects
            case .agents: screen = .agents
            case .providers: screen = .providers
            case .skills: screen = .skills
            case .jobs: screen = .jobs
            case .settings: screen = .settings
            }
        } else if let id = selection, bot(id) != nil {
            let target = tab(of: id)
            let showsStatus = defaults.object(forKey: "showsStatus") as? Bool ?? true
            let area = InspectorTab(rawValue: defaults.string(forKey: InspectorTab.storageKey) ?? "") ?? .activity
            screen = .conversation(statusArea: showsStatus ? area.title : nil)
            if let settings = runSettings(of: target) {
                let queue = messageQueues[target]
                conversation = IssueSnapshot.Conversation(
                    settings: settings, task: task(target), status: status(of: target), openTasks: openTasks(of: id).count,
                    queued: queue?.pending.count ?? 0, queuePaused: queue?.isPaused ?? false,
                    subagents: delegation?.activeCount(target) ?? 0)
            }
        }
        let window = window ?? reportWindow
        let size = window?.contentView?.bounds.size
        return IssueSnapshot(
            info: Bundle.main.infoDictionary, screen: screen, conversation: conversation,
            window: window.flatMap { window in
                size.map { IssueSnapshot.Window(width: $0.width, height: $0.height,
                                                dark: window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) }
            },
            bots: bots.count, runningTurns: runStates.count)
    }
}
