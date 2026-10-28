import AppKit
import SwiftUI
import BotChuCore

struct SensitiveInputSheet: View {
    let prompt: SensitiveInputRuntime.Prompt
    let runtime: SensitiveInputRuntime
    @State private var value = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Sensitive Information", systemImage: "lock.shield")
                .font(.title2.bold())
            Text("\(prompt.botName) requests: \(prompt.request.label)")
            Text("Save directly to this new file on this Mac:")
            Text(prompt.request.destination)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Sensitive value", text: $value)
                .disabled(runtime.saving.contains(prompt.id))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .privacySensitive()
                .accessibilityIdentifier("sensitive-value")
            Text("The value goes only to this file, with owner-only permissions. It stays there until you delete it. BotChu sends only a status to the agent. Programs with access to the file can read it; keep it out of source control.")
                .font(.callout).foregroundStyle(.secondary)
            if let problem { Text(problem).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { value = ""; runtime.finish(prompt.id) }
                    .keyboardShortcut(.cancelAction)
                Button(runtime.saving.contains(prompt.id) ? "Saving…" : "Save to File") {
                    let submitted = value
                    value = ""
                    Task {
                        do { try await runtime.submit(submitted, id: prompt.id) }
                        catch {
                            problem = (error as? SensitiveInputError)?.errorDescription ?? "The value could not be saved."
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(value.isEmpty || value.utf8.count > 65536 || runtime.saving.contains(prompt.id))
            }
        }
        .padding(24).frame(width: 520)
        .onAppear { focused = true }
        .onDisappear { value = ""; runtime.finish(prompt.id) }
    }
}

/// Separate from document/settings sheets so a waiting tool is always reachable.
@MainActor
final class SensitiveInputPanel: NSObject, NSWindowDelegate {
    private weak var runtime: SensitiveInputRuntime?
    private var panel: NSPanel?
    private var shown: UUID?

    init(runtime: SensitiveInputRuntime) {
        self.runtime = runtime
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(activate),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func activate() {
        if shown != nil { panel?.makeKeyAndOrderFront(nil) }
    }

    func show(_ prompt: SensitiveInputRuntime.Prompt?) {
        guard let prompt, let runtime else {
            shown = nil
            panel?.orderOut(nil)
            panel?.contentView = nil
            return
        }
        let window: NSPanel
        if let panel { window = panel } else {
            window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 568, height: 350),
                styleMask: [.titled, .closable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.isFloatingPanel = true
            window.hidesOnDeactivate = true
            window.sharingType = .none
            window.identifier = NSUserInterfaceItemIdentifier("sensitive-input")
            window.delegate = self
            panel = window
        }
        shown = prompt.id
        window.title = "Sensitive Information"
        let host = NSHostingView(rootView: SensitiveInputSheet(prompt: prompt, runtime: runtime).id(prompt.id))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        if !window.isVisible { window.center() }
        if NSApp.isActive { window.makeKeyAndOrderFront(nil) }
        else { NSApp.requestUserAttention(.informationalRequest) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let shown { runtime?.finish(shown) }
        return false
    }
}
