import AppKit
import SwiftUI
import BotChuCore

/// The status sidebar for a task: its bot's face and the task's state in a card, then the task
/// (repository, issue, branch and pull request), what it runs on, its session, conversation and
/// worktree, and the actions on it.
struct TaskInspector: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    /// The pull request's state on GitHub (`OPEN`, `MERGED` or `CLOSED`), once read.
    @State private var pullRequestState: String?

    var body: some View {
        if let bot = model.bot(target.botID), let task = model.task(target), let status = model.status(of: target) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    AvatarCard(bot: bot, status: status, title: task.title, subtitle: "\(bot.name) · \(task.repo)",
                               account: task.account, faceSize: 72)
                    InspectorSection("Task") {
                        InspectorCard {
                            InspectorRow("Repository", value: task.repo)
                            if let work = task.work, !work.isPullRequest {
                                InspectorRow("Issue") {
                                    Link(work.title.isEmpty ? "#\(work.number)" : "#\(work.number) \(work.title)", destination: work.url)
                                        .foregroundStyle(Palette.accent)
                                        .truncationMode(.tail)
                                        .help(work.title)
                                }
                            }
                            InspectorRow("Branch") {
                                if task.branch.isEmpty {
                                    Text("Not made yet").foregroundStyle(Palette.secondaryText)
                                } else {
                                    HStack(spacing: 2) {
                                        Text(task.branch)
                                            .font(.system(size: 12, design: .monospaced))
                                            .truncationMode(.middle)
                                            .help(task.branch)
                                        CopyButton(text: task.branch, help: "Copy branch name")
                                    }
                                }
                            }
                            InspectorRow("Pull request") {
                                if let url = task.pullRequestURL, let number = task.pullRequest {
                                    Link(pullRequestState.map { "#\(number) · \($0.capitalized)" } ?? "#\(number)", destination: url)
                                        .foregroundStyle(Palette.accent)
                                        .help("Open pull request #\(number) on GitHub")
                                } else {
                                    Text("None yet").foregroundStyle(Palette.secondaryText)
                                }
                            }
                            InspectorRow("Started by", value: task.origin == .home ? "\(bot.name), from Home" : "You", last: true)
                        }
                    }
                    InspectorSection("Runs on") {
                        RunsOnCard(settings: task, changeAccount: model.isRunning(target) ? nil : { model.setAccount($0, for: target) })
                    }
                    InspectorSection("Session") {
                        SessionCard(session: status.session)
                    }
                    InspectorSection("Conversation") {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            StatTile(value: "\(status.messageCount)", label: "Messages", tabular: true)
                            StatTile(value: "\(status.toolCallCount)", label: "Tool calls", tabular: true)
                            StatTile(value: status.lastActivity.map(BotInspector.ago) ?? "None yet", label: "Last activity")
                            StatTile(value: task.createdAt.formatted(.dateTime.month(.abbreviated).day()), label: "Started")
                        }
                    }
                    InspectorSection("Worktree") {
                        InspectorCard(padded: true) {
                            Group {
                                if let folder = task.folder {
                                    Text((folder as NSString).abbreviatingWithTildeInPath)
                                        .foregroundStyle(Palette.pathText)
                                        .help(folder)
                                } else {
                                    Text("BotChu makes it from \((task.checkout as NSString).abbreviatingWithTildeInPath) when the task starts.")
                                        .foregroundStyle(Palette.secondaryText)
                                }
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 8) {
                            Button { model.revealWorktree(target) } label: {
                                Label("Show in Finder", systemImage: "folder")
                            }
                            Button { model.openWorktreeInTerminal(target) } label: {
                                Label("Terminal", systemImage: "terminal")
                            }
                            .help("Open the worktree in Terminal")
                        }
                        .buttonStyle(InspectorButtonStyle(fill: true))
                        .disabled(task.folder == nil)
                    }
                }
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 24, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
                // Explicit, so the sidebar's vibrancy doesn't recolor text on these opaque cards.
                .foregroundStyle(Palette.text)
            }
            .background(Palette.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actions
            }
            .task(id: "\(task.id)|\(task.pullRequest ?? 0)|\(status.phase.isActive)") {
                await readPullRequestState(task)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 8) {
                Button("Close Task") { model.closeTask(target) }
                    .buttonStyle(InspectorButtonStyle())
                    .disabled(model.isRunning(target))
                    .help("Close the task's tab. Its conversation and worktree stay, and Home's status can open it again.")
                Spacer()
                Button("New Session") { model.newSession(target) }
                    .buttonStyle(InspectorButtonStyle(prominent: true))
                    .disabled(model.isRunning(target))
                    .help("Start the task's next message in a fresh session (⌘K)")
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .background(Palette.sidebar)
        }
    }

    /// Asks GitHub whether the task's pull request is open, merged or closed.
    private func readPullRequestState(_ task: BotTask) async {
        pullRequestState = nil
        guard let number = task.pullRequest, task.repo.contains("/") else { return }
        if case .success(let found) = await GitHubLookup.work(number: number, pullRequest: true, repo: task.repo, in: task.checkout),
           !found.state.isEmpty {
            pullRequestState = found.state.lowercased()
        }
    }
}
