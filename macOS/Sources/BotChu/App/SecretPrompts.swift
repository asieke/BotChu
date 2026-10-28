import AppKit
import SwiftUI
import BotChuCore

/// The keys and passwords bots ask the owner for with `botchu-secret ask` (#266), one popup at a
/// time, oldest first. What the owner pastes goes straight into the asking turn's mailbox, where
/// its helper reads it, deletes it and puts it in place; BotChu keeps no copy, and one the helper
/// never reads is deleted after `unreadLimit`.
@MainActor @Observable
final class SecretPrompts {
    struct Prompt: Identifiable {
        var id: UUID { request.id }
        let request: SecretRequest
        /// The bot that asks: a sub-agent run's own bot, else the conversation's.
        let botID: UUID
        let botName: String
        /// The conversation it asks in: "Home", or its task's title.
        let conversation: String
        let caller: UUID
        let transport: SubagentTransport
    }

    /// How long a saved secret may wait in a mailbox for its helper to take it.
    static var unreadLimit: Duration = .seconds(30)

    private(set) var waiting: [Prompt] = [] {
        didSet { if waiting.first?.id != oldValue.first?.id { present(waiting.first) } }
    }
    var current: Prompt? { waiting.first }
    /// Shows a prompt, or closes the popup for nil; the panel in the app, replaced in tests.
    @ObservationIgnored var present: (Prompt?) -> Void
    @ObservationIgnored private var asked: Set<UUID> = []
    @ObservationIgnored private var deadlines: [UUID: Task<Void, Never>] = [:]

    init(model: AppModel) {
        let panel = SecretPanel(model: model)
        present = { panel.show($0) }
    }

    /// Opens a popup for a request, once however often its file is read, until its helper stops waiting.
    func ask(_ request: SecretRequest, bot: Bot, conversation: String, caller: UUID, transport: SubagentTransport) {
        guard asked.insert(request.id).inserted else { return }
        waiting.append(Prompt(request: request, botID: bot.id, botName: bot.name, conversation: conversation,
                              caller: caller, transport: transport))
        let id = request.id
        deadlines[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(request.wait))
            guard !Task.isCancelled else { return }
            self?.withdraw(id)
        }
    }

    /// Hands what the owner pasted to the asking helper; false when there's nothing to save.
    @discardableResult func save(_ id: UUID, value: String) -> Bool {
        guard let cleaned = SecretRequest.cleaned(value), let prompt = remove(id) else { return false }
        answer(prompt, SecretResult(id: id, value: cleaned), removingAfter: Self.unreadLimit)
        return true
    }

    func cancel(_ id: UUID) {
        guard let prompt = remove(id) else { return }
        answer(prompt, SecretResult(id: id, cancelled: true), removingAfter: nil)
    }

    /// The helper stopped waiting, or its time is up: the popup closes without an answer.
    func withdraw(_ id: UUID) { remove(id) }

    /// The asking turn ended, and its helper with it.
    func endCaller(_ caller: UUID) {
        for prompt in waiting where prompt.caller == caller { remove(prompt.id) }
    }

    @discardableResult private func remove(_ id: UUID) -> Prompt? {
        deadlines.removeValue(forKey: id)?.cancel()
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
        return waiting.remove(at: index)
    }

    private func answer(_ prompt: Prompt, _ result: SecretResult, removingAfter limit: Duration?) {
        let transport = prompt.transport
        Task.detached(priority: .userInitiated) {
            guard let data = try? SubagentIPC.encode(result) else { return }
            try? await transport.writeResult(id: result.id, data: data)
            guard let limit else { return }
            try? await Task.sleep(for: limit)
            try? await transport.removeResult(id: result.id)
        }
    }
}

/// The popup: a floating panel of its own, so it shows over whatever the main window has open
/// (another sheet, Settings) and never behind it. While BotChu isn't the active app, the Dock icon
/// bounces, and the popup comes forward when it is.
@MainActor
final class SecretPanel: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var panel: NSPanel?
    private var shown: UUID?

    init(model: AppModel) {
        self.model = model
        super.init()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shown != nil else { return }
                self.panel?.makeKeyAndOrderFront(nil)
            }
        }
    }

    func show(_ prompt: SecretPrompts.Prompt?) {
        guard let prompt, let model else {
            shown = nil
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? make()
        shown = prompt.id
        panel.title = prompt.botName
        let host = NSHostingView(rootView: SecretPromptView(prompt: prompt).environment(model).id(prompt.id))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if !panel.isVisible { panel.center() }
        if NSApp.isActive {
            panel.makeKeyAndOrderFront(nil)
        } else {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240), styleMask: [.titled, .closable],
                            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = true
        panel.identifier = NSUserInterfaceItemIdentifier("secret-prompt")
        panel.delegate = self
        self.panel = panel
        return panel
    }

    /// Closing the popup cancels its request.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let shown { model?.secrets.cancel(shown) }
        return false
    }
}

/// What a bot asks for, in its words, a secure field for it, and where it will be put.
struct SecretPromptView: View {
    @Environment(AppModel.self) private var model
    let prompt: SecretPrompts.Prompt
    @State private var value = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let bot = model.bot(prompt.botID) { BotAvatar(bot: bot, size: 34) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.request.title)
                        .font(.headline)
                    Text(verbatim: "\(prompt.botName) · \(prompt.conversation)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let note = prompt.request.note {
                Text(note)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            SecureField(prompt.request.title, text: $value)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
                .accessibilityIdentifier("secret-value")
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(prompt.request.destinations.enumerated()), id: \.offset) { _, destination in
                    Label {
                        Text(verbatim: destination.label())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: destination.symbol)
                    }
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .help(destination.label())
                }
            }
            HStack {
                if model.secrets.waiting.count > 1 {
                    Text(verbatim: "1 of \(model.secrets.waiting.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.secrets.cancel(prompt.id) }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(SecretRequest.cleaned(value) == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { focused = true }
    }

    private func save() {
        if model.secrets.save(prompt.id, value: value) { value = "" }
    }
}

extension SecretDestination {
    var symbol: String {
        switch self {
        case .env: "list.bullet.rectangle"
        case .file: "doc"
        case .pipe: "terminal"
        }
    }
}
