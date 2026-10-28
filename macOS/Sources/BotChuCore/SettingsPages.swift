import Foundation

/// A page of Settings, in the main window's detail column (#191): its name is the one the app's
/// messages already use ("Settings ▸ Run reviews"), and its raw value is what is remembered and
/// what `BOTCHU_SETTINGS` names.
public enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
    case general, accounts, github, hosts
    case runReviews = "run-reviews", pets
    case openRouter = "openrouter", sail, telegram, remoteQueue = "remote-queue"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .github: "GitHub"
        case .hosts: "Hosts"
        case .runReviews: "Run reviews"
        case .pets: "Pets"
        case .openRouter: "OpenRouter"
        case .sail: "Sail"
        case .telegram: "Telegram"
        case .remoteQueue: "Remote queue"
        }
    }

    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "terminal"
        case .github: "arrow.triangle.pull"
        case .hosts: "network"
        case .runReviews: "checkmark.seal"
        case .pets: "pawprint"
        case .openRouter: "arrow.triangle.branch"
        case .sail: "sailboat"
        case .telegram: "paperplane"
        case .remoteQueue: "antenna.radiowaves.left.and.right"
        }
    }

    /// The pages in the rail's three groups: this Mac and its tools, what bots do on their own, and
    /// the services BotChu reaches.
    public static let groups: [[SettingsPage]] = [
        [.general, .accounts, .github, .hosts],
        [.runReviews, .pets],
        [.openRouter, .sail, .telegram, .remoteQueue],
    ]

    /// Below this width of the page area, the rail folds into the page's title, as a menu.
    public static let compactWidth: Double = 720

    public static func isCompact(width: Double) -> Bool { width < compactWidth }
}

/// What the rail shows beside a page, so a page that needs the owner is seen without opening it.
/// Never colour alone: each has words or a symbol of its own.
public enum SettingsMark: Equatable, Sendable {
    /// Something is wrong there, `count` things where they can be counted (Accounts' missing commands).
    case problem(count: Int?)
    /// A service of that page is running.
    case on
    /// A key typed there isn't saved yet.
    case unsaved

    public var label: String {
        switch self {
        case .problem(let count?): count == 1 ? "1 problem" : "\(count) problems"
        case .problem(nil): "Needs attention"
        case .on: "On"
        case .unsaved: "Not saved"
        }
    }

    /// The mark for Accounts: how many commands the login shell didn't find, if any.
    public static func accounts(found: [String: Bool]) -> SettingsMark? {
        let missing = found.values.filter { !$0 }.count
        return missing == 0 ? nil : .problem(count: missing)
    }

    /// The mark for a page with a key field and a service: an unsaved key first, then a problem,
    /// then whether it runs.
    public static func service(unsaved: Bool, problem: Bool, running: Bool) -> SettingsMark? {
        if unsaved { return .unsaved }
        if problem { return .problem(count: nil) }
        return running ? .on : nil
    }
}

/// A key typed in Settings (the OpenRouter key, the Telegram bot token), saved only with Save. It
/// lives as long as Settings shows, so switching pages keeps what is typed; it reads the saved key
/// only when its page first shows, so other pages never touch the Keychain.
public struct SettingsKeyDraft: Equatable, Sendable {
    /// What the field holds; nil until its page shows.
    public var text: String?
    /// The key as saved, when the page first showed or since Save.
    public private(set) var saved = ""

    public init() {}

    /// Starts the draft from the saved key, once.
    public mutating func seed(saved key: String?) {
        guard text == nil else { return }
        saved = key ?? ""
        text = saved
    }

    public var value: String { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Something is typed that isn't saved.
    public var isUnsaved: Bool { text != nil && value != saved }

    /// The key to save; the draft then holds it as saved.
    public mutating func save() -> String {
        let key = value
        text = key
        saved = key
        return key
    }
}
