import AppKit
import SwiftUI
import BotChuCore

/// Home's character and four inspector areas, scoped to this bot's Home conversation.
struct BotInspector: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        if let bot = model.bot(botID), let status = model.status(of: .home(botID)) {
            InspectorPanel(badgeCounts: [.subagents: model.delegation.activeCount(.home(botID), includeTasks: true)]) {
                InspectorSection("Status") {
                    AvatarCard(bot: bot, status: status, title: bot.name, subtitle: bot.title, account: bot.account) { model.edit(botID) }
                    PetJobStatus(botID: botID)
                }
            } content: { tab in
                switch tab {
                case .activity:
                    ClosedTasksSection(botID: botID)
                    RunReviewsSection(target: .home(botID))
                    JobsSection(botID: botID)
                    InspectorSection("Conversation") {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            StatTile(value: "\(status.messageCount)", label: "Messages", tabular: true)
                            StatTile(value: "\(status.toolCallCount)", label: "Tool calls", tabular: true)
                            StatTile(value: status.lastActivity.map(Self.ago) ?? "None yet", label: "Last activity")
                            StatTile(value: bot.createdAt.formatted(.dateTime.month(.abbreviated).day()), label: "Created")
                        }
                    }
                case .subagents:
                    SubagentsInspectorContent(target: .home(botID), includeBotTasksOverview: true)
                case .model:
                    InspectorSection("Runs on") {
                        RunsOnCard(settings: bot, target: .home(botID))
                    }
                    let usageRequest = UsageRequest(account: bot.account, command: model.settings.command(for: bot.account),
                        credentialRevision: bot.account.kind == .pi ? model.settings.usageCredentialRevision : 0)
                    AccountUsageSection(request: usageRequest, isRunning: model.isRunning(.home(botID)))
                        .id(usageRequest)
                case .session:
                    InspectorSection("Session") {
                        SessionCard(session: status.session)
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
                case .memory:
                    MemorySection(botID: botID)
                }
            } actions: {
                actions
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 8) {
                Button("Edit…") { model.edit(botID) }
                    .buttonStyle(InspectorButtonStyle())
                Spacer()
                Button("New Session") { model.newSession(.home(botID)) }
                    .buttonStyle(InspectorButtonStyle(prominent: true))
                    .disabled(model.isRunning(.home(botID)))
                    .help("Start the next message in a fresh session (⌘K)")
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .background(Palette.sidebar)
        }
    }

    static func ago(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 5 ? "just now" : date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}

/// The card at the top: a large character beside the bot's name, task title and current activity.
/// The ring and pet reflect this conversation's activity.
struct AvatarCard: View {
    let bot: Bot
    let status: BotStatus
    let title: String
    let subtitle: String
    /// The account the turn starts on.
    let account: Account
    var eyebrow: String?
    /// The pencil in the corner; none without.
    var edit: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusAvatar(bot: bot, status: status, size: 88)
                .overlay(alignment: .bottomTrailing) {
                    if let edit {
                        Button(action: edit) {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Palette.button))
                                .overlay(Circle().strokeBorder(Palette.card, lineWidth: 2))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.buttonText)
                        .help("Edit \(bot.name), including its appearance")
                        .accessibilityLabel("Edit \(bot.name)")
                    }
                }
            VStack(alignment: .leading, spacing: 5) {
                if let eyebrow {
                    Text(eyebrow)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .help(eyebrow)
                }
                Text(title)
                    .font(.system(size: eyebrow == nil ? 15 : 18, weight: .bold))
                    .kerning(-0.2)
                    .accessibilityLabel("\(title), \(StatusLook(status).label)")
                    .lineLimit(2)
                    .help(title)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.cardSubtitle)
                        .lineLimit(2)
                        .help(subtitle)
                }
                detail
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.cardEdge))
    }

    @ViewBuilder private var detail: some View {
        Group {
            switch status.phase {
            case .preparing:
                Text("Preparing the task's workspace…")
            case .starting:
                Text("Starting \(account.name)…")
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
        .multilineTextAlignment(.leading)
    }
}

/// What a conversation runs on: account, agent, model and reasoning. A task's account can change
/// here (`changeAccount`); a bot's changes in Edit Bot.
struct RunsOnCard: View {
    @Environment(AppModel.self) private var model
    let settings: any RunSettings
    let target: ChatTarget

    var body: some View {
        InspectorCard {
            InspectorRow("Account") {
                Menu {
                    Picker("Account", selection: Binding(get: { settings.accountID }, set: { model.setAccount($0, for: target) })) {
                        ForEach(model.settings.accounts) { account in
                            ProviderMenuLabel(account).tag(account.id)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    ProviderMenuLabel(settings.account)
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .disabled(model.isRunning(target))
                .accessibilityLabel("Account: \(settings.account.name)")
                .help(model.isRunning(target) ? "Account can change when this turn ends"
                      : "Choose the account for this conversation; its next message starts a session there")
            }
            InspectorRow("Agent", value: settings.account.kind.displayName)
            ModelMenu(settings: settings, disabled: model.isRunning(target),
                      onModel: { model.setModel($0, for: target) },
                      onEffort: { model.setReasoningEffort($0, for: target) }, inInspector: true)
                .id(target)
        }
    }
}

/// Whether the next message continues the conversation's CLI session, with its id to copy.
struct SessionCard: View {
    let session: BotStatus.Session

    var body: some View {
        InspectorCard {
            if case .continuing(let id) = session {
                InspectorRow("Next message", value: summary)
                InspectorRow("ID", last: true) {
                    HStack(spacing: 2) {
                        Text(id)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(id)
                        CopyButton(text: id, help: "Copy session ID")
                    }
                }
            } else {
                InspectorRow("Next message", value: summary, last: true)
            }
        }
    }

    private var summary: String {
        switch session {
        case .continuing: "Continues session"
        case .startsNew(accountChanged: true): "New session (account changed)"
        case .startsNew(accountChanged: false): "Starts a new session"
        }
    }
}

/// A small button that copies `text`.
struct CopyButton: View {
    let text: String
    let help: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.secondaryText)
        .help(help)
    }
}

/// Home's closed tasks, to open again: the open ones are the tabs beside the chat (#128). Collapsed
/// at first, with their count; nothing while none is closed.
struct ClosedTasksSection: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        let closed = model.closedTasks(of: botID).reversed()
        if !closed.isEmpty {
            InspectorSection("Closed tasks", trailing: "\(closed.count)", expandedByDefault: false) {
                InspectorCard {
                    ForEach(Array(closed.enumerated()), id: \.element.id) { index, task in
                        ClosedTaskRow(task: task, last: index == closed.count - 1) {
                            model.reopenTask(.task(task.id, of: botID))
                        }
                    }
                }
            }
        }
    }
}

/// A closed task in Home's list: its repository and number, and what it was about; a click opens
/// it again.
struct ClosedTaskRow: View {
    let task: BotTask
    let last: Bool
    let reopen: () -> Void

    var body: some View {
        let tab = ConversationTab(task: task, machine: nil, state: .idle(since: nil))
        Button(action: reopen) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(tab.subject)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
        }
        .help("Open \(task.title) again")
    }
}

/// A conversation's status ring and the bot list's activity color.
enum StatusLook {
    case idle, working, error

    init(_ status: BotStatus) {
        switch status.phase {
        case .idle: self = .idle
        case .preparing, .starting, .working: self = .working
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

}

/// A bot's face in a ring: grey when idle, a spinning violet arc while it works, red after a
/// failed turn. This is the character card's only status indicator.
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
                Circle().fill(Palette.card).padding(4)
                BotFace(bot: bot, activity: status.activity, animates: true)
                    .saturation(look == .error ? 0.3 : 1)
                    .clipShape(Circle())
                    .padding(6)
            }
            .frame(width: size, height: size)

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
            if let video = model.pets[bot.id] {
                PetVideoView(package: video, activity: activity, animates: animates)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                Text(bot.emoji)
                    .font(.system(size: geometry.size.width * 0.5))
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
}

/// A titled group in the status sidebar, with an optional note on the right of the title.
struct InspectorSection<Content: View>: View {
    let title: String
    var trailing: String?
    /// What VoiceOver reads for the heading, when the title and note don't say it well.
    var spoken: String?
    @ViewBuilder let content: Content
    @AppStorage private var expanded: Bool

    init(_ title: String, trailing: String? = nil, preferenceKey: String? = nil, spoken: String? = nil, expandedByDefault: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.spoken = spoken
        self.content = content()
        _expanded = AppStorage(wrappedValue: expandedByDefault, "inspector.expanded.\(preferenceKey ?? title)")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content
        } label: {
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
            .modifier(SpokenHeading(text: spoken))
        }
        .disclosureGroupStyle(InspectorDisclosureStyle())
    }
}

private struct SpokenHeading: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.accessibilityElement(children: .ignore).accessibilityLabel(text)
        } else {
            content
        }
    }
}

/// Keeps the cards full-width and makes the entire heading a keyboard-accessible toggle.
struct InspectorDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                }
                .foregroundStyle(Palette.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
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

/// Compact, plain values for the inspector's selectable rows. The composer keeps its larger pills.
struct InspectorChoiceLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Palette.secondaryText)
        }
        .font(.system(size: 13))
        .frame(minHeight: 28)
        .contentShape(Rectangle())
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

/// The status sidebar's colors, light and dark.
enum Palette {
    static let sidebar = dynamic(0xF2F0EE, 0x1E1D21)
    static let hairline = dynamic(0xDEDAD5, 0x34333A)
    static let card = dynamic(0xFFFFFF, 0x2A2A2F)
    static let cardEdge = Color.primary.opacity(0.05)
    static let rowDivider = dynamic(0xEEECE9, 0x36353B)
    static let secondaryText = dynamic(0x636366, 0x98989F)
    static let cardSubtitle = dynamic(0x5C5866, 0xA6A1B3)
    static let pathText = dynamic(0x3A3A3C, 0xC7C7CC)
    static let button = dynamic(0xE5E2DE, 0x3A393F)
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
