import AppKit
import SwiftUI
import BotChuCore

/// The right-hand sidebar: the selected bot's face and state in a card, then what it runs on, its
/// session, conversation, memory and workspace in grouped cards, and the actions on it.
struct BotInspector: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    @State private var memory = MemorySnapshot.missing

    var body: some View {
        if let bot = model.bot(botID) {
            let status = model.status(of: bot)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    AvatarCard(bot: bot, status: status) { model.edit(botID) }
                    PetDrawingStatus(botID: botID)
                    InspectorSection("Runs on") {
                        InspectorCard {
                            InspectorRow("Account") {
                                Label(bot.account.name, systemImage: bot.account.symbol)
                                    .labelStyle(.titleAndIcon)
                            }
                            InspectorRow("Agent", value: bot.account.kind.displayName)
                            InspectorRow("Model", value: modelName(bot))
                            InspectorRow("Reasoning", value: bot.reasoningEffort?.title ?? "Default", last: true)
                        }
                    }
                    InspectorSection("Session") {
                        InspectorCard {
                            if case .continuing(let id) = status.session {
                                InspectorRow("Next message", value: sessionSummary(status.session))
                                InspectorRow("ID", last: true) {
                                    HStack(spacing: 2) {
                                        Text(id)
                                            .font(.system(size: 12, design: .monospaced))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .help(id)
                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(id, forType: .string)
                                        } label: {
                                            Image(systemName: "doc.on.doc")
                                                .frame(width: 28, height: 28)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Palette.secondaryText)
                                        .help("Copy session ID")
                                    }
                                }
                            } else {
                                InspectorRow("Next message", value: sessionSummary(status.session), last: true)
                            }
                        }
                    }
                    InspectorSection("Conversation") {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            StatTile(value: "\(status.messageCount)", label: "Messages", tabular: true)
                            StatTile(value: "\(status.toolCallCount)", label: "Tool calls", tabular: true)
                            StatTile(value: status.lastActivity.map(Self.ago) ?? "None yet", label: "Last activity")
                            StatTile(value: bot.createdAt.formatted(.dateTime.month(.abbreviated).day()), label: "Created")
                        }
                    }
                    InspectorSection("Memory", trailing: memorySummary) {
                        InspectorCard(padded: true) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("MEMORY.md")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Palette.secondaryText)
                                MemoryPreview(memory: memory)
                            }
                        }
                    }
                    InspectorSection("Workspace") {
                        InspectorCard(padded: true) {
                            Text((bot.workspace as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 11, design: .monospaced))
                                .lineSpacing(2)
                                .foregroundStyle(Palette.pathText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(bot.workspace)
                        }
                        HStack(spacing: 8) {
                            Button { model.revealWorkspace(botID) } label: {
                                Label("Show in Finder", systemImage: "folder")
                            }
                            Button { model.revealHistory(botID) } label: {
                                Label("History & Logs", systemImage: "clock")
                            }
                            .help("Open .botchu/: the bot's settings, its conversation and a log of each turn")
                        }
                        .buttonStyle(InspectorButtonStyle(fill: true))
                    }
                }
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 24, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
                // Explicit, so the sidebar's vibrancy doesn't recolor text on these opaque cards.
                .foregroundStyle(Palette.text)
            }
            .background(Palette.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actions(bot, running: status.phase.isActive)
            }
            // The bot keeps MEMORY.md itself, so read it again whenever a turn ends.
            .task(id: "\(bot.workspace)|\(status.phase.isActive)|\(status.messageCount)") {
                memory = MemorySnapshot.read(bot: bot)
            }
        }
    }

    private func actions(_ bot: Bot, running: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 8) {
                Button("Edit…") { model.edit(botID) }
                    .buttonStyle(InspectorButtonStyle())
                Spacer()
                Button("New Session") { model.newSession(botID) }
                    .buttonStyle(InspectorButtonStyle(prominent: true))
                    .disabled(running)
                    .help("Start the next message in a fresh session (⌘K)")
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .background(Palette.sidebar)
        }
    }

    private func modelName(_ bot: Bot) -> String {
        if !bot.model.isEmpty {
            return GenerationOptions.modelArgument(bot.model, kind: bot.account.kind, effort: bot.reasoningEffort)
        }
        return bot.account.kind == .pi ? model.settings.openRouterModel : "CLI default"
    }

    private func sessionSummary(_ session: BotStatus.Session) -> String {
        switch session {
        case .continuing: "Continues session"
        case .startsNew(accountChanged: true): "New session (account changed)"
        case .startsNew(accountChanged: false): "Starts a new session"
        }
    }

    private var memorySummary: String {
        guard memory.exists else { return "Not created yet" }
        let entries = memory.entryCount == 1 ? "1 entry" : "\(memory.entryCount) entries"
        guard let modified = memory.modified else { return entries }
        return "\(entries) · \(Self.ago(modified))"
    }

    static func ago(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 5 ? "just now" : date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}

/// The card at the top: the bot's face in a ring that shows its state, its name and title, a
/// status pill, and a line on what it is doing.
struct AvatarCard: View {
    let bot: Bot
    let status: BotStatus
    let edit: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            StatusAvatar(bot: bot, status: status, size: 128)
            VStack(spacing: 2) {
                Text(bot.name)
                    .font(.system(size: 20, weight: .bold))
                    .kerning(-0.2)
                if !bot.title.isEmpty {
                    Text(bot.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.cardSubtitle)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            VStack(spacing: 8) {
                StatusPill(state: StatusLook(status))
                detail
                if status.phase.isActive { IndeterminateBar() }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(EdgeInsets(top: 24, leading: 16, bottom: 18, trailing: 16))
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).fill(Palette.avatarCard))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.black.opacity(0.04)))
        .overlay(alignment: .topTrailing) {
            Button(action: edit) {
                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.cardButton))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.buttonText)
            .padding(8)
            .help("Edit \(bot.name), including its appearance")
        }
    }

    @ViewBuilder private var detail: some View {
        Group {
            switch status.phase {
            case .starting:
                Text("Starting \(bot.account.name)…")
            case .working:
                if let started = status.runStartedAt {
                    Text("\(status.activity.doing) · \(Text(started, style: .timer))")
                } else {
                    Text(status.activity.doing)
                }
            case .failed:
                Text(status.lastError ?? "The last turn failed")
                    .lineLimit(4)
                    .textSelection(.enabled)
            case .idle:
                Text(status.lastActivity.map { "Last active \(BotInspector.ago($0))" } ?? "No messages yet")
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .foregroundStyle(Palette.cardSubtitle)
        .multilineTextAlignment(.center)
    }
}

/// How a bot's state looks: the ring around its face, its dot and its pill.
enum StatusLook {
    case idle, working, error

    init(_ status: BotStatus) {
        switch status.phase {
        case .idle: self = .idle
        case .starting, .working: self = .working
        case .failed: self = .error
        }
    }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .error: "Error"
        }
    }

    var dot: Color {
        switch self {
        case .idle: Palette.dynamic(0x8E8E93, 0x8E8E93)
        case .working: Palette.dynamic(0x7C5CFA, 0x9D84FF)
        case .error: Palette.dynamic(0xD93A2F, 0xFF6B60)
        }
    }

    var pillBackground: Color {
        switch self {
        case .idle: Palette.dynamic(0xE6E2DD, 0x3A3A3F)
        case .working: Palette.dynamic(0xE9E3FB, 0x352B5C)
        case .error: Palette.dynamic(0xFBE1DF, 0x4A2220)
        }
    }

    var pillText: Color {
        switch self {
        case .idle: Palette.dynamic(0x3F3F44, 0xD1D1D6)
        case .working: Palette.dynamic(0x4B2FB3, 0xCBBCFF)
        case .error: Palette.dynamic(0x9E2219, 0xFFB4AD)
        }
    }
}

struct StatusPill: View {
    let state: StatusLook

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state.dot).frame(width: 7, height: 7)
            Text(state.label)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(state.pillText)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(state.pillBackground))
    }
}

/// A bot's face in a ring: grey when idle, a spinning violet arc while it works, red after a
/// failed turn; a dot in the corner says the same.
struct StatusAvatar: View {
    let bot: Bot
    let status: BotStatus
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let look = StatusLook(status)
        let moving = look == .working && !reduceMotion
        // Driven by the clock rather than implicit animations, which would also animate layout.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving)) { context in
            let t = moving ? context.date.timeIntervalSinceReferenceDate : 0
            ZStack {
                ring(look, angle: .degrees(t.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360))
                Circle().fill(Palette.avatarCard).padding(5)
                BotFace(bot: bot, activity: status.activity, animates: true)
                    .saturation(look == .error ? 0.3 : 1)
                    .clipShape(Circle())
                    .padding(8)
            }
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(look.dot)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Palette.avatarCard, lineWidth: 3))
                    .opacity(moving ? 0.675 + 0.325 * cos(t / 1.2 * 2 * .pi) : 1)
                    .padding(10)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func ring(_ look: StatusLook, angle: Angle) -> some View {
        switch look {
        case .idle:
            Circle().fill(Palette.dynamic(0xC9C3DA, 0x4A4560))
        case .error:
            Circle().fill(look.dot)
        case .working:
            Circle()
                .fill(AngularGradient(stops: [
                    .init(color: Palette.violet, location: 0),
                    .init(color: Palette.dynamic(0xC8B8FF, 0x6C55C9), location: 0.35),
                    .init(color: Palette.violet.opacity(0), location: 0.65),
                    .init(color: Palette.violet, location: 1),
                ], center: .center))
                .rotationEffect(angle)
        }
    }
}

/// A face filling its frame: the pet's head when the bot has one, else its emoji.
struct BotFace: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    var activity: BotActivity = .idle
    var animates = false

    var body: some View {
        GeometryReader { geometry in
            if let sheet = model.petSheets[bot.id] {
                PetSpriteView(sheet: sheet, activity: activity, style: .head, animates: animates)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                Text(bot.emoji)
                    .font(.system(size: geometry.size.width * 0.5))
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
}

/// A slim bar sliding left to right while a turn works.
struct IndeterminateBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
            // Ease in and out, from just off the left to just off the right.
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            Capsule()
                .fill(Palette.violet.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Palette.violet)
                        .frame(width: 48)
                        .offset(x: -48 + eased * 168)
                }
                .clipShape(Capsule())
        }
        .frame(width: 120, height: 3)
        .accessibilityHidden(true)
    }
}

/// A titled group in the status sidebar, with an optional note on the right of the title.
struct InspectorSection<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content

    init(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                    .textCase(.uppercase)
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 11))
                }
            }
            .foregroundStyle(Palette.secondaryText)
            .padding(.horizontal, 4)
            content
        }
    }
}

/// A white card holding rows or content.
struct InspectorCard<Content: View>: View {
    var padded = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padded ? EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12) : EdgeInsets())
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.cardEdge))
    }
}

/// A label and its value on one line of a card, with a divider below unless it is the last.
struct InspectorRow<Value: View>: View {
    let label: String
    var last = false
    @ViewBuilder let value: Value

    init(_ label: String, last: Bool = false, @ViewBuilder value: () -> Value) {
        self.label = label
        self.last = last
        self.value = value()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(Palette.secondaryText)
            Spacer(minLength: 8)
            value
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
        }
    }
}

extension InspectorRow where Value == Text {
    init(_ label: String, value: String, last: Bool = false) {
        self.init(label, last: last) { Text(value) }
    }
}

/// A number or short value over its label, one of the conversation's tiles.
struct StatTile: View {
    let value: String
    let label: String
    var tabular = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.cardEdge))
    }
}

/// The sidebar's buttons: soft grey, or the accent for the main action.
struct InspectorButtonStyle: ButtonStyle {
    var prominent = false
    /// Fills the width it is given, as the workspace buttons do.
    var fill = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Palette.buttonText)
            .padding(.horizontal, 16)
            .frame(maxWidth: fill ? .infinity : nil)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(prominent ? Palette.accent : Palette.button))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

/// What the bot's MEMORY.md holds.
struct MemoryPreview: View {
    let memory: MemorySnapshot

    var body: some View {
        Group {
            if memory.body.isEmpty {
                Text("Nothing saved yet. The bot adds what it learns here.")
                    .foregroundStyle(Palette.secondaryText)
            } else {
                ScrollView {
                    MarkdownText(text: memory.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
        .font(.system(size: 13))
        .lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The status sidebar's colors, light and dark.
enum Palette {
    static let sidebar = dynamic(0xF2F0EE, 0x1E1D21)
    static let hairline = dynamic(0xDEDAD5, 0x34333A)
    static let avatarCard = dynamic(0xECE8F6, 0x2B2740)
    static let card = dynamic(0xFFFFFF, 0x2A2A2F)
    static let cardEdge = Color.primary.opacity(0.05)
    static let rowDivider = dynamic(0xEEECE9, 0x36353B)
    static let secondaryText = dynamic(0x636366, 0x98989F)
    static let cardSubtitle = dynamic(0x5C5866, 0xA6A1B3)
    static let pathText = dynamic(0x3A3A3C, 0xC7C7CC)
    static let button = dynamic(0xE5E2DE, 0x3A393F)
    static let cardButton = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor.white.withAlphaComponent(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.08 : 0.6)
    })
    static let buttonText = dynamic(0x1D1D1F, 0xF2F2F7)
    static let text = buttonText
    static let accent = dynamic(0x5B3FD0, 0x6E52E0)
    static let violet = dynamic(0x7C5CFA, 0x9D84FF)

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

extension BotActivity {
    /// What the bot is doing, as the status card's line says it.
    var doing: String {
        switch self {
        case .idle, .greeting, .done: "Wrapping up…"
        case .thinking: "Thinking…"
        case .researching: "Reading files…"
        case .browsing: "Searching the web…"
        case .coding: "Editing code…"
        case .testing: "Running checks…"
        case .working: "Running a tool…"
        case .failed: "Hit a problem…"
        }
    }
}
