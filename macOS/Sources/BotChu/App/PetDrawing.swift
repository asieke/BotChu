import Foundation
import ImageIO
import BotChuCore

/// A pet being drawn for a bot by Codex, with the `hatch-pet` skill (`PetHatching`).
struct PetDrawing: Equatable {
    enum Phase: Equatable {
        case checking
        case drawing(PetHatching.Progress)
        case failed(String)
    }

    var phase: Phase
    var startedAt = Date()

    var isActive: Bool {
        if case .failed = phase { return false }
        return true
    }

    /// One line for the editor and the status sidebar.
    var summary: String {
        switch phase {
        case .checking: "Getting ready to draw…"
        case .drawing(let progress):
            "Drawing \(Self.name(of: progress.current)) (\(min(progress.done + 1, progress.total)) of \(progress.total))…"
        case .failed(let reason): reason
        }
    }

    static func name(of job: String?) -> String {
        switch job {
        case nil: "the finishing touches"
        case "base": "its main look"
        case let job?: job.replacingOccurrences(of: "-", with: " ")
        }
    }
}

extension AppModel {
    /// The Codex account that draws a bot's pet: its own when it runs on Codex, else the one in Settings.
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

    /// Draws the bot's pet from its appearance, in the background. Chat goes on meanwhile; the pet
    /// it has now stays until the new one is done.
    func drawPet(_ id: UUID) {
        guard let bot = bot(id), petDrawings[id]?.isActive != true else { return }
        let appearance = bot.appearance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !appearance.isEmpty else {
            petDrawings[id] = PetDrawing(phase: .failed("Describe how the bot looks first."))
            return
        }
        let account = petAccount(for: bot)
        petDrawings[id] = PetDrawing(phase: .checking)
        Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            let skill = PetHatching.skillCandidates(accountID: account.id)
                .first { files.fileExists(atPath: ($0 as NSString).appendingPathComponent("SKILL.md")) }
            let python = PetHatching.pythonCandidates.first(where: Self.hasPillow)
            await MainActor.run {
                guard self.petDrawings[id]?.phase == .checking else { return }
                guard let skill else {
                    self.petDrawings[id] = PetDrawing(phase: .failed(PetHatching.skillHelp(accountName: account.name)))
                    return
                }
                guard let python else {
                    self.petDrawings[id] = PetDrawing(phase: .failed(PetHatching.pillowHelp))
                    return
                }
                self.startDrawing(id, account: account, skill: skill, python: python, appearance: appearance)
            }
        }
    }

    func cancelPetDrawing(_ id: UUID) {
        if let run = petRuns[id] {
            run.stop()
        } else {
            petDrawings[id] = nil
        }
    }

    func dismissPetDrawing(_ id: UUID) {
        if petDrawings[id]?.isActive == false { petDrawings[id] = nil }
    }

    private func startDrawing(_ id: UUID, account: Account, skill: String, python: String, appearance: String) {
        guard let bot = bot(id) else { return }
        let home = BotHome(workspace: bot.workspace)
        let staging = PetHatching.stagingURL(for: home)
        let files = FileManager.default
        // A redraw with the same appearance keeps the pet's look: its base image is reused.
        let keptBase = staging.appendingPathComponent(PetHatching.keptBaseFile)
        let keeping = PetHatching.baseToKeep(appearance: appearance, pet: home.petURL)
        do {
            // A drawing that failed before is kept for a look until the next one starts.
            if files.fileExists(atPath: staging.path) { try files.trashItem(at: staging, resultingItemURL: nil) }
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            if let keeping { try files.copyItem(at: keeping, to: keptBase) }
            try appearance.write(to: staging.appendingPathComponent(PetHatching.appearanceFile), atomically: true, encoding: .utf8)
        } catch {
            petDrawings[id] = PetDrawing(phase: .failed("Couldn't prepare \(staging.path): \(error.localizedDescription)"))
            return
        }
        let prompt = PetHatching.prompt(petName: bot.name, appearance: appearance, skill: skill, python: python,
                                        folder: staging.path, keptBase: keeping == nil ? nil : keptBase.path)
        let lastMessage = staging.appendingPathComponent(PetHatching.lastMessageFile)
        let invocation = CommandBuilder.codexJob(prompt: prompt, outputFile: lastMessage.path)
        let command = settings.command(for: account)
        let run = AgentRun(command: command, invocation: invocation, directory: staging)
        let startedAt = Date()
        var parser = StreamParsers.make(for: .codex)
        var toolCalls = 0
        var failures: [String] = []

        run.onLines = { lines in
            for line in lines {
                for event in parser.parse(line: line) {
                    switch event {
                    case .toolStarted: toolCalls += 1
                    case .failed(let reason): failures.append(reason)
                    default: break
                    }
                }
            }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.petRuns[id] === run else { return }
                let progress = PetHatching.progress(folder: staging)
                if self.petDrawings[id]?.phase != .drawing(progress) {
                    self.petDrawings[id]?.phase = .drawing(progress)
                }
            }
        }
        run.onExit = { [weak self, weak run] status, stderr in
            timer.invalidate()
            guard let self else { return }
            self.petRuns[id] = nil
            let stopped = run?.stopped == true
            var error: String?
            if stopped {
                self.petDrawings[id] = nil
            } else if self.bot(id)?.workspace != bot.workspace {
                error = "The bot's folder moved while its pet was drawn. Draw it again."
            } else if let pet = PetPackage.load(from: staging), Self.isAtlas(pet.sheetURL) {
                do {
                    try PetHatching.recordActivities(in: staging)
                    try PetHatching.install(from: staging, into: home)
                    self.petDrawings[id] = nil
                    self.reloadPet(id)
                    self.react(.greeting, for: id, seconds: 2)
                } catch let failure {
                    error = "Couldn't use the new pet: \(failure.localizedDescription)"
                }
            } else {
                let said = (try? String(contentsOf: lastMessage, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let detail = failures.last ?? (said.isEmpty ? Self.lastLines(stderr, count: 3) : said)
                error = "Codex finished without a pet (exit \(status))." + (detail.isEmpty ? "" : " \(detail)")
            }
            if let error { self.petDrawings[id] = PetDrawing(phase: .failed(error)) }
            try? home.appendLog(TurnLog.ended(at: Date(), startedAt: startedAt, status: status, stopped: stopped,
                                              toolCalls: toolCalls, error: error, stderr: stderr, what: "pet drawing"))
        }

        do {
            try? home.appendLog(TurnLog.started(at: startedAt, account: account, command: command,
                                                arguments: invocation.arguments, prompt: prompt, resuming: nil,
                                                what: "pet drawing"))
            try run.start()
            petRuns[id] = run
            petDrawings[id] = PetDrawing(phase: .drawing(PetHatching.progress(folder: staging)), startedAt: startedAt)
        } catch {
            timer.invalidate()
            petDrawings[id] = PetDrawing(phase: .failed("Couldn't start \(account.name): \(error.localizedDescription)"))
        }
    }

    /// Whether a Python can import Pillow, which the skill's scripts need.
    nonisolated static func hasPillow(_ python: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import PIL"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Whether an image is a pet atlas, from its header alone.
    nonisolated static func isAtlas(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return PetAtlas.isValidSize(width: width, height: height)
    }
}
