import AppKit
import SwiftUI
import BotChuCore

/// Environment variables for checking the app without touching real data or needing screen-recording
/// permission (see `macOS/ui-review.sh`):
/// - `BOTCHU_DATA_DIR`: keep the bot index and bot folders under this folder instead, with settings in
///   their own `defaults` domain (`local.BotChu.dev`), so a throwaway run never changes the real ones.
/// - `BOTCHU_SNAPSHOT`: write a PNG of each window into this folder every second, and of the sidebar's
///   rows (`sidebar.png`), which the window's picture leaves out.
/// - `BOTCHU_OPEN`: open `editor` (a new bot), `task` (New Task for the selected bot) or `settings` at launch.
/// - `BOTCHU_APPEARANCE`: use `light` or `dark` for an isolated visual review.
/// - `BOTCHU_USAGE`: `sample`, `stale`, `expired`, or `unavailable` allowance for an isolated review.
/// - `BOTCHU_SEND`: send this message to the selected bot's shown conversation at launch (its Home,
///   or the tab `BOTCHU_TAB` shows).
/// - `BOTCHU_TASK`: start a task for the selected bot at launch from `repo|task|host`, as New Task does
///   (`repo` is `owner/name` or a checkout's folder in the repositories folder, `host` an optional
///   host's nickname, where the checkout is in its repositories folder; a real turn).
/// - `BOTCHU_TAB`: show the selected bot's tab with this number at launch (0 is Home, 1 its first task).
/// - `BOTCHU_HOST`: with `BOTCHU_DATA_DIR`, the hosts in Settings ▸ Hosts, from
///   `nickname|ssh destination|repositories folder|machine name`, several separated by `;`.
/// - `BOTCHU_SSH`: with `BOTCHU_DATA_DIR`, the program BotChu runs as `ssh` (a stand-in that runs the
///   command here lets a review exercise tasks on a host without one).
/// - `BOTCHU_TASK_REPO`: with `BOTCHU_OPEN=task`, the repository (`owner/name`) New Task chooses.
/// - `BOTCHU_CREATE`: create a bot at launch from `name|account id|instructions`, as the editor does.
/// - `BOTCHU_PET`: give the selected bot this pet folder at launch (`video.json`, `stills/`, `clips/`).
/// - `BOTCHU_DRAW_PET`: give the selected bot this appearance and make its pet at launch (a real Codex
///   run, then real clips on OpenRouter, which cost OpenRouter credit).
@MainActor
enum DevHooks {
    static let env = ProcessInfo.processInfo.environment

    static var dataDir: URL? {
        env["BOTCHU_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The hosts a throwaway run starts with (`BOTCHU_HOST`).
    static var hosts: [SSHHost] {
        guard dataDir != nil, let spec = env["BOTCHU_HOST"] else { return [] }
        return spec.split(separator: ";").compactMap { entry in
            let parts = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { return nil }
            return SSHHost(nickname: parts[0], destination: parts[1], machine: parts.count > 3 ? parts[3] : SSHHost.machineName(destination: parts[1]),
                           reposFolder: parts.count > 2 ? parts[2] : "~/apps")
        }
    }

    /// Settings a throwaway run needs before the model loads: the stand-in `ssh` (`BOTCHU_SSH`).
    static func configure() {
        if dataDir != nil, let ssh = env["BOTCHU_SSH"] { Machine.ssh = ssh }
    }

    static var usageFetch: UsageCache.Fetch? {
        guard dataDir != nil, let fixture = env["BOTCHU_USAGE"],
              ["sample", "stale", "expired", "unavailable"].contains(fixture) else { return nil }
        return { _, _ in
            if fixture == "unavailable" { throw UsageFailure("Check the account’s sign-in, then refresh.") }
            let now = Date()
            return ProviderUsage(windows: [
                UsageWindow(id: "session", title: "5-hour", usedPercent: 24,
                            resetsAt: now.addingTimeInterval(fixture == "expired" ? -60 : 7_200)),
                UsageWindow(id: "week", title: "Weekly", usedPercent: 83, resetsAt: now.addingTimeInterval(259_200)),
            ], readAt: now.addingTimeInterval(fixture == "stale" ? -7_200 : 0))
        }
    }

    static func start(model: AppModel, openSettings: () -> Void) {
        if dataDir != nil, let appearance = env["BOTCHU_APPEARANCE"], ["light", "dark"].contains(appearance) {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let dir = env["BOTCHU_SNAPSHOT"] {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let url = URL(fileURLWithPath: dir, isDirectory: true)
                    snapshot(into: url)
                    snapshotSidebar(model: model, into: url)
                }
            }
        }
        switch env["BOTCHU_OPEN"] {
        case "editor": model.newBot()
        case "task": if let id = model.selection { model.newTask(for: id) }
        case "settings": openSettings()
        default: break
        }
        if let spec = env["BOTCHU_CREATE"] {
            let parts = spec.split(separator: "|", maxSplits: 2).map(String.init)
            var bot = Bot(name: parts[0], workspace: model.defaultWorkspace(for: parts[0]))
            if parts.count > 1 { bot.accountID = parts[1] }
            if parts.count > 2 { bot.instructions = parts[2] }
            model.create(bot)
        }
        if let folder = env["BOTCHU_PET"], let id = model.selection, let bot = model.bot(id) {
            let target = PetVideo.folder(for: BotHome(workspace: bot.workspace))
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath), to: target)
            model.reloadPet(id)
        }
        if let appearance = env["BOTCHU_DRAW_PET"], let id = model.selection {
            model.setAppearance(appearance, for: id)
            model.makePet(id)
        }
        if let tab = env["BOTCHU_TAB"].flatMap(Int.init), tab > 0, let id = model.selection {
            model.showTab(offset: tab, of: id)
        }
        if let text = env["BOTCHU_SEND"], let id = model.selection {
            model.send(text, to: model.tab(of: id))
        }
        if let spec = env["BOTCHU_TASK"], let id = model.selection, let bot = model.bot(id) {
            let parts = spec.split(separator: "|", maxSplits: 2).map(String.init)
            let host = parts.count > 2 ? model.settings.hosts.first { $0.nickname == parts[2] } : nil
            if let checkout = Repositories.find(parts[0], in: model.checkouts()) {
                let task = BotTask(for: bot, repo: checkout.repo,
                                   checkout: host.map { ($0.reposFolder as NSString).appendingPathComponent(checkout.name) } ?? checkout.path,
                                   work: nil, brief: parts.count > 1 ? parts[1] : "Look around and say what this repository is.", host: host)
                model.startTask(task, for: id, show: true)
            }
        }
    }

    /// The sidebar's rows as `sidebar.png`; the sidebar's material isn't in the window's picture.
    static func snapshotSidebar(model: AppModel, into dir: URL) {
        let rows = VStack(alignment: .leading, spacing: 4) {
            ForEach(model.bots) { bot in
                BotRow(bot: bot, status: model.status(of: bot), selected: model.selection == bot.id,
                       unread: model.selection == bot.id ? 0 : model.unreadCount(of: bot.id))
            }
        }
        .padding(10)
        .frame(width: 240, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(model)
        let renderer = ImageRenderer(content: rows)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("sidebar.png"))
    }

    /// Each visible window as `<n>-<title>.png`, drawn by the app itself.
    /// Video layers aren't in a view's cached drawing, so each pet's current frame (and where it
    /// shows, in `root`'s coordinates) is collected to be drawn over the picture, and its player's
    /// state is written to `pets.txt`.
    static func petVideoFrames(in root: NSView) -> [(CGImage, CGRect)] {
        var frames: [(CGImage, CGRect)] = []
        var players: [String] = []
        func visit(_ view: NSView) {
            if let pet = view as? PetVideoLayerView {
                let rect = pet.convert(pet.bounds, to: root)
                players.append(pet.debugState + String(format: " at %.0f,%.0f %.0fx%.0f", rect.minX, rect.minY, rect.width, rect.height))
                if let image = pet.currentFrame() { frames.append((image, rect)) }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        if let dir = env["BOTCHU_SNAPSHOT"] {
            try? (players.joined(separator: "\n") + "\n").write(to: URL(fileURLWithPath: dir).appendingPathComponent("pets.txt"),
                                                               atomically: true, encoding: .utf8)
        }
        return frames
    }

    /// The window's picture with the pets' frames drawn in their circles.
    static func composite(_ rep: NSBitmapImageRep, root: NSView) -> Data? {
        let frames = petVideoFrames(in: root)
        guard let base = rep.cgImage else { return nil }
        if frames.isEmpty { return rep.representation(using: .png, properties: [:]) }
        let width = base.width, height = base.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(width) / root.bounds.width
        for (image, rect) in frames {
            let y = root.isFlipped ? root.bounds.height - rect.maxY : rect.minY
            let target = CGRect(x: rect.minX * scale, y: y * scale, width: rect.width * scale, height: rect.height * scale)
            context.saveGState()
            context.addEllipse(in: target)
            context.clip()
            context.draw(image, in: target)
            context.restoreGState()
        }
        guard let combined = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: combined).representation(using: .png, properties: [:])
    }

    static func snapshot(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (n, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.title.isEmpty ? "window" : window.title.replacingOccurrences(of: "/", with: "-")
            try? composite(rep, root: view)?.write(to: dir.appendingPathComponent("\(n)-\(name).png"))
        }
    }
}
