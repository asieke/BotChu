import SwiftUI
import BotChuCore

/// An in-app sheet; ContentView sizes it from the window that presented it. A file of a bot's own,
/// opened while one of its conversations is shown, can also be saved and that conversation started
/// over in a new session that reads it (#232); Save alone leaves every session to its next new one.
struct BotDocumentEditor: View {
    @Environment(\.dismiss) private var dismiss
    /// Not in Settings' sheets, whose shared files never start a session over.
    @Environment(AppModel.self) private var model: AppModel?
    let request: DocumentEditorRequest
    @State private var draft: BotDocumentDraft?
    @State private var error: String?
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(request.name).font(.headline)
                Text(request.owner)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Button("Reload", action: load)
                    .help("Read the latest file from disk, replacing this draft")
            }
            .padding(16)
            Divider()
            if draft != nil {
                TextEditor(text: Binding(get: { draft?.text ?? "" }, set: { draft?.text = $0 }))
                    .font(.system(size: 13, design: .monospaced))
                    .padding(10)
                    .focused($editing)
                    .overlay(alignment: .topLeading) {
                        if draft?.text.isEmpty == true, !request.placeholder.isEmpty {
                            Text(request.placeholder)
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Edit \(request.name)")
            } else {
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let error {
                    Text(error)
                        .font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .center, spacing: 12) {
                    Spacer(minLength: 0)
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if restart != .unavailable {
                        Button("Save & Start New Session") { save(restarting: true) }
                            .disabled(draft == nil || restart != .ready)
                            .help(restart == .ready
                                  ? "Save, then start this conversation over in a new session that reads it"
                                  : "Available once this conversation's turn ends")
                    }
                    Button("Save") { save(restarting: false) }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == nil)
                }
            }
            .padding(16)
        }
        .background(.background)
        .task { load(); editing = true }
    }

    /// Save & Start New Session's state for the conversation shown when the file was opened.
    private var restart: DocumentSessionRestart {
        guard let model, request.conversation != nil else { return .unavailable }
        return model.sessionRestart(of: request.conversation)
    }

    private func load() {
        do {
            draft = try BotDocumentDraft(url: request.url, seed: request.seed)
            error = nil
        } catch {
            self.error = "Couldn't read \(request.name): \(error.localizedDescription)"
        }
    }

    /// Saves; restarting, only once the file is saved, and only while the conversation is still idle.
    private func save(restarting: Bool) {
        do {
            try draft?.save {
                guard restarting, restart == .ready, let model, let target = request.conversation else { return }
                model.newSession(target)
            }
            dismiss()
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
