import SwiftUI
import BotChuCore

struct RemoteQueueSection: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var revealed = false
    @State private var regenerating = false
    var body: some View {
        @Bindable var settings = model.settings
        Section("Remote queue") {
            if let bot = model.bots.first(where: \.isRemoteQueue) {
                LabeledContent("Bot", value: bot.name)
            } else {
                Button("Create Remote Bot…") {
                    var bot = Bot(name: "Danny", workspace: "")
                    bot.kind = .remoteQueue
                    model.editor = EditorRequest(bot: bot, isNew: true)
                }
            }
            Toggle("Serve the remote queue", isOn: $settings.remoteQueueEnabled)
                .help("Danny polls this address while BotChu is open and this Mac is awake.")
            LabeledContent("Listen address") {
                TextField("Listen address", text: $settings.remoteQueueAddress).labelsHidden().settingsField()
            }
            .help("A numeric IP on this Mac, such as its Tailscale address, or an HTTPS tunnel's. 127.0.0.1 is local-only.")
            LabeledContent("Port") {
                TextField("Port", value: $settings.remoteQueuePort, format: .number.grouping(.never)).labelsHidden().settingsField()
            }
            if let url = model.remoteQueue.servingURL {
                LabeledContent("Base URL") { Text(url).textSelection(.enabled) }
            }
            LabeledContent("Token") {
                HStack {
                    Group {
                        if revealed { TextField("Token", text: .constant(token)) }
                        else { SecureField("Token", text: .constant(token)) }
                    }.labelsHidden().settingsField()
                    Button(revealed ? "Hide" : "Show") { token = model.remoteQueue.readToken() ?? ""; revealed.toggle() }
                        .help("Hand the token to Danny through secure entry; keep it out of chats.")
                    Button("Copy") {
                        token = model.remoteQueue.readToken() ?? ""
                        guard !token.isEmpty else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                    }
                    Button("Regenerate…") { regenerating = true }
                        .help("Regenerating it disconnects the old token.")
                }
            }
            LabeledContent("Status", value: model.remoteQueue.summary)
            RemoteQueuePresence()
            if let problem = model.remoteQueue.problem {
                Label(problem, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .onAppear { if model.settings.remoteQueueEnabled { token = model.remoteQueue.readToken() ?? "" } }
        .confirmationDialog("Replace the remote queue token?", isPresented: $regenerating) {
            Button("Regenerate Token") {
                if model.remoteQueue.regenerateToken() { token = model.remoteQueue.readToken() ?? "" }
            }
        } message: { Text("Danny will need the new token before he can poll or post replies again. Waiting messages are kept.") }
    }
}

struct RemoteQueuePresence: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let queue = model.remoteQueue!
        VStack(alignment: .leading, spacing: 6) {
            Label("\(queue.presence) · \(queue.pending) waiting", systemImage: queue.online ? "circle.fill" : "circle")
                .foregroundStyle(queue.online ? .green : queue.unreachable ? .orange : .secondary)
            Text(queue.lastPoll.map { "Last poll: \($0.formatted(date: .abbreviated, time: .standard))" } ?? "No poll received yet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RemoteQueueInspector: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Only the selected bot's inspector shows, so its pet moves, as a local bot's does,
                // for what its Home conversation is known to be doing.
                BotIntro(bot: bot, activity: model.status(of: .home(bot.id))?.activity ?? .idle, animates: true)
                PetJobStatus(botID: bot.id)
                Text("Remote queue bot").font(.headline)
                RemoteQueuePresence()
                Text(model.remoteQueue.summary).foregroundStyle(.secondary)
                if let problem = model.remoteQueue.problem { Text(problem).foregroundStyle(.red) }
                HStack {
                    Button("Edit…") { model.edit(bot.id) }
                    Button("Connection Settings…") { model.openSettings(.remoteQueue) }
                }
                Button("Show Conversation Files") { model.revealHistory(bot.id) }
            }.padding(20)
        }
        .background(Palette.sidebar)
    }
}
