import AppKit
import SwiftUI
import BotChuCore

/// A task's character and the same four inspector areas as Home, using this task's data and actions.
struct TaskInspector: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget

    var body: some View {
        if let bot = model.bot(target.botID), let task = model.task(target), let status = model.status(of: target) {
            let machine = model.machineName(task.hostID, fallback: task.hostName)
            InspectorPanel {
                InspectorSection("Status") {
                    AvatarCard(bot: bot, status: status, title: task.title,
                               subtitle: task.isRemote ? "on \(machine)" : "",
                               account: task.account, eyebrow: bot.name)
                }
            } content: { tab in
                switch tab {
                case .activity:
                    InspectorSection("Task") {
                        InspectorCard {
                            InspectorRow("Repository", value: task.repo)
                            InspectorRow("Machine", last: task.work?.isPullRequest != false && task.review == nil) {
                                Label(machine, systemImage: task.isRemote ? "network" : "laptopcomputer")
                                    .labelStyle(.titleAndIcon)
                                    .help(task.isRemote ? "Works on \(machine) over SSH: the CLI runs there, with \(bot.name)'s context from this Mac" : "Works on this Mac")
                            }
                            if let work = task.work, !work.isPullRequest {
                                InspectorRow("Issue", last: task.review == nil) {
                                    Link(work.title.isEmpty ? "#\(work.number)" : "#\(work.number) \(work.title)", destination: work.url)
                                        .foregroundStyle(Palette.accent)
                                        .truncationMode(.tail)
                                        .help(work.title)
                                }
                            }
                            if let review = task.review {
                                InspectorRow("Review", value: review == .comment ? "Posted on GitHub" : "In this conversation", last: true)
                            }
                        }
                    }
                    InspectorSection("Conversation") {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            StatTile(value: "\(status.messageCount)", label: "Messages", tabular: true)
                            StatTile(value: "\(status.toolCallCount)", label: "Tool calls", tabular: true)
                            StatTile(value: status.lastActivity.map(BotInspector.ago) ?? "None yet", label: "Last activity")
                            StatTile(value: task.createdAt.formatted(.dateTime.month(.abbreviated).day()), label: "Started")
                        }
                    }
                case .model:
                    InspectorSection("Runs on") {
                        RunsOnCard(settings: task, target: target, changeAccount: model.isRunning(target) ? nil : { model.setAccount($0, for: target) })
                    }
                    let usageRequest = UsageRequest(account: task.account, command: model.settings.command(for: task.account),
                        credentialRevision: task.account.kind == .pi ? model.settings.usageCredentialRevision : 0)
                    AccountUsageSection(request: usageRequest, isRunning: model.isRunning(target))
                        .id(usageRequest)
                case .session:
                    InspectorSection("Session") {
                        SessionCard(session: status.session)
                    }
                    InspectorSection("Workspace", trailing: task.isRemote ? "on \(machine)" : nil, preferenceKey: "Worktree") {
                        if task.folder == nil {
                            Text("A separate workspace will be prepared when the task starts.")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.secondaryText)
                        }
                        HStack(spacing: 8) {
                            if task.isRemote {
                                Button {
                                    if let command = model.sshCommand(for: task) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(command, forType: .string)
                                    }
                                } label: {
                                    Label("Copy SSH", systemImage: "doc.on.doc")
                                }
                                .help("Copy the ssh command that opens a shell in the workspace on \(machine)")
                            } else {
                                Button { model.revealWorktree(target) } label: {
                                    Label("Show in Finder", systemImage: "folder")
                                }
                            }
                            Button { model.openWorktreeInTerminal(target) } label: {
                                Label("Terminal", systemImage: "terminal")
                            }
                            .help(task.isRemote ? "Open a shell in the workspace on \(machine), over SSH, in Terminal" : "Open the workspace in Terminal")
                        }
                        .buttonStyle(InspectorButtonStyle(fill: true))
                        .disabled(task.folder == nil)
                    }
                case .memory:
                    MemorySection(botID: target.botID)
                }
            } actions: {
                actions
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
                    .help("Close the task's tab. Its conversation and workspace stay, and Home's status can open it again.")
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
}
