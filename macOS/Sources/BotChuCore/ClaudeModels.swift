import Foundation

/// Claude Code's `initialize` control response lists the profile's models and their capabilities
/// (#326). This is its stream-json control protocol: one control request, then end of input, with
/// no user message, so no model turn starts, and every tool, MCP server and customization off.
public enum ClaudeModelList {
    static let arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                            "--no-session-persistence", "--safe-mode", "--tools", "", "--disallowedTools", "*",
                            "--strict-mcp-config", "--disable-slash-commands", "--permission-mode", "dontAsk"]
    static let requestID = "botchu-models"

    /// The rows of `models`, in Claude Code's order. `value` is what is sent as `--model`. An alias
    /// (`opus`) names no version and resolves to another ID, so it moves with new versions, and that
    /// pin follows it unless the list has it already; an ID that names its version stays put, also
    /// in its 1M-context form (`claude-fable-5-1[1m]`). The `default` row is the account's own
    /// choice, which the picker's "Use account default" already is. Efforts are the levels a row
    /// reports, none when it reports none.
    public static func parse(_ result: [String: Any]) throws -> [ModelOption] {
        guard let rows = result["models"] as? [[String: Any]] else { throw ModelListFailure.unsupported("Claude Code") }
        let listed = Set(rows.compactMap { text($0["value"]) })
        var models: [ModelOption] = []
        var seen = Set<String>()
        for row in rows {
            guard let id = text(row["value"]), id != "default", seen.insert(id).inserted else { continue }
            let resolved = text(row["resolvedModel"])
            let moving = GenerationOptions.claudeName(id) == nil && resolved.map { $0 != id } ?? false
            let reported = text(row["displayName"]) ?? GenerationOptions.claudeName(resolved ?? id) ?? id
            var name = reported.hasPrefix("Claude ") ? reported : "Claude \(reported)"
            if id.lowercased().hasSuffix("[1m]"), !name.contains("1M") { name += " (1M context)" }
            var efforts: [ReasoningEffort] = []
            if row["supportsEffort"] as? Bool != false {
                for effort in (row["supportedEffortLevels"] as? [String] ?? []).compactMap(ReasoningEffort.init)
                where !efforts.contains(effort) { efforts.append(effort) }
            }
            // An alias names no version until a turn reports the one it ran; its pin keeps the version.
            let aliasName = name.replacingOccurrences(of: #"\s+\d+(?:\.\d+)*(?=\s|$)"#, with: "", options: .regularExpression)
            models.append(ModelOption(id: id, name: moving ? aliasName : name, efforts: efforts, moving: moving))
            if moving, let resolved, resolved != "default", !listed.contains(resolved), seen.insert(resolved).inserted {
                models.append(ModelOption(id: resolved, name: name, efforts: efforts))
            }
        }
        guard !models.isEmpty else { throw ModelListFailure.unrecognized("Claude Code") }
        return models
    }

    /// The `initialize` answer among `output`'s lines: other frames (`system`) are skipped.
    static func result(in output: Data) throws -> [String: Any] {
        for line in output.split(separator: 10) {
            guard let frame = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  frame["type"] as? String == "control_response",
                  let response = frame["response"] as? [String: Any], response["request_id"] as? String == requestID else { continue }
            guard response["subtype"] as? String == "success" else { throw ModelListFailure.unsupported("Claude Code") }
            guard let result = response["response"] as? [String: Any] else { throw ModelListFailure.unrecognized("Claude Code") }
            return result
        }
        throw ModelListFailure.unrecognized("Claude Code")
    }

    /// The profile's models, run from `folder` (the home folder), or on `machine` from its own.
    public static func list(command: String, machine: Machine = .thisMac, folder: String = NSHomeDirectory(),
                            timeout: TimeInterval = NativeModelList.timeout) async throws -> [ModelOption] {
        try await NativeModelList.run("Claude Code", command: command, arguments: arguments, machine: machine,
                                      folder: folder, timeout: timeout) { process in
            try process.send(["type": "control_request", "request_id": requestID, "request": ["subtype": "initialize"]])
            // Ends input, so Claude Code exits after answering; the whole output is bounded.
            return try parse(result(in: process.output()))
        }
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// `agy models` (Antigravity 1.4.10, #326): a line per model and effort, `<id>\t<name> (<Effort>)`,
/// read from the profile's own sign-in without a turn. Each family is one choice, by its medium
/// variant as the starters are, with the efforts it lists; `--effort` picks the variant to run
/// (`GenerationOptions.modelArgument`).
public enum AntigravityModelList {
    static let efforts: [ReasoningEffort] = [.low, .medium, .high]

    public static func parse(_ output: String) throws -> [ModelOption] {
        struct Family { var id: String; var name: String; var efforts: [ReasoningEffort] }
        var families: [Family] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2, !fields[0].isEmpty, !fields[0].contains(" ") else { continue }
            let id = fields[0]
            let effort = efforts.first { id.hasSuffix("-" + $0.rawValue) }
            var name = fields[1].isEmpty ? id : fields[1]
            if let effort, name.lowercased().hasSuffix("(\(effort.rawValue))") {
                name = name.dropLast(effort.rawValue.count + 2).trimmingCharacters(in: .whitespaces)
            }
            if let i = families.firstIndex(where: { family(of: $0.id) == family(of: id) }) {
                if let effort, !families[i].efforts.contains(effort) {
                    families[i].efforts.append(effort)
                    if effort == .medium { families[i].id = id }
                }
            } else {
                families.append(Family(id: id, name: name, efforts: effort.map { [$0] } ?? []))
            }
        }
        let models = families.map { family in
            ModelOption(id: family.id, name: family.name, efforts: efforts.filter(family.efforts.contains))
        }
        guard !models.isEmpty else { throw ModelListFailure.unrecognized("Antigravity") }
        return models
    }

    /// A variant's family: its ID without the effort suffix.
    static func family(of id: String) -> String {
        efforts.first { id.hasSuffix("-" + $0.rawValue) }.map { String(id.dropLast($0.rawValue.count + 1)) } ?? id
    }

    /// The profile's models, run from `folder` (the home folder), or on `machine` from its own.
    public static func list(command: String, machine: Machine = .thisMac, folder: String = NSHomeDirectory(),
                            timeout: TimeInterval = NativeModelList.timeout) async throws -> [ModelOption] {
        try await NativeModelList.run("Antigravity", command: command, arguments: ["models"], machine: machine,
                                      folder: folder, timeout: timeout) { process in
            try parse(String(decoding: process.output(), as: UTF8.self))
        }
    }
}
