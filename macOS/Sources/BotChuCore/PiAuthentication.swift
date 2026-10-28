import Foundation

/// Pi's non-secret readiness command. A check neither refreshes OAuth nor asks for credentials.
/// Older wrappers without this command remain usable: their turn handles authentication itself.
public enum PiAuthentication {
    public static func problem(account: Account, providerID: String?, command: String,
                               machine: Machine = .thisMac, folder: String = NSHomeDirectory(),
                               openRouterKey: String? = nil, timeout: TimeInterval = 10) async -> String? {
        let provider = ModelProvider.effectiveID(providerID, runtime: .pi)!
        let environment = machine.isRemote ? [:] : account.runtime.adapter.profileEnvironment(
            account: account, providerID: provider, openRouterKey: openRouterKey)
        let unset = machine.isRemote ? [] : account.runtime.adapter.unsetEnvironment(account: account, providerID: provider)
        return await Task.detached(priority: .utility) {
            do {
                let process = try UsageProcess(command: command,
                    arguments: ["auth", "check", "--provider", provider, "--json", "--no-refresh"],
                    directory: URL(fileURLWithPath: folder), environment: environment, unsetEnvironment: unset,
                    machine: machine, remoteFolder: folder, timeout: timeout, frameLimit: 64 << 10)
                defer { process.stop() }
                guard let frame = try process.next() else { return nil as String? }
                return problem(frame, provider: provider)
            } catch {
                // No raw output reaches a conversation. Pi's actual turn reports an unavailable
                // command/host or an older CLI's auth failure through its normal error handling.
                return nil
            }
        }.value
    }

    static func problem(_ frame: [String: Any], provider: String) -> String? {
        guard frame["provider"] as? String == provider else { return nil }
        let name = ModelProvider(id: provider).name
        switch frame["status"] as? String {
        case "not_ready":
            if frame["reason"] as? String == "provider_not_found" {
                return "Pi does not recognize provider \(name). Check this profile's provider ID."
            }
            return "Sign in to \(name) in this Pi profile before starting a turn."
        case "invalid":
            return "Pi could not use the \(name) login. Sign in again in this profile."
        default: return nil
        }
    }
}
