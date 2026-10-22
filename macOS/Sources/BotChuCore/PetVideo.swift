import Foundation

/// Pets, made the way Muse animates its character: a square still per state, drawn by Codex,
/// turned into a short looping clip by an image-to-video model on OpenRouter, with the still as
/// the clip's first and last frame so it loops without a seam. They play as video, at 24 frames a
/// second.
public enum PetVideo {
    /// The bot's `pet/` folder: `video.json`, `stills/<id>.png`, `clips/<id>.mp4`, and the
    /// appearance it was made from.
    public static let manifestFile = "video.json"
    public static let stillsFolder = "stills"
    public static let clipsFolder = "clips"
    public static let lastMessageFile = "last-message.txt"
    public static let appearanceFile = "appearance.txt"
    /// The character image a new pet keeps, copied into its folder while it is made.
    public static let referenceFile = "reference.png"
    /// The size clips are kept at, in pixels: an avatar is at most 128 points.
    public static let clipSide = 256

    public static func folder(for home: BotHome) -> URL { home.petURL }

    /// The image of the character a new pet should keep, when its appearance is the one the current
    /// pet was made from: the current pet's idle still, or the base image of a sprite pet drawn
    /// before video pets (recorded with its appearance, or starting the skill's own notes).
    public static func characterReference(appearance: String, pet folder: URL) -> URL? {
        let wanted = appearance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let files = FileManager.default
        let candidates = [folder.appendingPathComponent(stillsFolder).appendingPathComponent("idle.png"),
                          folder.appendingPathComponent("run/references/canonical-base.png")]
        guard let image = candidates.first(where: { files.fileExists(atPath: $0.path) }) else { return nil }
        if let made = try? String(contentsOf: folder.appendingPathComponent(appearanceFile), encoding: .utf8) {
            return made.trimmingCharacters(in: .whitespacesAndNewlines) == wanted ? image : nil
        }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("run/pet_request.json")),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notes = request["pet_notes"] as? String else { return nil }
        return notes.hasPrefix(wanted) ? image : nil
    }

    /// Where a video pet is made, beside the bot's pet, so its current pet stays until it's done.
    public static func stagingURL(for home: BotHome) -> URL {
        home.url.appendingPathComponent("pet-making", isDirectory: true)
    }

    /// A pose Codex draws, which one or more clips start and end on.
    public struct Still: Equatable, Sendable {
        public let id: String
        public let pose: String
    }

    public static let stills: [Still] = [
        Still(id: "idle", pose: "relaxed and content, looking at the viewer with a small smile, hands resting in front of it"),
        Still(id: "thinking", pose: "chin resting on one hand, eyes glancing up, thoughtful"),
        Still(id: "researching", pose: "holding an open book close with both hands and reading it; the book has no text"),
        Still(id: "browsing", pose: "holding a small tablet in both hands and looking at it; its screen is plain and light, with no text"),
        Still(id: "coding", pose: "sitting at an open silver laptop and wearing over-ear headphones, typing, eyes on the screen; the keyboard and the edge of the screen show at the lower right"),
        Still(id: "testing", pose: "leaning toward an open silver laptop with one finger on a key, watching the screen expectantly, no headphones; the keyboard and the edge of the screen show at the lower right"),
        Still(id: "working", pose: "holding a small wrench at chest height and tinkering with focus"),
        Still(id: "failed", pose: "a little deflated, shoulders slightly dropped, a small sad face"),
    ]

    /// One clip: the activity it shows (named after it, as `BotActivity.animations` names them), the
    /// still it starts and ends on, and the motion between.
    public struct Clip: Equatable, Sendable {
        public let id: String
        public let still: String
        public let seconds: Int
        /// False for a reaction that plays once and returns to idle.
        public let loops: Bool
        public let motion: String
    }

    public static let clips: [Clip] = [
        Clip(id: "idle", still: "idle", seconds: 5, loops: true,
             motion: "breathes slowly and blinks once, with the slightest tilt of the head; otherwise it stays still"),
        Clip(id: "greeting", still: "idle", seconds: 4, loops: false,
             motion: "raises one hand and waves hello, then lowers it back into the starting pose"),
        Clip(id: "thinking", still: "thinking", seconds: 5, loops: true,
             motion: "keeps its chin on its hand while its eyes drift up and back, with one slow blink"),
        Clip(id: "researching", still: "researching", seconds: 5, loops: true,
             motion: "reads the open book, its eyes moving along the lines, and turns one page gently"),
        Clip(id: "browsing", still: "browsing", seconds: 5, loops: true,
             motion: "scrolls the tablet slowly with one finger, its eyes following"),
        Clip(id: "coding", still: "coding", seconds: 5, loops: true,
             motion: "keeps typing on the laptop with small, gentle alternating finger taps, eyes on the screen, with a slow breath and one slow blink; the headphones stay on"),
        Clip(id: "testing", still: "testing", seconds: 5, loops: true,
             motion: "presses a key, watches the screen expectantly, then gives a small satisfied nod"),
        Clip(id: "working", still: "working", seconds: 5, loops: true,
             motion: "turns the small wrench a little at a time, focused, with one slow blink"),
        Clip(id: "failed", still: "failed", seconds: 5, loops: true,
             motion: "gives a small sigh, its shoulders sinking a little and rising again, with one slow sad blink"),
        Clip(id: "done", still: "idle", seconds: 4, loops: false,
             motion: "gives a small happy cheer, both arms up with a little bounce, then settles back into the starting pose"),
    ]

    /// The motion prompt for a clip.
    public static func motionPrompt(for clip: Clip) -> String {
        "The character \(clip.motion). Its movements are small and gentle; its head stays almost still unless the motion says otherwise. The camera is locked off: no zoom, pan or cut. The background stays plain off-white. It ends in exactly the starting pose."
    }

    /// An image-to-video model on OpenRouter that can pin both a clip's first and last frame.
    /// `dollarsPerSecond` is what a square clip cost when measured, for the estimate shown before
    /// making a pet; OpenRouter reports the real cost of each clip.
    public struct Model: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let resolution: String
        public let dollarsPerSecond: Double
    }

    public static let models: [Model] = [
        // Measured: $0.058 for a 5-second square clip (it comes back 640 × 640).
        Model(id: "bytedance/seedance-1-5-pro", name: "Seedance 1.5 Pro, 480p", resolution: "480p", dollarsPerSecond: 0.0116),
        // Measured: $0.42 for a 5-second square clip (960 × 960).
        Model(id: "kwaivgi/kling-v3.0-std", name: "Kling 3.0 Standard, 720p", resolution: "720p", dollarsPerSecond: 0.084),
    ]
    public static let defaultModel = models[0]

    public static func model(id: String) -> Model { models.first { $0.id == id } ?? defaultModel }

    /// What a full set of clips costs on `model`, in dollars, from its list price.
    public static func estimatedCost(_ model: Model, clips: [Clip] = clips) -> Double {
        Double(clips.reduce(0) { $0 + $1.seconds }) * model.dollarsPerSecond
    }

    /// The body of `POST /api/v1/videos` for one clip; `image` is the still as a data URI.
    public static func requestBody(model: Model, clip: Clip, image: String) throws -> Data {
        let frame = { (type: String) -> [String: Any] in
            ["type": "image_url", "image_url": ["url": image], "frame_type": type]
        }
        let body: [String: Any] = [
            "model": model.id, "prompt": motionPrompt(for: clip), "duration": clip.seconds,
            "resolution": model.resolution, "aspect_ratio": "1:1", "generate_audio": false,
            "frame_images": [frame("first_frame"), frame("last_frame")],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// A video job as OpenRouter reports it.
    public struct Job: Equatable, Sendable {
        public enum State: String, Sendable { case pending, inProgress = "in_progress", completed, failed, cancelled, expired }
        public var id: String
        public var state: State
        public var error: String?
        public var cost: Double?

        public var isFinished: Bool { state != .pending && state != .inProgress }

        public static func parse(_ data: Data) -> Job? {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let state = (object["status"] as? String).flatMap(State.init(rawValue:)) else { return nil }
            let error = (object["error"] as? String) ?? ((object["error"] as? [String: Any])?["message"] as? String)
            let usage = object["usage"] as? [String: Any]
            let cost = (usage?["cost"] as? Double) ?? (object["cost"] as? Double)
            return Job(id: id, state: state, error: error, cost: cost)
        }

        /// The message of an error response (a refused request), if it is one.
        public static func errorMessage(_ data: Data) -> String? {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let error = object["error"] as? [String: Any] { return error["message"] as? String }
            return object["error"] as? String
        }
    }

    /// Instructions for the Codex run that draws the stills into `folder/stills/`. `reference` is
    /// an image of the character to keep (its sprite pet's base), attached to the run.
    public static func stillsPrompt(petName: String, appearance: String, folder: String, reference: String?,
                                    stills: [Still] = stills) -> String {
        let dir = (folder as NSString).appendingPathComponent(stillsFolder)
        let character = reference.map {
            "The attached image (\($0)) is this character: draw exactly the same character, with the same face, colors, materials and proportions. Load it with view_image before the first image."
        } ?? "There is no reference image: design the character from the description, and keep it exactly the same in every image."
        let lines = stills.map { "- `\($0.id)`: \($0.pose)." }.joined(separator: "\n")
        return """
        Draw the stills for \(petName.trimmingCharacters(in: .whitespacesAndNewlines))'s video pet, for BotChu, a macOS app. Work in \(folder) without asking questions, and keep going until every still is done.

        The character, in the owner's words: \(appearance.trimmingCharacters(in: .whitespacesAndNewlines))
        \(character)

        Use your built-in image generation tool, one image per still, in the order below. Every image: one square image of the same character framed as a close portrait, the head and upper body filling most of the frame with the head near the top and centered; soft, even studio lighting; a plain seamless off-white background with no shadows on it; no text or logos. After `idle`, load \(dir)/idle.png with view_image and use it as the reference for every later image, so the character stays identical. A prop named in a pose belongs to that pose only.

        After each image, copy the generated file to \(dir)/<id>.png, creating the folder if needed.
        Stills:
        \(lines)

        Finish with one line per still: `still <id>=ok`, or `still <id>=failed: <reason>`.
        """
    }

    /// The stills a folder holds, by id.
    public static func stillsDrawn(in folder: URL, stills: [Still] = stills) -> [String] {
        let dir = folder.appendingPathComponent(stillsFolder)
        return stills.map(\.id).filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0).png").path) }
    }
}

/// `video.json`: the clips a video pet has.
public struct PetVideoManifest: Codable, Equatable, Sendable {
    public struct Clip: Codable, Equatable, Sendable {
        public var id: String
        public var still: String
        public var loops: Bool

        public init(id: String, still: String, loops: Bool) {
            self.id = id
            self.still = still
            self.loops = loops
        }
    }

    public var version: Int
    public var model: String
    public var createdAt: Date
    public var clips: [Clip]

    public init(version: Int = 1, model: String, createdAt: Date = Date(), clips: [Clip]) {
        self.version = version
        self.model = model
        self.createdAt = createdAt
        self.clips = clips
    }
}

/// A video pet on disk: its manifest, and the clips and stills that exist.
public struct PetVideoPackage: Equatable, Sendable {
    public var folder: URL
    public var manifest: PetVideoManifest

    public func clipURL(_ id: String) -> URL {
        folder.appendingPathComponent(PetVideo.clipsFolder).appendingPathComponent("\(id).mp4")
    }

    public func stillURL(_ id: String) -> URL {
        folder.appendingPathComponent(PetVideo.stillsFolder).appendingPathComponent("\(id).png")
    }

    /// The animations it can play, named as `BotActivity.animations` names them.
    public var available: Set<String> { Set(manifest.clips.map(\.id)) }

    public func clip(_ id: String) -> PetVideoManifest.Clip? { manifest.clips.first { $0.id == id } }

    /// The video pet in `folder`, with only the clips whose files exist; nil without an idle clip.
    public static func load(from folder: URL) -> PetVideoPackage? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(PetVideo.manifestFile)),
              var manifest = try? Store.decoder.decode(PetVideoManifest.self, from: data) else { return nil }
        var package = PetVideoPackage(folder: folder, manifest: manifest)
        manifest.clips = manifest.clips.filter { clip in
            FileManager.default.fileExists(atPath: package.clipURL(clip.id).path)
                && FileManager.default.fileExists(atPath: package.stillURL(clip.still).path)
        }
        package.manifest = manifest
        return package.available.contains("idle") ? package : nil
    }

    /// Writes the manifest for the clips in `folder`, and replaces the bot's video pet with it.
    public static func install(from staging: URL, model: String, into home: BotHome,
                               clips: [PetVideo.Clip] = PetVideo.clips) throws -> PetVideoManifest {
        let made = clips.filter {
            FileManager.default.fileExists(atPath: staging.appendingPathComponent(PetVideo.clipsFolder).appendingPathComponent("\($0.id).mp4").path)
        }
        guard made.contains(where: { $0.id == "idle" }) else { throw PetError("The idle clip wasn't made, so there is no pet.") }
        let manifest = PetVideoManifest(model: model, clips: made.map { .init(id: $0.id, still: $0.still, loops: $0.loops) })
        try Store.encoder.encode(manifest).write(to: staging.appendingPathComponent(PetVideo.manifestFile), options: .atomic)
        let files = FileManager.default
        let target = PetVideo.folder(for: home)
        // The pet it replaces (or a sprite pet from before video pets) goes to the Trash.
        if files.fileExists(atPath: target.path) { try files.trashItem(at: target, resultingItemURL: nil) }
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: staging, to: target)
        return manifest
    }
}

extension CommandBuilder {
    /// A one-off Codex run that isn't a chat turn (drawing a pet's stills): no session to resume,
    /// the last message written to `outputFile`, `images` attached to the prompt.
    public static func codexJob(prompt: String, outputFile: String, model: String? = nil, images: [String] = []) -> Invocation {
        // `-i` takes any number of files, so the images go before the other options: right before
        // the prompt, they would take the prompt as one more image, and Codex would wait for one on
        // stdin.
        var args = ["exec", "--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox"]
        for image in images { args += ["-i", image] }
        args += ["-o", outputFile]
        if let model, !model.trimmingCharacters(in: .whitespaces).isEmpty { args += ["-m", model] }
        args.append(prompt.hasPrefix("-") ? " " + prompt : prompt)
        return Invocation(arguments: args, environment: [:], sessionID: nil)
    }
}
