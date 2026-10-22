import SwiftUI
import BotChuCore

/// Layout constants shared by the window's views.
enum Theme {
    /// The widest the chat column grows, so lines stay readable in a wide window.
    static let chatWidth: CGFloat = 760
    static let messageAvatar: CGFloat = 26
    static let bubbleRadius: CGFloat = 16
    static let cardRadius: CGFloat = 9
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
            if let sheet = model.petSheets[bot.id] {
                // A pet is drawn on nothing: its own outline is the avatar.
                PetSpriteView(sheet: sheet, activity: activity, style: .head, animates: animates)
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
        case .starting: "Starting…"
        case .working: "Working"
        case .failed: "Last turn failed"
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .starting: .orange
        case .working: .green
        case .failed: .red
        }
    }

    var isActive: Bool { self == .starting || self == .working }
}

extension BotStatus {
    /// The phase, or while a turn works, what the bot is doing in it.
    var label: String { phase == .working ? activity.label : phase.label }
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

/// The bot's phase as a colored capsule, with the turn's running time while it works.
struct StatusBadge: View {
    let status: BotStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.phase.color)
                .frame(width: 7, height: 7)
            Text(status.label)
            if status.phase.isActive, let started = status.runStartedAt {
                Text(started, style: .timer)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(status.phase.color.opacity(0.12)))
    }
}
