import SwiftUI
import BotChuCore

struct GitHubSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Section {
            HStack {
                Label("GitHub CLI", systemImage: "terminal")
                Spacer()
                if model.githubChecking { ProgressView().controlSize(.small) }
                Button("Test Connection") { Task { await model.checkGitHub() } }.disabled(model.githubChecking)
            }
            switch model.githubConnection {
            case .connected(let login, let version):
                Label("Connected as \(login) on github.com", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(version).font(.caption).foregroundStyle(.secondary)
            case .unavailable(let message): Text(message).font(.callout).foregroundStyle(.orange)
            case nil: Text("Test the gh installation and signed-in GitHub account.").foregroundStyle(.secondary)
            }
        } header: { Text("GitHub") } footer: {
            Text("Projects and metadata PRs use gh’s own login. To connect an account, run gh auth login --hostname github.com in Terminal.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
