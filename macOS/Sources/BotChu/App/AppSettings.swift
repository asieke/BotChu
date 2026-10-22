import Foundation
import Observation
import BotChuCore

/// Settings kept in `defaults` (domain `local.BotChu`); the OpenRouter key is in the Keychain.
@MainActor @Observable
final class AppSettings {
    private let defaults: UserDefaults

    var botsRoot: String { didSet { defaults.set(botsRoot, forKey: "botsRoot") } }
    /// Where the repositories tasks work in are checked out, one folder each (as GitChu puts them).
    var reposRoot: String { didSet { defaults.set(reposRoot, forKey: "reposRoot") } }
    var openRouterModel: String { didSet { defaults.set(openRouterModel, forKey: "openRouterModel") } }
    /// Command overrides by account id; a missing or empty entry means the account's default.
    var commands: [String: String] { didSet { defaults.set(commands, forKey: "commands") } }
    /// The Codex account that draws pets for bots that don't run on Codex themselves.
    var petAccountID: String { didSet { defaults.set(petAccountID, forKey: "petAccountID") } }
    /// The OpenRouter model that turns a pet's stills into clips.
    var petModelID: String { didSet { defaults.set(petModelID, forKey: "petModelID") } }
    /// Invalidates allowance readings when the saved OpenRouter key changes, without retaining it.
    var usageCredentialRevision = 0

    init(defaults: UserDefaults? = nil) {
        // Throwaway runs (DevHooks) keep their settings apart from the real ones.
        let defaults = defaults ?? (DevHooks.dataDir == nil ? .standard : UserDefaults(suiteName: "local.BotChu.dev")!)
        self.defaults = defaults
        if let dev = DevHooks.dataDir {
            botsRoot = dev.appendingPathComponent("bots").path
            reposRoot = dev.appendingPathComponent("repos").path
        } else {
            botsRoot = defaults.string(forKey: "botsRoot") ?? (NSHomeDirectory() as NSString).appendingPathComponent("BotChu")
            reposRoot = defaults.string(forKey: "reposRoot") ?? "~/Desktop/WORKSPACE"
        }
        openRouterModel = (DevHooks.dataDir != nil ? DevHooks.env["BOTCHU_DEFAULT_MODEL"] : nil)
            ?? defaults.string(forKey: "openRouterModel") ?? CommandBuilder.defaultOpenRouterModel
        commands = defaults.dictionary(forKey: "commands") as? [String: String] ?? [:]
        petAccountID = defaults.string(forKey: "petAccountID") ?? "codex-personal"
        petModelID = defaults.string(forKey: "petModelID") ?? PetVideo.defaultModel.id
    }

    func command(for account: Account) -> String {
        let override = commands[account.id]?.trimmingCharacters(in: .whitespaces) ?? ""
        return override.isEmpty ? account.defaultCommand : override
    }

    var expandedBotsRoot: String { (botsRoot as NSString).expandingTildeInPath }
    var expandedReposRoot: String { (reposRoot as NSString).expandingTildeInPath }
    var sharedMemoryPath: String { (expandedBotsRoot as NSString).appendingPathComponent(BotContext.memoryFile) }
}
