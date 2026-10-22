import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import BotChuCore

/// A pet being made for a bot: Codex draws its stills, then OpenRouter turns each into a clip.
struct PetJob: Equatable {
    enum Phase: Equatable {
        case checking
        case drawingStills(done: Int, total: Int)
        case animating(done: Int, total: Int)
        case failed(String)
    }

    var phase: Phase
    var startedAt = Date()
    /// Dollars OpenRouter has reported so far.
    var cost: Double = 0

    var isActive: Bool {
        if case .failed = phase { return false }
        return true
    }

    var summary: String {
        switch phase {
        case .checking: "Getting ready…"
        case let .drawingStills(done, total): "Drawing stills (\(min(done + 1, total)) of \(total))…"
        case let .animating(done, total):
            "Animating clips (\(done) of \(total) done)" + (cost > 0 ? String(format: ", $%.2f so far…", cost) : "…")
        case .failed(let reason): reason
        }
    }
}

extension AppModel {
    /// The Codex account that draws a bot's stills: its own when it runs on Codex, else the one in Settings.
    func petAccount(for bot: Bot) -> Account {
        bot.account.kind == .codex ? bot.account : Accounts.account(id: settings.petAccountID)
    }

    /// Saves a bot's appearance (the editor's text) without the rest of the editor's changes.
    func setAppearance(_ text: String, for id: UUID) {
        guard let i = bots.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        bots[i].appearance = trimmed.isEmpty ? nil : trimmed
        save(bots[i])
    }

    /// The video model in Settings, and what a full set of clips costs on it.
    var petModel: PetVideo.Model { PetVideo.model(id: settings.petModelID) }

    /// Makes the bot's pet in the background: Codex draws a still per state (on the pet
    /// account, from its current pet's look when its appearance hasn't changed), then OpenRouter makes a
    /// looping clip from each. Stills already drawn by a stopped or failed attempt are reused.
    func makePet(_ id: UUID) {
        guard let bot = bot(id), petJobs[id]?.isActive != true else { return }
        let appearance = bot.appearance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !appearance.isEmpty else {
            petJobs[id] = PetJob(phase: .failed("Describe how the bot looks first."))
            return
        }
        guard let key = Keychain.get(Keychain.openRouterAccount), !key.isEmpty else {
            petJobs[id] = PetJob(phase: .failed("Pets are animated on OpenRouter. Add your OpenRouter API key in BotChu ▸ Settings first."))
            return
        }
        let home = BotHome(workspace: bot.workspace)
        let staging = PetVideo.stagingURL(for: home)
        let files = FileManager.default
        let allStills = PetVideo.stills.map(\.id)
        let resuming = PetVideo.stillsDrawn(in: staging) == allStills
            && (try? String(contentsOf: staging.appendingPathComponent(PetVideo.appearanceFile), encoding: .utf8)) == appearance
        if resuming {
            animatePet(id, key: key, staging: staging, home: home)
            return
        }
        let reference = staging.appendingPathComponent(PetVideo.referenceFile)
        let keeping = PetVideo.characterReference(appearance: appearance, pet: PetVideo.folder(for: home))
        do {
            if files.fileExists(atPath: staging.path) { try files.trashItem(at: staging, resultingItemURL: nil) }
            try files.createDirectory(at: staging.appendingPathComponent(PetVideo.stillsFolder), withIntermediateDirectories: true)
            if let keeping { try files.copyItem(at: keeping, to: reference) }
            try appearance.write(to: staging.appendingPathComponent(PetVideo.appearanceFile), atomically: true, encoding: .utf8)
        } catch {
            petJobs[id] = PetJob(phase: .failed("Couldn't prepare \(staging.path): \(error.localizedDescription)"))
            return
        }

        let account = petAccount(for: bot)
        let prompt = PetVideo.stillsPrompt(petName: bot.name, appearance: appearance, folder: staging.path,
                                           reference: keeping == nil ? nil : reference.path)
        let lastMessage = staging.appendingPathComponent(PetVideo.lastMessageFile)
        let invocation = CommandBuilder.codexJob(prompt: prompt, outputFile: lastMessage.path,
                                                 images: keeping == nil ? [] : [reference.path])
        let command = settings.command(for: account)
        let run = AgentRun(command: command, invocation: invocation, directory: staging)
        let startedAt = Date()
        let total = allStills.count
        var parser = StreamParsers.make(for: .codex)
        var toolCalls = 0
        run.onLines = { lines in
            for line in lines { for event in parser.parse(line: line) { if case .toolStarted = event { toolCalls += 1 } } }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.petRuns[id] === run else { return }
                let phase = PetJob.Phase.drawingStills(done: PetVideo.stillsDrawn(in: staging).count, total: total)
                if self.petJobs[id]?.phase != phase { self.petJobs[id]?.phase = phase }
            }
        }
        run.onExit = { [weak self, weak run] status, stderr in
            timer.invalidate()
            guard let self else { return }
            self.petRuns[id] = nil
            let stopped = run?.stopped == true
            let drawn = PetVideo.stillsDrawn(in: staging)
            var error: String?
            if stopped {
                self.petJobs[id] = nil
            } else if !drawn.contains("idle") {
                let said = (try? String(contentsOf: lastMessage, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                error = "Codex didn't draw the stills (exit \(status))." + (said.isEmpty ? "" : " \(said)")
            }
            try? home.appendLog(TurnLog.ended(at: Date(), startedAt: startedAt, status: status, stopped: stopped,
                                              toolCalls: toolCalls, error: error, stderr: stderr, what: "pet stills"))
            if let error {
                self.petJobs[id] = PetJob(phase: .failed(error))
            } else if !stopped {
                self.animatePet(id, key: key, staging: staging, home: home)
            }
        }
        do {
            try? home.appendLog(TurnLog.started(at: startedAt, account: account, command: command,
                                                arguments: invocation.arguments, prompt: prompt, resuming: nil,
                                                what: "pet stills"))
            try run.start()
            petRuns[id] = run
            petJobs[id] = PetJob(phase: .drawingStills(done: 0, total: total), startedAt: startedAt)
        } catch {
            timer.invalidate()
            petJobs[id] = PetJob(phase: .failed("Couldn't start \(account.name): \(error.localizedDescription)"))
        }
    }

    /// Stops waiting for a pet. Clips already started on OpenRouter still finish there and
    /// are charged; the stills stay, so the next attempt starts from them.
    func cancelPet(_ id: UUID) {
        if let run = petRuns[id] { run.stop() }
        petTasks.removeValue(forKey: id)?.cancel()
        petJobs[id] = nil
    }

    func dismissPet(_ id: UUID) {
        if petJobs[id]?.isActive == false { petJobs[id] = nil }
    }

    /// Turns the stills in `staging` into clips on OpenRouter, all at once, then installs them.
    private func animatePet(_ id: UUID, key: String, staging: URL, home: BotHome) {
        let model = petModel
        let drawn = Set(PetVideo.stillsDrawn(in: staging))
        let clips = PetVideo.clips.filter { drawn.contains($0.still) }
        let startedAt = petJobs[id]?.startedAt ?? Date()
        petJobs[id] = PetJob(phase: .animating(done: 0, total: clips.count), startedAt: startedAt)
        try? home.appendLog("── \(Self.logTime()) · pet clips started · OpenRouter \(model.id) · \(clips.count) clips, "
            + String(format: "about $%.2f\n", PetVideo.estimatedCost(model, clips: clips)))
        let client = OpenRouterVideos(key: key)
        petTasks[id] = Task { [weak self] in
            var images: [String: String] = [:]
            for still in Set(clips.map(\.still)) {
                images[still] = Self.dataURI(jpegOf: staging.appendingPathComponent(PetVideo.stillsFolder).appendingPathComponent("\(still).png"))
            }
            var failures: [String] = []
            await withTaskGroup(of: (String, Double, String?).self) { group in
                for clip in clips {
                    guard let image = images[clip.still] else { failures.append("\(clip.id): couldn't read its still"); continue }
                    group.addTask {
                        do {
                            let file = staging.appendingPathComponent(PetVideo.clipsFolder).appendingPathComponent("\(clip.id).mp4")
                            let cost = try await Self.makeClip(clip, model: model, image: image, client: client, to: file)
                            return (clip.id, cost, nil)
                        } catch {
                            return (clip.id, 0, error.localizedDescription)
                        }
                    }
                }
                var done = 0
                for await (clipID, cost, error) in group {
                    done += 1
                    if let error { failures.append("\(clipID): \(error)") }
                    try? home.appendLog("── \(Self.logTime()) · pet clip \(clipID) "
                        + (error.map { "failed · \($0)" } ?? String(format: "made · $%.2f", cost)) + "\n")
                    await MainActor.run { [weak self] in
                        guard let self, var job = self.petJobs[id], job.isActive else { return }
                        job.cost += cost
                        job.phase = .animating(done: done, total: clips.count)
                        self.petJobs[id] = job
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled, self.bot(id) != nil else { return }
                self.petTasks[id] = nil
                let cost = self.petJobs[id]?.cost ?? 0
                do {
                    let manifest = try PetVideoPackage.install(from: staging, model: model.id, into: home)
                    try? home.appendLog("── \(Self.logTime()) · pet installed · \(manifest.clips.count) clips · "
                        + String(format: "$%.2f", cost) + (failures.isEmpty ? "" : " · missing: \(failures.joined(separator: "; "))") + "\n\n")
                    self.reloadPet(id)
                    self.react(.greeting, for: self.tab(of: id), seconds: 4)
                    self.petJobs[id] = failures.isEmpty ? nil
                        : PetJob(phase: .failed("Made \(manifest.clips.count) of \(clips.count) clips; the rest fall back to the closest one. " + failures.joined(separator: "; ")))
                } catch {
                    try? home.appendLog("── \(Self.logTime()) · pet failed · \(error.localizedDescription)\n\n")
                    self.petJobs[id] = PetJob(phase: .failed("\(error.localizedDescription) " + failures.joined(separator: "; ")))
                }
            }
        }
    }

    /// Submits one clip, waits for it (up to 20 minutes), and downloads it. Returns its cost. Each
    /// request is repeated when it fails for a passing reason (`OpenRouterVideos.retrying`), so a
    /// server hiccup neither loses a clip nor drops one OpenRouter is still making, and charging for.
    nonisolated private static func makeClip(_ clip: PetVideo.Clip, model: PetVideo.Model, image: String,
                                             client: OpenRouterVideos, to file: URL) async throws -> Double {
        let body = try PetVideo.requestBody(model: model, clip: clip, image: image)
        var job = try await OpenRouterVideos.retrying { try await client.submit(body) }
        let deadline = Date().addingTimeInterval(20 * 60)
        while !job.isFinished {
            guard Date() < deadline else { throw PetError("it took more than 20 minutes") }
            try await Task.sleep(for: .seconds(10))
            let id = job.id
            job = try await OpenRouterVideos.retrying { try await client.status(of: id) }
        }
        guard job.state == .completed else { throw PetError("\(job.state.rawValue)\(job.error.map { ": \($0)" } ?? "")") }
        let id = job.id
        try await OpenRouterVideos.retrying { try await client.download(id, to: file) }
        await shrink(file, to: PetVideo.clipSide)
        return job.cost ?? 0
    }

    /// Scales a clip down to `side` × `side` pixels (cropping the middle of a clip that isn't
    /// square), so a pet takes little room; the models' smallest clips are 480 or 640 pixels. A clip
    /// that can't be scaled stays as it was.
    nonisolated static func shrink(_ file: URL, to side: Int) async {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let duration = try? await asset.load(.duration),
              min(natural.width, natural.height) > CGFloat(side) else { return }
        let rate = (try? await track.load(.nominalFrameRate)) ?? 24
        let scale = CGFloat(side) / min(natural.width, natural.height)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: (CGFloat(side) - natural.width * scale) / 2,
                                             y: (CGFloat(side) - natural.height * scale) / 2)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: side, height: side)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, rate.rounded())))
        composition.instructions = [instruction]
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return }
        let smaller = file.deletingPathExtension().appendingPathExtension("small.mp4")
        try? FileManager.default.removeItem(at: smaller)
        export.outputURL = smaller
        export.outputFileType = .mp4
        export.videoComposition = composition
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { done.resume() }
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: smaller)
            return
        }
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: smaller)
    }

    /// A still as a JPEG data URI, at most 768 pixels on a side: enough for the 480p and 720p models.
    nonisolated static func dataURI(jpegOf url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 768,
                  kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }

    nonisolated static func logTime() -> String {
        ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
    }
}
