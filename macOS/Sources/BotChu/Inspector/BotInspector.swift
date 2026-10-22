import SwiftUI
import BotChuCore

/// The right-hand sidebar: the selected bot's status at a glance, and the actions on it.
struct BotInspector: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    @State private var memory = MemorySnapshot.missing

    var body: some View {
        if let bot = model.bot(botID) {
            let status = model.status(of: bot)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(bot, status)
                    if let error = status.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                    InspectorSection("Runs on") {
                        InspectorRow("Account") {
                            Label(bot.account.name, systemImage: bot.account.symbol)
                        }
                        InspectorRow("Agent", value: bot.account.kind.displayName)
                        InspectorRow("Model", value: modelName(bot))
                        InspectorRow("Reasoning", value: bot.reasoningEffort?.title ?? "Default")
                    }
                    InspectorSection("Session") {
                        InspectorRow("Next message", value: sessionSummary(status.session))
                        if case .continuing(let id) = status.session {
                            InspectorRow("ID") {
                                Text(id)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .help(id)
                            }
                        }
                    }
                    InspectorSection("Conversation") {
                        InspectorRow("Messages", value: "\(status.messageCount)")
                        InspectorRow("Tool calls", value: "\(status.toolCallCount)")
                        InspectorRow("Last activity", value: status.lastActivity.map(relative) ?? "None yet")
                        InspectorRow("Created", value: bot.createdAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    InspectorSection("Memory") {
                        InspectorRow("MEMORY.md", value: memorySummary)
                        MemoryPreview(memory: memory)
                    }
                    InspectorSection("Workspace") {
                        Text((bot.workspace as NSString).abbreviatingWithTildeInPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(bot.workspace)
                        HStack {
                            Button("Show in Finder") { model.revealWorkspace(botID) }
                            Button("History & Logs") { model.revealHistory(botID) }
                                .help("Open .botchu/: the bot's settings, its conversation and a log of each turn")
                        }
                        .controlSize(.small)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actions(bot, running: status.phase.isActive)
            }
            // The bot keeps MEMORY.md itself, so read it again whenever a turn ends.
            .task(id: "\(bot.workspace)|\(status.phase.isActive)|\(status.messageCount)") {
                memory = MemorySnapshot.read(bot: bot)
            }
        }
    }

    private func header(_ bot: Bot, _ status: BotStatus) -> some View {
        HStack(alignment: .top, spacing: 12) {
            BotAvatar(bot: bot, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(bot.name).font(.headline)
                    if !bot.title.isEmpty {
                        Text(bot.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                StatusBadge(status: status)
            }
        }
    }

    private func actions(_ bot: Bot, running: Bool) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button("Edit…") { model.edit(botID) }
                Spacer()
                Button("New Session") { model.newSession(botID) }
                    .disabled(running)
                    .help("Start the next message in a fresh session (⌘K)")
            }
            .controlSize(.small)
            .padding(12)
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
        case .continuing: "Continues the session"
        case .startsNew(accountChanged: true): "New session (account changed)"
        case .startsNew(accountChanged: false): "Starts a new session"
        }
    }

    private var memorySummary: String {
        guard memory.exists else { return "Not created yet" }
        let entries = memory.entryCount == 1 ? "1 entry" : "\(memory.entryCount) entries"
        guard let modified = memory.modified else { return entries }
        return "\(entries) · \(relative(modified))"
    }

    private func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

/// A titled group of rows in the status sidebar.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
    }
}

/// A label and its value on one line.
struct InspectorRow<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

extension InspectorRow where Value == Text {
    init(_ label: String, value: String) {
        self.init(label) { Text(value) }
    }
}

/// What the bot's MEMORY.md holds, in a small scrolling box.
struct MemoryPreview: View {
    let memory: MemorySnapshot

    var body: some View {
        Group {
            if memory.body.isEmpty {
                Text("Nothing saved yet. The bot adds what it learns here.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    MarkdownText(text: memory.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Color.primary.opacity(0.04)))
    }
}
