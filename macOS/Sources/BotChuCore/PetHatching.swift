import Foundation

/// Drawing a pet with Codex: one `codex exec` that follows the `hatch-pet` skill to make the atlas,
/// then draws BotChu's extra animations with the same skill's layout guides and frame extraction.
/// The run works in a staging folder; BotChu swaps it in for the bot's pet once it holds a pet.
public enum PetHatching {
    /// The folder a drawing works in, beside the bot's pet, so a failed or stopped drawing leaves
    /// the pet there as it was.
    public static func stagingURL(for home: BotHome) -> URL {
        home.url.appendingPathComponent("pet-drawing", isDirectory: true)
    }

    public static let runFolder = "run"
    public static let lastMessageFile = "last-message.txt"

    /// Where the `hatch-pet` skill may be for a Codex account, first match wins: the account's own
    /// Codex home (the profile wrappers set `CODEX_HOME=~/.<account id>`), then the shared places.
    public static func skillCandidates(accountID: String, home: String = NSHomeDirectory()) -> [String] {
        [".\(accountID)/skills/hatch-pet", ".agents/skills/hatch-pet", ".codex/skills/hatch-pet"]
            .map { (home as NSString).appendingPathComponent($0) }
    }

    /// Pythons that may have Pillow, which the skill's scripts need: Xcode's, Homebrew's, then the
    /// login shell's.
    public static let pythonCandidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]

    /// What to tell the owner when no Python with Pillow is found.
    public static let pillowHelp = "Drawing pets needs Python with Pillow. Install it with: /usr/bin/python3 -m pip install --user pillow"

    /// What to tell the owner when the skill is missing.
    public static func skillHelp(accountName: String) -> String {
        "Drawing pets needs Codex's hatch-pet skill, which \(accountName) doesn't have. Install it in Codex (Settings ▸ Pets ▸ Create pet), or with $skill-installer hatch-pet."
    }

    /// The instructions for the drawing run.
    public static func prompt(petName: String, appearance: String, skill: String, python: String, folder: String,
                              extras: [PetActivitySpec] = PetActivitySpec.all) -> String {
        let run = (folder as NSString).appendingPathComponent(runFolder)
        let name = petName.trimmingCharacters(in: .whitespacesAndNewlines)
        let look = appearance.trimmingCharacters(in: .whitespacesAndNewlines)
        let extraLines = extras.map { spec in
            "   - `\(spec.id)` (alias `\(spec.alias)`, \(spec.frames) frames): \(spec.prompt)"
        }.joined(separator: "\n")
        return """
        Draw an animated pet for BotChu, a macOS app, working in \(folder). Work without asking questions: choose sensible defaults and keep going until both parts are done.

        Part 1. Follow the hatch-pet skill at \(skill)/SKILL.md to hatch one pet, with these settings:
        - Pet name: \(name). Its look, in the owner's words: \(look)
        - No reference images. Style preset: auto.
        - Run folder: \(run) (pass it to prepare_pet_run.py as --output-dir).
        - load_workspace_dependencies is not available here. Set PYTHON=\(python) for every script; it has Pillow.
        - Use subagents for the image jobs if you can; otherwise generate each image yourself, one at a time.
        - BotChu uses only the nine standard rows (0-8). Skip all look-direction work (look-cardinals, rows 9 and 10, look mechanics) and package the validated 8x9 atlas that compose_atlas.py writes, with spriteVersionNumber 1.
        - BotChu shows these rows for its bot's work: `waiting` while it thinks (a quiet pondering pose, not asking for anything), `review` while it reads or looks something up (focused reading or scanning), `running` while it works (focused effort at a task). Write those rows' prompts to fit.
        - Package into this folder instead of $CODEX_HOME/pets: \(folder)/spritesheet.webp and \(folder)/pet.json with id, displayName, description, "spritesheetPath": "spritesheet.webp" and "spriteVersionNumber": 1.
        - Keep the run folder's qa/ files; skip the cleanup step.

        Part 2. Draw BotChu's extra animations, one at a time, each like a standard row strip grounded in the canonical base. For each extra below:
        1. Write its prompt to \(run)/extras/<id>/prompt.md: the skill's row prompt for its alias row (same identity lock, frame count, invisible slots, chroma key from \(run)/pet_request.json, and the same rules against text, scenery, shadows and detached effects), with the action below in place of the alias row's action. The props an action names (book, tablet, laptop, desk, wrench) are allowed for that animation only; they touch the pet and stay inside its slot.
        2. Generate the strip, attaching \(run)/references/canonical-base.png for identity and \(run)/references/layout-guides/<alias>.png for layout only. Copy the chosen image to \(run)/extras/<id>/decoded/<alias>.png.
        3. Run: "$PYTHON" "\(skill)/scripts/extract_strip_frames.py" --decoded-dir \(run)/extras/<id>/decoded --output-dir \(run)/extras/<id>/frames --states <alias> --chroma-key <the chroma key hex in pet_request.json> --method auto
        4. Check that the frames show the same pet doing the action (render_animation_previews.py --frames-root \(run)/extras/<id>/frames --output-dir \(run)/extras/<id>/previews helps). Regenerate once if the identity or the action is wrong; if it is still wrong, skip that extra.
        5. Copy \(run)/extras/<id>/frames/<alias>/00.png, 01.png, … to \(folder)/activities/<id>/ with the same names.
        Extras:
        \(extraLines)

        Finish with one line per result: `pet=<path to pet.json>`, then `extra <id>=ok` or `extra <id>=skipped: <reason>`.
        """
    }

    /// How far a drawing has got, from the skill's job manifest and the extras' frames.
    public struct Progress: Equatable, Sendable {
        public var done: Int
        public var total: Int
        /// The image being drawn: a job id (`base`, an atlas row) or an extra's id.
        public var current: String?

        public init(done: Int, total: Int, current: String?) {
            self.done = done
            self.total = total
            self.current = current
        }
    }

    public static func progress(folder: URL, extras: [PetActivitySpec] = PetActivitySpec.all) -> Progress {
        let run = folder.appendingPathComponent(runFolder)
        var jobs: [(id: String, complete: Bool)] = []
        if let data = try? Data(contentsOf: run.appendingPathComponent("imagegen-jobs.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = object["jobs"] as? [[String: Any]] {
            jobs = list.compactMap { job in
                guard let id = job["id"] as? String, !id.hasPrefix("look") else { return nil }
                return (id, (job["status"] as? String) == "complete")
            }
        }
        // Before the skill writes its manifest: the base and the nine rows.
        let standard = jobs.isEmpty ? 1 + PetAtlas.rows.count : jobs.count
        let extrasDone = extras.map { spec in hasFrames(spec, in: folder) }
        let done = jobs.filter(\.complete).count + extrasDone.filter { $0 }.count
        let current = jobs.isEmpty ? "base" : jobs.first(where: { !$0.complete })?.id
            ?? zip(extras, extrasDone).first(where: { !$0.1 })?.0.id
        return Progress(done: done, total: standard + extras.count, current: current)
    }

    static func hasFrames(_ spec: PetActivitySpec, in folder: URL) -> Bool {
        let dir = folder.appendingPathComponent(PetPackage.activitiesFolder).appendingPathComponent(spec.id)
        return (0..<spec.frames).allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(String(format: "%02d.png", $0)).path)
        }
    }

    /// Writes `activities.json` for the extras whose frames the run left, and returns it.
    @discardableResult
    public static func recordActivities(in folder: URL, extras: [PetActivitySpec] = PetActivitySpec.all) throws -> PetActivitiesManifest {
        let manifest = PetActivitiesManifest(activities: extras.filter { hasFrames($0, in: folder) }.map {
            .init(id: $0.id, frames: $0.frames, durations: $0.durations)
        })
        try Store.encoder.encode(manifest).write(to: folder.appendingPathComponent(PetPackage.activitiesFile), options: .atomic)
        return manifest
    }

    /// Replaces the bot's pet with the drawing in `staging`; the old pet goes to the Trash.
    public static func install(from staging: URL, into home: BotHome) throws {
        let files = FileManager.default
        if files.fileExists(atPath: home.petURL.path) {
            try files.trashItem(at: home.petURL, resultingItemURL: nil)
        }
        try files.moveItem(at: staging, to: home.petURL)
    }
}

extension CommandBuilder {
    /// A one-off Codex run that isn't a chat turn (drawing a pet): no session to resume, the last
    /// message written to `outputFile`.
    public static func codexJob(prompt: String, outputFile: String, model: String? = nil) -> Invocation {
        var args = ["exec", "--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox",
                    "-o", outputFile]
        if let model, !model.trimmingCharacters(in: .whitespaces).isEmpty { args += ["-m", model] }
        args.append(prompt.hasPrefix("-") ? " " + prompt : prompt)
        return Invocation(arguments: args, environment: [:], sessionID: nil)
    }
}
