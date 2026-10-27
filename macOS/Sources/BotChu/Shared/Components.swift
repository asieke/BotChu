import SwiftUI
import BotChuCore

/// Layout constants shared by the window's views.
enum Theme {
    /// The widest the chat column grows, so lines stay readable in a wide window.
    static let chatWidth: CGFloat = 760
    static let messageAvatar: CGFloat = 26
    static let bubbleRadius: CGFloat = 16
    static let cardRadius: CGFloat = 9
    /// Matches ChatRenderer/index.html so rich replies blend into the same bubble as native text.
    static let replyBackground = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(srgbRed: dark ? 41 / 255 : 247 / 255,
                       green: dark ? 41 / 255 : 247 / 255,
                       blue: dark ? 41 / 255 : 247 / 255, alpha: 1)
    })
}

/// A bot's face: its pet's head when it has one (animated for what it is doing), else its emoji.
struct BotAvatar: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    var size: CGFloat = 30
    var activity: BotActivity = .idle
    var animates = false

    var body: some View {
        Group {
            if let video = model.pets[bot.id] {
                // A pet is a square portrait: shown in a circle, like a profile picture.
                PetVideoView(package: video, activity: activity, animates: animates)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Text(bot.emoji)
                    .font(.system(size: size * 0.55))
                    .frame(width: size, height: size)
                    .background(Circle().fill(Self.tint(for: bot.name).opacity(0.22)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// A stable color per name, so each bot keeps its own.
    static func tint(for name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .mint, .red, .yellow]
        let hash = name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

extension BotStatus.Phase {
    var label: String {
        switch self {
        case .idle: "Idle"
        case .preparing: "Preparing…"
        case .starting: "Starting…"
        case .working: "Working"
        case .failed: "Last turn failed"
        case .stopped: "Stopped"
        }
    }
}

extension BotStatus {
    /// The phase, or while a turn works, what the bot is doing in it; for a bot whose tasks work
    /// while its Home is idle, which task.
    var label: String {
        if let workingOn, phase.isActive { return "Working on \(workingOn)" }
        return phase == .working ? activity.label : phase.label
    }
}

extension BotActivity {
    var label: String {
        switch self {
        case .idle: "Idle"
        case .greeting: "Saying hello"
        case .thinking: "Thinking"
        case .researching: "Researching"
        case .browsing: "Browsing"
        case .coding: "Coding"
        case .testing: "Testing"
        case .working: "Working"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}
