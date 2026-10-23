import SwiftUI
import BotChuCore

/// Report a Bug or Feature: one field for the report, filed as a public issue in BotChu's
/// repository with gh, beneath it the title it gets and the app state that goes with it, so nothing
/// is posted unseen.
struct ReportIssueSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var request: IssueReportRequest
    @FocusState private var editing: Bool
    @State private var showsState = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Report a Bug or Feature").font(.headline)
                Text("Files a public issue in \(IssueReport.repository) on GitHub, with gh as you're signed in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            if case .filed(let url) = request.state {
                filed(url)
            } else {
                form
            }
        }
        .frame(width: 540)
        .background(.background)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $request.text)
                .font(.system(size: 13))
                .padding(10)
                .frame(height: 170)
                .focused($editing)
                .disabled(request.state == .filing)
                .overlay(alignment: .topLeading) {
                    if request.text.isEmpty {
                        Text("What went wrong, or what would you like BotChu to do? The first line becomes the title.")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Report")
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Title") {
                    Text(request.isEmpty ? "From the report's first line" : request.title)
                        .foregroundStyle(request.isEmpty ? .tertiary : .primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
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
                    Text("Anyone can read the issue on GitHub.")
                        .font(.caption).foregroundStyle(.secondary)
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
        .task { editing = true }
    }

    private func filed(_ url: URL?) -> some View {
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
