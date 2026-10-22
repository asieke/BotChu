import AppKit
import SwiftUI
import BotChuCore

struct SubagentsInspectorContent: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    var includeBotTasksOverview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SubagentTree(target: target)
            if includeBotTasksOverview {
                ForEach(model.tasks[target.botID] ?? []) { task in
                    let scope = ChatTarget.task(task.id, of: target.botID)
                    if !(model.delegation.records[scope] ?? []).isEmpty {
                        DisclosureGroup(task.title) { SubagentTree(target: scope) }
                            .font(.system(size: 12, weight: .medium))
                    }
                }
            }
            if let error = model.delegation.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .frame(minWidth: 0, idealWidth: 240, maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("subagents-inspector")
    }
}

private struct SubagentTree: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    @State private var expanded: Set<UUID> = []
    @State private var seen: Set<UUID> = []
    private var runs: [SubagentRun] { model.delegation.records[target] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let count = runs.filter { $0.phase.isActive }.count
            Text("Sub-agents" + (count > 0 ? " · \(count) running" : ""))
                .font(.system(size: 12, weight: .semibold))
            if runs.isEmpty {
                Text("When this conversation delegates work to another bot, its progress and handoff appear here.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
            }
            ForEach(runs.filter { $0.parentSubagentID == nil }) { run in
                node(run, ancestry: [])
            }
        }
        .onChange(of: runs.map(\.id), initial: true) { _, _ in
            for run in runs where seen.insert(run.id).inserted && run.phase.isActive { expanded.insert(run.id) }
        }
    }

    // Type erasure breaks the recursive View type. An ancestry guard also keeps a malformed
    // persisted tree from recursing forever; normal runs are capped at three levels.
    private func node(_ run: SubagentRun, ancestry: Set<UUID>) -> AnyView {
        guard !ancestry.contains(run.id) else { return AnyView(EmptyView()) }
        let path = ancestry.union([run.id])
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            SubagentCard(run: run, expanded: Binding(get: { expanded.contains(run.id) }, set: {
                if $0 { expanded.insert(run.id) } else { expanded.remove(run.id) }
            }))
            ForEach(runs.filter { $0.parentSubagentID == run.id }) { child in
                node(child, ancestry: path)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 1) }
            }
        })
    }
}

private struct SubagentCard: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun
    @Binding var expanded: Bool
    private var activity: BotActivity { model.delegation.states[run.id]?.activity ?? (run.phase == .failed ? .failed : .idle) }
    private var avatarBot: Bot {
        model.bot(run.targetBotID) ?? Bot(id: run.targetBotID, name: run.targetBotName, emoji: run.targetBotEmoji,
                                        workspace: run.targetBotWorkspace, appearance: run.targetBotAppearance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        BotAvatar(bot: avatarBot, size: 25, activity: activity, animates: run.phase.isActive)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(run.targetBotName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(run.title).font(.system(size: 11)).lineLimit(2).foregroundStyle(Palette.secondaryText)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(run.targetBotName): \(run.title)")
                if run.phase.isActive {
                    Button { model.delegation.stop(run.id) } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }
                        .buttonStyle(.plain).help("Stop this sub-agent and its children")
                        .accessibilityLabel("Stop \(run.targetBotName)")
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                HStack {
                    Text(run.phase.isActive ? activity.doing : run.phase.displayName)
                        .foregroundStyle(run.phase == .failed ? Color.red : Palette.secondaryText)
                    Spacer(minLength: 0)
                    Text(BotStatus.formatElapsed(from: run.startedAt ?? run.createdAt, to: run.finishedAt ?? timeline.date))
                        .monospacedDigit().foregroundStyle(Palette.secondaryText)
                }.font(.system(size: 10))
            }
            if expanded {
                Divider()
                Text("Asked by \(callerName)").font(.system(size: 11, weight: .semibold))
                Text(run.brief).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                let messages = model.delegation.threads[run.id] ?? []
                if !messages.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(messages.filter { $0.role != .user }.suffix(30)) { message in
                                if message.role == .tool {
                                    DisclosureGroup {
                                        Text([message.toolInput, message.toolOutput].compactMap { $0 }.joined(separator: "\n"))
                                            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                    } label: {
                                        Label(message.toolName ?? "Tool", systemImage: message.toolState == .running ? "hourglass" : "checkmark")
                                            .font(.system(size: 11))
                                    }
                                } else {
                                    Text(message.text).font(.system(size: 11)).textSelection(.enabled)
                                        .foregroundStyle(message.role == .error ? Color.red : Palette.text)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 220)
                }
                if let handoff = run.handoffOutput, !handoff.isEmpty, !run.phase.isActive {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Handoff").font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(handoff, forType: .string)
                            }.buttonStyle(.borderless).font(.system(size: 11))
                        }
                        Text(handoff).font(.system(size: 11)).textSelection(.enabled)
                    }.padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Palette.accent.opacity(0.08)))
                }
                if let error = run.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                Text([run.account.name, run.model.isEmpty ? "Default model" : run.model,
                      run.workspaceMode == .sharedCallerWorkspace ? "Shared workspace" : "Bot workspace"].joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(Palette.secondaryText)
                Text(run.workingDirectory).font(.system(size: 10, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Palette.secondaryText).textSelection(.enabled)
                if !run.phase.isActive { Button("Clear run") { model.delegation.clear(run.id) }.font(.system(size: 11)).buttonStyle(.borderless) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.cardEdge))
        .accessibilityIdentifier("subagent-\(run.id.uuidString)")
    }

    private var callerName: String {
        run.parentSubagentID.flatMap { model.delegation.run($0)?.targetBotName } ?? model.bot(run.rootBotID)?.name ?? "Bot"
    }
}

extension SubagentPhase {
    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .preparing: "Preparing"
        case .running: "Working"
        case .completed: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}
