import AppKit
import BotChuCore

/// The Report a Bug or Feature sheet: the report being written, with its images, the app's state as
/// it was when the sheet opened (what the sheet shows is what the issue gets), and how filing went.
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
    let images = DraftImages()
    private(set) var state = State.writing

    init(snapshot: IssueSnapshot, text: String = "") {
        self.snapshot = snapshot
        self.text = text
    }

    var title: String { IssueReport.title(from: text) }
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var canSubmit: Bool {
        guard case .filed = state else { return state != .filing && !isEmpty }
        return false
    }

    func submit(with filer: IssueFiler) async {
        guard canSubmit else { return }
        state = .filing
        switch await filer.file(text, images: images.images.map(\.png), snapshot: snapshot) {
        case .filed(let url, let problem): state = .filed(url, problem: problem)
        case .failed(let problem): state = .failed(problem)
        }
    }
}

extension AppModel {
    /// Whether Report a Bug or Feature can open: not over another sheet.
    var canReportIssue: Bool {
        editor == nil && taskSheet == nil && documentEditor == nil && issueReport == nil
    }

    /// Opens Report a Bug or Feature with the app's state as it is now.
    func reportIssue(text: String = "") {
        guard canReportIssue else { return }
        issueReport = IssueReportRequest(snapshot: issueSnapshot(), text: text)
    }

    /// What a report says about the app (see `IssueSnapshot`): the screen, and for a conversation
    /// its kind, account family and state, with the window's size and appearance. `defaults` holds
    /// the status sidebar's settings, as the views store them.
    func issueSnapshot(defaults: UserDefaults = .standard) -> IssueSnapshot {
        var screen = IssueSnapshot.Screen.noBot
        var conversation: IssueSnapshot.Conversation?
        if let destination {
            switch destination {
            case .projects: screen = .projects
            case .agents: screen = .agents
            case .providers: screen = .providers
            case .skills: screen = .skills
            case .jobs: screen = .jobs
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
        let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true } ?? NSApp.mainWindow
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
