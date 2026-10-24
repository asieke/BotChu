import Foundation
import Observation
import BotChuCore

/// Settings kept in `defaults` (domain `local.BotChu`); the OpenRouter key and the Telegram bot
/// token are in the Keychain.
@MainActor @Observable
final class AppSettings {
    private let defaults: UserDefaults

    var customAccounts: [Account] { didSet { save(customAccounts, forKey: "customAccounts") } }
    var accounts: [Account] { Accounts.all + customAccounts }

    var botsRoot: String { didSet { defaults.set(botsRoot, forKey: "botsRoot") } }
    /// Where repositories are checked out on this Mac, one folder each, and where BotChu clones one
    /// a task needs.
    var reposRoot: String { didSet { defaults.set(reposRoot, forKey: "reposRoot") } }
    /// The computers besides this Mac that tasks can run on, over SSH.
    var hosts: [SSHHost] { didSet { save(hosts, forKey: "hosts") } }
    /// Where the owner chose to work on each repository (`owner/name`), when not where it lives by default.
    var repoLocations: [String: RepoLocation] { didSet { save(repoLocations, forKey: "repoLocations") } }
    /// This Mac's short name, as PROJECT.md's `deploy` calls it: looked up off the main thread (it
    /// runs `scutil`), nil until it is. What places a task waits for it (`resolvedMacName`), never
    /// taking another name meanwhile.
    private(set) var thisMacName: String?
    private let macName = Task.detached(priority: .utility) { Locations.thisMacName() }

    func resolvedMacName() async -> String { await macName.value }
    var openRouterModel: String { didSet { defaults.set(openRouterModel, forKey: "openRouterModel") } }
    /// Command overrides by account id; a missing or empty entry means the account's default.
    var commands: [String: String] { didSet { defaults.set(commands, forKey: "commands") } }
    /// The Codex account that draws pets for bots that don't run on Codex themselves.
    var petAccountID: String { didSet { defaults.set(petAccountID, forKey: "petAccountID") } }
    /// The OpenRouter model that turns a pet's stills into clips.
    var petModelID: String { didSet { defaults.set(petModelID, forKey: "petModelID") } }
    /// Whether finished task turns and sub-agent runs are reviewed in the background (`RunEvaluator`).
    var evaluateRuns: Bool { didSet { defaults.set(evaluateRuns, forKey: "evaluateRuns") } }
    /// Whether the Telegram gateway runs (`TelegramBridge`), and the private chats it lets reach a
    /// bot's Home.
    var telegramEnabled: Bool { didSet { defaults.set(telegramEnabled, forKey: "telegramEnabled") } }
    var telegramChats: [TelegramChat] { didSet { save(telegramChats, forKey: "telegramChats") } }
    /// Invalidates allowance readings when the saved OpenRouter key changes, without retaining it.
    var usageCredentialRevision = 0

    init(defaults: UserDefaults? = nil) {
        // Throwaway runs (DevHooks) keep their settings apart from the real ones.
        let defaults = defaults ?? (DevHooks.dataDir == nil ? .standard : UserDefaults(suiteName: "local.BotChu.dev")!)
        self.defaults = defaults
        customAccounts = DevHooks.dataDir == nil ? Self.load([Account].self, from: defaults, forKey: "customAccounts") ?? [] : []
        if let dev = DevHooks.dataDir {
            botsRoot = dev.appendingPathComponent("bots").path
            reposRoot = dev.appendingPathComponent("repos").path
            hosts = DevHooks.hosts
            repoLocations = [:]
        } else {
            botsRoot = defaults.string(forKey: "botsRoot") ?? (NSHomeDirectory() as NSString).appendingPathComponent("BotChu")
            reposRoot = defaults.string(forKey: "reposRoot") ?? "~/Desktop/WORKSPACE"
            hosts = Self.load([SSHHost].self, from: defaults, forKey: "hosts") ?? []
            repoLocations = Self.load([String: RepoLocation].self, from: defaults, forKey: "repoLocations") ?? [:]
        }
        openRouterModel = (DevHooks.dataDir != nil ? DevHooks.env["BOTCHU_DEFAULT_MODEL"] : nil)
            ?? defaults.string(forKey: "openRouterModel") ?? CommandBuilder.defaultOpenRouterModel
        commands = defaults.dictionary(forKey: "commands") as? [String: String] ?? [:]
        petAccountID = defaults.string(forKey: "petAccountID") ?? "codex-personal"
        petModelID = defaults.string(forKey: "petModelID") ?? PetVideo.defaultModel.id
        evaluateRuns = defaults.object(forKey: "evaluateRuns") as? Bool ?? true
        telegramEnabled = defaults.bool(forKey: "telegramEnabled")
        telegramChats = Self.load([TelegramChat].self, from: defaults, forKey: "telegramChats") ?? []
        Task { [weak self, macName] in
            let name = await macName.value
            self?.thisMacName = name
        }
    }

    func account(_ id: String) -> Account { accounts.first { $0.id == id } ?? Accounts.account(id: id) }

    func command(for account: Account) -> String {
        let override = commands[account.id]?.trimmingCharacters(in: .whitespaces) ?? ""
        return override.isEmpty ? account.defaultCommand : override
    }

    func host(_ id: UUID?) -> SSHHost? {
        id.flatMap { id in hosts.first { $0.id == id } }
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, forKey key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    var expandedBotsRoot: String { (botsRoot as NSString).expandingTildeInPath }
    var expandedReposRoot: String { (reposRoot as NSString).expandingTildeInPath }
    var sharedMemoryPath: String { (expandedBotsRoot as NSString).appendingPathComponent(BotContext.memoryFile) }
    var teamPath: String { BotContext.teamPath(besideSharedMemory: sharedMemoryPath) }
}
