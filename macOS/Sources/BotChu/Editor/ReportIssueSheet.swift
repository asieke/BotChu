import SwiftUI
import BotChuCore

/// Report a Bug or Feature: a title (the report's first line until one is typed) and one field for
/// the report, which takes images and starts with a screenshot of the window behind the sheet, filed
/// as a public issue in BotChu's repository with gh, as its header says, beneath it the app state
/// that goes with it, so nothing is posted unseen.
struct ReportIssueSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var request: IssueReportRequest
    @State private var editing = true
    @State private var showsState = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Report a Bug or Feature").font(.headline)
                // Where it goes and who sees it, with what it attaches, in one place (#232).
                Label(IssueReport.repository + " · " + request.visibility, systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .help("Anyone can read the issue on GitHub, and see what it attaches. gh files it as you're signed in.")
            }
            .padding(16)
            Divider()
            if case .filed(let url, let problem) = request.state {
                filed(url, problem: problem)
            } else {
                form
            }
        }
        .frame(width: 540)
        .background(.background)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                // Typed, or left empty for the report's first line, which it shows until then.
                LabeledContent("Title") {
                    TextField("Title", text: $request.typedTitle,
                              prompt: Text(request.isEmpty ? "Title" : IssueReport.title(from: request.text)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
                .font(.callout)
                .disabled(request.state == .filing)
                DraftEditor(text: $request.text, focused: $editing, images: request.images,
                            placeholder: "What went wrong, or what would you like BotChu to do?",
                            editable: request.state != .filing, minHeight: 170, maxHeight: 170, identifier: "report-input")
                if let problem = request.screenshotProblem {
                    Label("No screenshot of this window is attached. " + problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup(isExpanded: $showsState) {
                    Text(request.snapshot.lines.joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } label: {
                    Text("App state sent with it")
                        .font(.callout)
                        .help("Categories and counts only: no conversations, instructions, memory, paths or names")
                }
                if case .failed(let problem) = request.state {
                    Label {
                        Text(problem)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.callout)
                    .foregroundStyle(.red)
                }
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    if request.state == .filing {
                        ProgressView().controlSize(.small)
                    }
                    Button("Cancel") { model.issueReport = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(request.state == .filing ? "Submitting…" : "Submit") {
                        Task { await request.submit(with: model.issueFiler) }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!request.canSubmit)
                    .help("Create the issue on GitHub (⌘↩)")
                }
            }
            .padding(16)
        }
    }

    private func filed(_ url: URL?, problem: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                // Verbatim: an issue number is never written "#1,234".
                Text(verbatim: url.flatMap(IssueReport.number(of:)).map { "Filed as issue #\($0). Thank you!" } ?? "Filed. Thank you!")
                    .font(.headline)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if let url {
                Link(url.absoluteString, destination: url)
            } else {
                Text("gh didn't print the issue's link.").font(.callout).foregroundStyle(.secondary)
                Link("Open BotChu's issues on GitHub", destination: IssueReport.issuesURL)
            }
            if let problem {
                Label {
                    Text(problem + "\n\nAdd what's missing to the issue on GitHub.")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Done") { model.issueReport = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

/// The toolbar button that opens Report a Bug or Feature.
struct ReportIssueButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.reportIssue() } label: {
            Label("Report a Bug or Feature", systemImage: "ladybug")
        }
        .help("Report a bug or request a feature (files a public issue on GitHub)")
        .disabled(!model.canReportIssue)
    }
}
