import SwiftUI
import BotChuCore

/// Settings ▸ GitHub: whether `gh` is installed and signed in, which Projects and metadata PRs use.
struct GitHubSettings: View {
    @Environment(AppModel.self) private var model
    /// What connects gh to an account, in Terminal.
    static let signIn = "gh auth login --hostname github.com"
    var body: some View {
        Section {
            HStack {
                Label("GitHub CLI", systemImage: "terminal")
                Spacer()
                if model.githubChecking { ProgressView().controlSize(.small) }
                Button("Test Connection") { Task { await model.checkGitHub() } }.disabled(model.githubChecking)
                    .help("Projects and metadata PRs use gh’s own login. To connect an account, run gh auth login --hostname github.com in Terminal.")
            }
            switch model.githubConnection {
            case .connected(let login, let version):
                Label("Connected as \(login) on github.com", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(version).font(.caption).foregroundStyle(.secondary)
            case .unavailable(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Palette.warning)
                    .textSelection(.enabled)
                // The setup step as a row to copy into Terminal (#232).
                LabeledContent("Sign in") {
                    HStack {
                        Text(verbatim: Self.signIn)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.signIn, forType: .string)
                        }
                    }
                }
            case nil:
                Label("Not tested", systemImage: "minus.circle").foregroundStyle(.secondary)
            }
        }
    }
}
