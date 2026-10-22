import AppKit
import SwiftUI
import BotChuCore

/// Environment variables for checking the app without touching real data or needing screen-recording
/// permission (see `macOS/ui-review.sh`):
/// - `BOTCHU_DATA_DIR`: keep the bot index and bot folders under this folder instead, with settings in
///   their own `defaults` domain (`local.BotChu.dev`), so a throwaway run never changes the real ones.
/// - `BOTCHU_SNAPSHOT`: write a PNG of each window into this folder every second.
/// - `BOTCHU_OPEN`: open `editor` (a new bot) or `settings` at launch.
/// - `BOTCHU_SEND`: send this message to the selected bot at launch.
/// - `BOTCHU_CREATE`: create a bot at launch from `name|account id|instructions`, as the editor does.
@MainActor
enum DevHooks {
    static let env = ProcessInfo.processInfo.environment

    static var dataDir: URL? {
        env["BOTCHU_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func start(model: AppModel, openSettings: () -> Void) {
        if let dir = env["BOTCHU_SNAPSHOT"] {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { snapshot(into: URL(fileURLWithPath: dir, isDirectory: true)) }
            }
        }
        switch env["BOTCHU_OPEN"] {
        case "editor": model.newBot()
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
        if let text = env["BOTCHU_SEND"], let id = model.selection {
            model.send(text, to: id)
        }
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
