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
/// - `BOTCHU_OPEN=model|effort|inspector-model|inspector-effort`: open a generation picker.
/// - `BOTCHU_DEFAULT_MODEL`: an OpenRouter default for a throwaway run only.
/// - `BOTCHU_WINDOW=compact`: review the main window at its minimum width, on throwaway data.
/// - `BOTCHU_USAGE`: `sample`, `stale`, `expired`, or `unavailable` allowance for an isolated review.
/// - `BOTCHU_SEND`: send this message to the selected bot's shown conversation at launch (its Home,
///   or the tab `BOTCHU_TAB` shows).
/// - `BOTCHU_TASK`: start a task for the selected bot at launch from `repo|task`, as New Task does
///   (`repo` is `owner/name` or a checkout's folder in the repositories folder; a real turn).
/// - `BOTCHU_TAB`: show the selected bot's tab with this number at launch (0 is Home, 1 its first task).
/// - `BOTCHU_CREATE`: create a bot at launch from `name|account id|instructions`, as the editor does.
/// - `BOTCHU_PET`: give the selected bot this Codex pet folder at launch, as Import Codex Pet does.
/// - `BOTCHU_DRAW_PET`: give the selected bot this appearance and draw its pet at launch (a real
///   Codex run on the pet account, which takes a while).
@MainActor
enum DevHooks {
    static let env = ProcessInfo.processInfo.environment

    static var dataDir: URL? {
        env["BOTCHU_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
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
        if dataDir != nil, env["BOTCHU_WINDOW"] == "compact" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { return }
                // SwiftUI establishes the split view's actual minimum after the first layout.
                window.setContentSize(NSSize(width: max(820, window.contentMinSize.width),
                                             height: max(600, window.contentMinSize.height)))
            }
        }
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
        if let folder = env["BOTCHU_PET"], let id = model.selection {
            try? model.importPet(from: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true), for: id)
        }
        if let appearance = env["BOTCHU_DRAW_PET"], let id = model.selection {
            model.setAppearance(appearance, for: id)
            model.drawPet(id)
        }
        if let tab = env["BOTCHU_TAB"].flatMap(Int.init), tab > 0, let id = model.selection {
            model.showTab(offset: tab, of: id)
        }
        if let text = env["BOTCHU_SEND"], let id = model.selection {
            model.send(text, to: model.tab(of: id))
        }
        if let spec = env["BOTCHU_TASK"], let id = model.selection, let bot = model.bot(id) {
            let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
            if let checkout = Repositories.find(parts[0], in: model.checkouts()) {
                let task = BotTask(for: bot, repo: checkout.repo, checkout: checkout.path, work: nil,
                                   brief: parts.count > 1 ? parts[1] : "Look around and say what this repository is.")
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
    static func snapshot(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (n, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.title.isEmpty ? "window" : window.title.replacingOccurrences(of: "/", with: "-")
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(n)-\(name).png"))
        }
    }
}
