import SwiftUI
import BotChuCore

/// New Issue (#245): the repository, the bot that writes it up and the provider it writes on, and
/// what the issue is about, in words and images. File Issue closes the sheet; the bot writes the
/// issue and BotChu files it in the background (`AppModel.fileNewIssue`).
struct NewIssueSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var request: NewIssueRequest
    @State private var editing = true

    private var repos: [String] {
        let names = (model.repositories ?? []).map(\.nameWithOwner)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return request.repo.map { names.contains($0) ? names : [$0] + names } ?? names
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("New Issue")
                .font(.headline)
                .padding(.top, 16)
            Form {
                Picker("Repository", selection: $request.repo) {
                    if request.repo == nil { Text("Choose…").tag(String?.none) }
                    ForEach(repos, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Picker("Bot", selection: Binding(get: { request.botID }, set: { $0.map { model.chooseIssueWriter($0, for: request) } })) {
                    ForEach(model.issueWriters) { bot in Text(verbatim: "\(bot.emoji)  \(bot.name)").tag(UUID?.some(bot.id)) }
                }
                Picker("Provider", selection: $request.accountID) {
                    if request.accountID == nil { Text("Choose…").tag(String?.none) }
                    ForEach(IssueDraft.accounts(model.settings.accounts)) { account in
                        Text(account.name).tag(String?.some(account.id))
                    }
                }
                DraftEditor(text: $request.text, focused: $editing, images: request.images,
                            placeholder: "What should the issue say?", minHeight: 150, maxHeight: 260, identifier: "new-issue-input")
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.newIssue = nil }
                    .keyboardShortcut(.cancelAction)
                Button("File Issue") { model.fileNewIssue(request) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.newIssueProblem(request) != nil)
                    .help(model.newIssueProblem(request) ?? "Write it up and file it in the background (⌘↩)")
            }
            .padding(16)
        }
        .frame(width: 520)
        .task { await model.loadRepositories() }
    }
}

/// The issues being written up and filed, in Projects' header: what each is doing, then its
/// number (opening it on GitHub), or why it failed with Try Again.
struct IssueFilingsStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.issueFilings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.issueFilings) { filing in row(filing) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    private func row(_ filing: IssueFiling) -> some View {
        HStack(spacing: 8) {
            if let bot = model.bot(filing.botID) { BotAvatar(bot: bot, size: 18) }
            switch filing.state {
            case .writing:
                ProgressView().controlSize(.small)
                Text("\(filing.botName) is writing an issue for \(TaskNaming.repoName(filing.repo))…")
                    .foregroundStyle(.secondary)
            case .filed(let url, let title):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                let number = url.flatMap(IssueReport.number(of:))
                Text(verbatim: number.map { "#\($0) \(title)" } ?? title)
                    .lineLimit(1)
                if let url { Link("Open ↗", destination: url) }
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(reason)
                Button("Try Again") { model.retryFiling(filing.id) }
            }
            Spacer(minLength: 0)
            if filing.state != .writing {
                Button { model.dismissFiling(filing.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
        }
        .font(.callout)
    }
}
