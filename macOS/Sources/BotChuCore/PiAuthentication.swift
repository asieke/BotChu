import Foundation

/// Pi's non-secret readiness command. A check neither refreshes OAuth nor asks for credentials.
/// Unknown, malformed and unavailable checks fail closed without exposing auth output.
public enum PiAuthentication {
    public static func problem(account: Account, providerID: String?, command: String,
                               machine: Machine = .thisMac, folder: String = NSHomeDirectory(),
                               openRouterKey: String? = nil, timeout: TimeInterval = 10) async -> String? {
        let provider = ModelProvider.effectiveID(providerID, runtime: .pi)!
        let environment = machine.isRemote ? [:] : account.runtime.adapter.profileEnvironment(
            account: account, providerID: provider, openRouterKey: openRouterKey)
        let unset = machine.isRemote ? [] : account.runtime.adapter.unsetEnvironment(account: account, providerID: provider)
        return await check(provider: provider, command: command, machine: machine, folder: folder,
                           environment: environment, unsetEnvironment: unset, timeout: timeout)
    }

    static func check(provider: String, command: String, machine: Machine, folder: String,
                      environment: [String: String], unsetEnvironment: [String], timeout: TimeInterval = 20) async -> String? {
        return await Task.detached(priority: .utility) {
            do {
                let process = try UsageProcess(command: command,
                    arguments: ["auth", "check", "--provider", provider, "--json", "--no-refresh"],
                    directory: URL(fileURLWithPath: machine.isRemote ? NSHomeDirectory() : folder),
                    environment: machine.isRemote ? [:] : environment,
                    unsetEnvironment: machine.isRemote ? [] : unsetEnvironment,
                    machine: machine, remoteFolder: folder, timeout: timeout, frameLimit: 64 << 10)
                defer { process.stop() }
                if let frame = try process.next() { return problem(frame, provider: provider) }
            } catch { }
            return unavailable(provider)
        }.value
    }

    private static func unavailable(_ provider: String) -> String {
        "Pi provider \(provider) is not ready. Sign in to this profile or configure its credentials."
    }

    static func problem(_ frame: [String: Any], provider: String) -> String? {
        guard frame["provider"] as? String == provider else { return unavailable(provider) }
        let name = ModelProvider(id: provider).name
        switch frame["status"] as? String {
        case "not_ready":
            if frame["reason"] as? String == "provider_not_found" {
                return "Pi does not recognize provider \(name). Check this profile's provider ID."
            }
            return "Sign in to \(name) in this Pi profile before starting a turn."
        case "invalid":
            return "Pi could not use the \(name) login. Sign in again in this profile."
        case "ready": return nil
        default: return unavailable(provider)
        }
    }
}
