import SwiftUI
import BotChuCore

/// An in-app sheet; ContentView sizes it from the window that presented it.
struct BotDocumentEditor: View {
    @Environment(\.dismiss) private var dismiss
    let request: DocumentEditorRequest
    @State private var draft: BotDocumentDraft?
    @State private var error: String?
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.name).font(.headline)
                    Text(request.subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                    Text("Read at the start of each new session. Use New Session to apply changes to an existing conversation.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save", action: save)
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

    private func load() {
        do {
            draft = try BotDocumentDraft(url: request.url, seed: request.seed)
            error = nil
        } catch {
            self.error = "Couldn't read \(request.name): \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            try draft?.save()
            dismiss()
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
