import AppKit
import SwiftUI
import BotChuCore

/// The look shared by the chat's activity cards.
enum ActivityStyle {
    static let radius: CGFloat = 10
    static let fill = Color.primary.opacity(0.035)
    static let edge = Color.primary.opacity(0.085)
    static let chip = Color.primary.opacity(0.06)
    static let failure = Color.red
    static let failureFill = Color.red.opacity(0.07)
    static let mono = Font.system(size: 12.5, design: .monospaced)
    static let monoSmall = Font.system(size: 11.5, design: .monospaced)
    /// File chips shown before "+N more".
    static let chipLimit = 7

    /// `0.4s`, `6.2s`, `48s`, `4m 32s`.
    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0.1 else { return nil }
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}

/// Work in progress, drawn as an animated symbol: cheaper than a progress indicator when many
/// cards run at once (seventeen sub-agents), and still under Reduce Motion.
struct ActivitySpinner: View {
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "rays")
            .font(.system(size: size, weight: .semibold))
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: !reduceMotion)
            .accessibilityLabel("Working")
    }
}

/// The quiet capsule button of a card ("Open").
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09)))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A card's frame: a soft rounded rectangle with a hairline edge.
struct ActivityCardBackground: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: ActivityStyle.radius, style: .continuous)
                .fill(tint.map { $0.opacity(0.07) } ?? ActivityStyle.fill))
            .overlay(RoundedRectangle(cornerRadius: ActivityStyle.radius, style: .continuous)
                .strokeBorder(tint.map { $0.opacity(0.35) } ?? ActivityStyle.edge))
    }
}

/// A part of a card made of several rows, one under another: the top row has the card's top
/// corners and edge, the bottom row its bottom ones, and those between only its sides.
struct ActivitySliceBackground: ViewModifier {
    let top: Bool
    let bottom: Bool

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                RoundedRectangle(cornerRadius: ActivityStyle.radius, style: .continuous).fill(ActivityStyle.fill)
                RoundedRectangle(cornerRadius: ActivityStyle.radius, style: .continuous).strokeBorder(ActivityStyle.edge)
            }
            // The card goes on beyond an open side, out of sight.
            .padding(.top, top ? 0 : -(ActivityStyle.radius + 2))
            .padding(.bottom, bottom ? 0 : -(ActivityStyle.radius + 2))
            .clipped()
        }
    }
}

extension View {
    func activityCard(tint: Color? = nil) -> some View { modifier(ActivityCardBackground(tint: tint)) }
    func activitySlice(top: Bool, bottom: Bool) -> some View { modifier(ActivitySliceBackground(top: top, bottom: bottom)) }
}

// MARK: Exploration

/// Consecutive read-only calls as one card. Live, it shows its last three calls with a spinner on
/// the current one; folded, its summary: what it explored and where, file chips and failures.
/// Opened, it is a row per call (`ExplorationHead`, `ExplorationEntrySlice`, `ExplorationFoot`), so
/// only those near the visible part are laid out, however many calls it has.
struct ExplorationCard: View, Equatable {
    @Environment(TranscriptModel.self) private var transcript
    let group: ExplorationGroup
    /// The conversation's turn is still adding to it.
    let live: Bool
    let density: ChatDensity
    let kind: AgentKind

    static func == (a: Self, b: Self) -> Bool {
        a.group == b.group && a.live == b.live && a.density == b.density && a.kind == b.kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExplorationHeader(group: group, live: live, open: false, density: density)
            if live {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.entries.suffix(3)) { entry in
                        ExplorationEntryRow(entry: entry, calls: group.calls(of: entry), kind: kind, live: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else if density != .compact, !group.files.isEmpty {
                chips.padding(.horizontal, 12).padding(.bottom, 10)
            }
            // Failures show whenever the group's body does; folded, its header counts them.
            if !group.failures.isEmpty, live || density != .compact {
                ForEach(group.failures) { failure in
                    FailureRow(failure: failure) { transcript.overrides[group.id] = true }
                }
            }
        }
        .activityCard()
        .accessibilityElement(children: .contain)
    }

    private var chips: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(group.files.prefix(ActivityStyle.chipLimit)) { file in
                FileChipView(chip: file)
            }
            if group.files.count > ActivityStyle.chipLimit {
                Button("+\(group.files.count - ActivityStyle.chipLimit) more") { transcript.overrides[group.id] = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.violet)
                    .padding(.vertical, 3)
                    .help(group.files.dropFirst(ActivityStyle.chipLimit).map(\.name).joined(separator: "\n"))
            }
        }
    }
}

/// An exploration group's header: what it explored, where and for how long; a click folds or
/// opens it.
struct ExplorationHeader: View {
    @Environment(TranscriptModel.self) private var transcript
    let group: ExplorationGroup
    let live: Bool
    let open: Bool
    let density: ChatDensity

    var body: some View {
        Button {
            guard !live else { return }
            transcript.toggle(group.id, default: false)
        } label: {
            HStack(spacing: 8) {
                if live {
                    ActivitySpinner(size: 13).foregroundStyle(Palette.violet).frame(width: 16)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                (Text(live ? "Exploring… " : "Explored ").fontWeight(.semibold)
                    + Text(live ? "\(group.calls.count) \(group.calls.count == 1 ? "call" : "calls") so far" : group.summary).fontWeight(.medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                if !group.location.isEmpty {
                    Text("in \(group.location)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                if density == .compact, !live, !open, group.failureCount > 0 {
                    Label("\(group.failureCount) failed", systemImage: "xmark.circle")
                        .foregroundStyle(ActivityStyle.failure).labelStyle(.titleAndIcon).lineLimit(1)
                }
                Spacer(minLength: 8)
                if live {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(BotStatus.formatElapsed(from: group.started, to: timeline.date)).monospacedDigit().foregroundStyle(.secondary)
                    }
                } else if let duration = ActivityStyle.duration(group.finished.timeIntervalSince(group.started)) {
                    Text(duration).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(live ? "Exploring" : open ? "Show the summary" : "Show every call")
        .accessibilityLabel(live ? "Exploring, \(group.calls.count) calls so far" : "Explored \(group.summary)" + (group.location.isEmpty ? "" : " in \(group.location)"))
    }

}

/// An opened group's first row: its header, at the top of the card its rows make.
struct ExplorationHead: View, Equatable {
    let group: ExplorationGroup
    let density: ChatDensity

    var body: some View {
        ExplorationHeader(group: group, live: false, open: true, density: density)
            .activitySlice(top: true, bottom: false)
    }
}

/// An opened group's call (or the same file read again), a row of its card.
struct ExplorationEntrySlice: View {
    let entry: ExplorationEntry
    let calls: Slice<ChunkedArray<ChatMessage>>
    let kind: AgentKind
    let last: Bool

    var body: some View {
        ExplorationEntryRow(entry: entry, calls: calls, kind: kind, live: false)
            .padding(.horizontal, 12)
            .padding(.bottom, last ? 0 : 2)
            .activitySlice(top: false, bottom: false)
    }
}

/// An opened group's last row: its failures, always visible, and the bottom of its card.
struct ExplorationFoot: View, Equatable {
    @Environment(TranscriptModel.self) private var transcript
    let group: ExplorationGroup

    static func == (a: Self, b: Self) -> Bool { a.group == b.group }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 8)
            ForEach(group.failures) { failure in
                FailureRow(failure: failure) { transcript.overrides[group.id] = true }
            }
        }
        .activitySlice(top: false, bottom: true)
    }
}

struct FileChipView: View {
    let chip: FileChip

    var body: some View {
        HStack(spacing: 4) {
            Text(chip.name).font(ActivityStyle.monoSmall).lineLimit(1).truncationMode(.middle)
            if chip.reads > 1 { Text("×\(chip.reads)").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 280, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ActivityStyle.chip))
        .help(chip.path)
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chip.path, forType: .string)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: chip.path)]) }
        }
    }
}

/// Calls that failed the same way: `7 not found` and the files, always visible.
struct FailureRow: View {
    let failure: FailureSummary
    var showAll: () -> Void

    var body: some View {
        Button(action: showAll) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "xmark.circle").foregroundStyle(ActivityStyle.failure)
                Text("\(failure.count) \(failure.reason)").fontWeight(.medium).foregroundStyle(ActivityStyle.failure).lineLimit(1)
                    .fixedSize()
                FlowLayout(spacing: 6, lineSpacing: 4) {
                    ForEach(failure.names.prefix(4), id: \.self) { name in
                        Text(name).font(ActivityStyle.monoSmall).foregroundStyle(ActivityStyle.failure.opacity(0.9)).lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(ActivityStyle.failure.opacity(0.09)))
                    }
                    if failure.names.count > 4 {
                        Text("+\(failure.names.count - 4)").foregroundStyle(ActivityStyle.failure.opacity(0.9)).padding(.vertical, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ActivityStyle.failureFill)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(failure.count) calls: \(failure.reason)\n" + failure.names.joined(separator: "\n") + "\n\nClick to show every call.")
        .accessibilityLabel("\(failure.count) \(failure.reason): \(failure.names.joined(separator: ", "))")
    }
}

/// One call of an exploration group (or the same read twice): the file or command, where, and
/// its range. Clicking it shows the call's input and output.
struct ExplorationEntryRow: View {
    @Environment(TranscriptModel.self) private var transcript
    let entry: ExplorationEntry
    let calls: Slice<ChunkedArray<ChatMessage>>
    let kind: AgentKind
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { transcript.toggleExpanded(entry.id) } label: { row }
                .buttonStyle(.plain)
                .disabled(entry.state == .running)
            // Kept by the transcript, as the row goes once scrolled far enough away.
            if transcript.isExpanded(entry.id) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(calls) { call in ToolDetail(message: call, kind: kind) }
                }
                .padding(.leading, 24)
                .padding(.bottom, 6)
            }
        }
    }

    private var row: some View {
        let activity = entry.activity
        return HStack(spacing: 8) {
            icon.frame(width: 16)
            if entry.state == .running {
                Text(activity.intent.doing).foregroundStyle(Palette.violet)
            }
            Text(activity.title).font(ActivityStyle.mono).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            if !activity.subtitle.isEmpty {
                Text(activity.subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            // The range or count stays whole; the folder gives way first.
            if let failure = entry.failure {
                Text(failure).foregroundStyle(ActivityStyle.failure).fixedSize().layoutPriority(2)
            } else if let detail = entry.detail {
                Text(detail).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize().layoutPriority(2)
            }
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(activity.command ?? activity.reads.first?.path ?? activity.title)
    }

    @ViewBuilder private var icon: some View {
        switch entry.state {
        case .running:
            ActivitySpinner()
        case .failed:
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(ActivityStyle.failure)
        case .interrupted:
            Image(systemName: "questionmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
        case .done:
            if entry.activity.isShell {
                Text("$").font(ActivityStyle.mono).foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Standalone calls

/// A command that changes something or runs long: what ran, its exit status and time, and the
/// first line of its output with the rest a click away.
struct CommandCard: View, Equatable {
    @Environment(TranscriptModel.self) private var transcript
    let item: ToolCallItem
    let density: ChatDensity
    let open: Bool
    let kind: AgentKind

    static func == (a: Self, b: Self) -> Bool {
        a.item == b.item && a.density == b.density && a.open == b.open && a.kind == b.kind
    }

    private var state: ChatMessage.ToolState { item.message.displayedToolState(for: kind) }

    var body: some View {
        let activity = item.activity
        VStack(alignment: .leading, spacing: 0) {
            Button { transcript.toggle(item.id, default: false) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "apple.terminal").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                    Text(state == .running ? "Running" : "Ran").fontWeight(.semibold)
                    Text(ToolActivity.firstLineOfCommand(activity.command ?? activity.title))
                        .font(ActivityStyle.mono).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    CallStatus(message: item.message, exitCode: activity.exitCode, state: state)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(activity.command ?? "")
            if open {
                Divider().opacity(0.6)
                ToolDetail(message: item.message, kind: kind).padding(12)
            } else if density != .compact, let output = activity.output {
                Divider().opacity(0.6)
                HStack(spacing: 10) {
                    Text(output.firstLine).font(ActivityStyle.monoSmall)
                        .foregroundStyle(state == .failed ? AnyShapeStyle(ActivityStyle.failure) : AnyShapeStyle(.secondary))
                        .lineLimit(1).truncationMode(.tail)
                    if output.moreLines > 0 {
                        Button("+\(output.moreLines) \(output.moreLines == 1 ? "line" : "lines")") { transcript.overrides[item.id] = true }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.violet)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 36)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
            }
        }
        .activityCard(tint: state == .failed ? ActivityStyle.failure : nil)
    }
}

/// `● exit 0 · 48s`, or a spinner and the running time.
struct CallStatus: View {
    let message: ChatMessage
    let exitCode: Int?
    let state: ChatMessage.ToolState

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .running:
                ActivitySpinner()
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(BotStatus.formatElapsed(from: message.date, to: timeline.date)).monospacedDigit()
                }
            case .interrupted:
                Image(systemName: "questionmark.circle").help("No completion was recorded")
                Text("unknown")
            case .done, .failed:
                Circle().fill(state == .failed ? ActivityStyle.failure : Color.green).frame(width: 7, height: 7)
                Text([exitCode.map { "exit \($0)" } ?? (state == .failed ? "failed" : "done"),
                      message.toolDuration.flatMap(ActivityStyle.duration)].compactMap { $0 }.joined(separator: " · "))
                    .monospacedDigit()
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(state == .failed ? AnyShapeStyle(ActivityStyle.failure) : AnyShapeStyle(.secondary))
        .fixedSize()
    }
}

/// An edit: the file, where it is, and the lines added and removed.
struct EditCard: View, Equatable {
    @Environment(TranscriptModel.self) private var transcript
    let item: ToolCallItem
    let open: Bool
    let kind: AgentKind

    static func == (a: Self, b: Self) -> Bool { a.item == b.item && a.open == b.open && a.kind == b.kind }

    var body: some View {
        let activity = item.activity
        let state = item.message.displayedToolState(for: kind)
        VStack(alignment: .leading, spacing: 0) {
            Button { transcript.toggle(item.id, default: false) } label: {
                HStack(spacing: 8) {
                    Group {
                        if state == .running { ActivitySpinner() } else { Image(systemName: "pencil.line").foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 12)).frame(width: 16)
                    Text(state == .running ? "Editing" : activity.verb ?? "Edited").fontWeight(.semibold)
                    Text(activity.title).font(ActivityStyle.mono).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    if !activity.subtitle.isEmpty {
                        Text(activity.subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    if state == .failed {
                        Text(activity.failure ?? "failed").foregroundStyle(ActivityStyle.failure)
                    } else if let diff = activity.diff {
                        (Text("+\(diff.added)").foregroundColor(.green) + Text(diff.removed > 0 ? " −\(diff.removed)" : "").foregroundColor(.red))
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(activity.edits.joined(separator: "\n"))
            if open {
                Divider().opacity(0.6)
                ToolDetail(message: item.message, kind: kind).padding(12)
            }
        }
        .activityCard(tint: state == .failed ? ActivityStyle.failure : nil)
    }
}

/// A sub-agent BotChu ran for this conversation (`botchu-subagent`): who, on what, how it's going,
/// and Open, into its thread in the status sidebar's Sub-agents tab.
struct SubagentChatCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showsStatus") private var showsStatus = true
    @AppStorage(InspectorTab.storageKey) private var inspectorTab: InspectorTab = .activity
    let run: SubagentRun

    private var avatarBot: Bot {
        model.bot(run.targetBotID) ?? Bot(id: run.targetBotID, name: run.targetBotName, emoji: run.targetBotEmoji,
                                        workspace: run.targetBotWorkspace, appearance: run.targetBotAppearance)
    }

    var body: some View {
        let activity = model.delegation.states[run.id]?.activity ?? (run.phase == .failed ? .failed : .idle)
        HStack(alignment: .center, spacing: 12) {
            BotAvatar(bot: avatarBot, size: 34, activity: activity, animates: false)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(run.targetBotName).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    SubagentBadge()
                }
                Text(run.title).font(.system(size: 13)).lineLimit(2)
                statusLine(activity: activity)
            }
            Spacer(minLength: 8)
            Button("Open") {
                SubagentFocus.shared.focus(run.id)
                inspectorTab = .subagents
                showsStatus = true
            }
            .buttonStyle(CardButtonStyle())
            .help("Show \(run.targetBotName)'s thread in the Sub-agents tab")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .activityCard(tint: run.phase == .failed ? ActivityStyle.failure : Palette.violet)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(run.targetBotName), sub-agent: \(run.title), \(run.phase.displayName)")
    }

    @ViewBuilder private func statusLine(activity: BotActivity) -> some View {
        let counts = model.delegation.threads.counts(run.id)
        if run.phase.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                HStack(spacing: 5) {
                    ActivitySpinner()
                    Text(([activity.doing, BotStatus.formatElapsed(from: run.startedAt ?? run.createdAt, to: timeline.date)] + counts.parts)
                        .joined(separator: " · "))
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        } else {
            HStack(spacing: 5) {
                Image(systemName: run.phase == .completed ? "checkmark.circle" : run.phase == .failed ? "xmark.circle" : "stop.circle")
                Text(([run.phase.displayName, BotStatus.formatElapsed(from: run.startedAt ?? run.createdAt, to: run.finishedAt ?? run.createdAt)]
                      + counts.parts).joined(separator: " · "))
            }
            .font(.system(size: 12))
            .foregroundStyle(run.phase == .failed ? AnyShapeStyle(ActivityStyle.failure) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            if let error = run.errorMessage, run.phase == .failed {
                Text(error).font(.system(size: 12)).foregroundStyle(ActivityStyle.failure).lineLimit(2).textSelection(.enabled)
            } else if let handoff = run.handoffOutput, !handoff.isEmpty {
                Text(handoff.split(separator: "\n").first.map(String.init) ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    .help(handoff)
            }
        }
    }
}

struct SubagentBadge: View {
    var body: some View {
        Text("Sub-agent").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.violet)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Palette.violet.opacity(0.15)))
    }
}

/// A sub-agent the CLI started itself (Claude Code's Task, Antigravity's invoke_subagent). BotChu
/// has no thread for it; Open shows the call's prompt and result.
struct NativeSubagentCard: View, Equatable {
    @Environment(TranscriptModel.self) private var transcript
    let item: ToolCallItem
    let open: Bool
    let kind: AgentKind

    static func == (a: Self, b: Self) -> Bool { a.item == b.item && a.open == b.open && a.kind == b.kind }

    var body: some View {
        let state = item.message.displayedToolState(for: kind)
        let subagent = item.activity.nativeSubagent ?? NativeSubagent(kind: "", task: item.activity.title)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.clock")
                    .font(.system(size: 22)).foregroundStyle(Palette.violet).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(subagent.kind.isEmpty ? "Sub-agent" : subagent.kind).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        SubagentBadge()
                    }
                    Text(subagent.task).font(.system(size: 13)).lineLimit(2)
                    HStack(spacing: 6) {
                        if state == .running { ActivitySpinner() }
                        CallStatusText(message: item.message, state: state)
                    }
                    .font(.system(size: 12)).foregroundStyle(state == .failed ? AnyShapeStyle(ActivityStyle.failure) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 8)
                Button(open ? "Close" : "Open") { transcript.toggle(item.id, default: false) }
                    .buttonStyle(CardButtonStyle())
                    .help("Show what it was asked and what it reported")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if open {
                Divider().opacity(0.6)
                ToolDetail(message: item.message, kind: kind).padding(12)
            }
        }
        .activityCard(tint: state == .failed ? ActivityStyle.failure : Palette.violet)
    }
}

/// `Done · 1:12`, `Working · 0:31`.
struct CallStatusText: View {
    let message: ChatMessage
    let state: ChatMessage.ToolState

    var body: some View {
        switch state {
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text("Working · " + BotStatus.formatElapsed(from: message.date, to: timeline.date)).monospacedDigit()
            }
        case .done, .failed, .interrupted:
            Text([state == .done ? "Done" : state == .failed ? "Failed" : "No result recorded",
                  message.toolDuration.map { BotStatus.formatElapsed(from: message.date, to: message.date.addingTimeInterval($0)) }]
                .compactMap { $0 }.joined(separator: " · "))
                .monospacedDigit()
        }
    }
}

/// `botchu-subagent wait`: one line for the runs it waits for, whose cards show above.
struct WaitRow: View, Equatable {
    @Environment(TranscriptModel.self) private var transcript
    let item: ToolCallItem
    let runs: [SubagentRun]
    let open: Bool
    let kind: AgentKind

    static func == (a: Self, b: Self) -> Bool { a.item == b.item && a.runs == b.runs && a.open == b.open && a.kind == b.kind }

    var body: some View {
        let state = item.message.displayedToolState(for: kind)
        let count = max(runs.count, item.activity.delegation?.waitsFor ?? 0)
        let failed = runs.filter { $0.phase == .failed || $0.phase == .stopped }.count
        VStack(alignment: .leading, spacing: 0) {
            Button { transcript.toggle(item.id, default: false) } label: {
                HStack(spacing: 8) {
                    Group {
                        if state == .running { ActivitySpinner() } else { Image(systemName: "arrow.triangle.merge").foregroundStyle(.secondary) }
                    }
                    .frame(width: 16)
                    Text(state == .running ? "Waiting for \(count) \(count == 1 ? "sub-agent" : "sub-agents")…"
                         : "Collected \(count) \(count == 1 ? "handoff" : "handoffs")").fontWeight(.medium)
                    if failed > 0 { Text("· \(failed) didn't finish").foregroundStyle(ActivityStyle.failure) }
                    Spacer(minLength: 8)
                    CallStatusText(message: item.message, state: state).foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Divider().opacity(0.6)
                ToolDetail(message: item.message, kind: kind).padding(12)
            }
        }
        .activityCard()
    }
}

/// A plan update, a question or another tool: one line, with its details a click away.
struct CompactToolCard: View, Equatable {
    @Environment(TranscriptModel.self) private var transcript
    let item: ToolCallItem
    let open: Bool
    let kind: AgentKind

    static func == (a: Self, b: Self) -> Bool { a.item == b.item && a.open == b.open && a.kind == b.kind }

    var body: some View {
        let activity = item.activity
        let state = item.message.displayedToolState(for: kind)
        VStack(alignment: .leading, spacing: 0) {
            Button { transcript.toggle(item.id, default: false) } label: {
                HStack(spacing: 8) {
                    Group {
                        switch state {
                        case .running: ActivitySpinner()
                        case .failed: Image(systemName: "xmark.circle").foregroundStyle(ActivityStyle.failure)
                        case .interrupted: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                        case .done: Image(systemName: symbol).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 16)
                    Text(activity.title).fontWeight(.medium).lineLimit(1)
                    if !activity.subtitle.isEmpty {
                        Text(activity.subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    if let failure = activity.failure {
                        Text(failure).foregroundStyle(ActivityStyle.failure).lineLimit(1)
                    } else if let detail = activity.detail {
                        Text(detail).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.message.toolName ?? "")
            if open {
                Divider().opacity(0.6)
                ToolDetail(message: item.message, kind: kind).padding(12)
            }
        }
        .activityCard(tint: state == .failed ? ActivityStyle.failure : nil)
    }

    private var symbol: String {
        switch item.activity.intent {
        case .plan: "checklist"
        case .question: "questionmark.bubble"
        case .subagent: "person.2"
        default: "wrench.and.screwdriver"
        }
    }
}

// MARK: Details

/// A call's original input (its arguments, pretty-printed) and output, for when a card is opened.
/// Long output shows its start, and Copy takes all of it.
struct ToolDetail: View {
    let message: ChatMessage
    let kind: AgentKind
    static let shownOutput = 20_000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.displayedToolState(for: kind) == .interrupted {
                Text("No completion was recorded for this tool call.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(message.toolName ?? "Tool").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                DetailCopyButton(label: "Copy Input", text: input)
            }
            DetailText(text: input)
            if let output = message.toolOutput, !output.isEmpty {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text(output.utf8.count > Self.shownOutput ? "Output · first \(Self.shownOutput / 1000) KB of \(ByteCountFormatter.string(fromByteCount: Int64(output.utf8.count), countStyle: .file))" : "Output")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    DetailCopyButton(label: "Copy Output", text: output)
                }
                ScrollView {
                    DetailText(text: String(output.prefix(Self.shownOutput)))
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private var input: String {
        if let arguments = message.toolArguments, let object = ToolArguments.parse(arguments),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: data, as: UTF8.self)
        }
        return message.toolInput ?? ""
    }
}

struct DetailText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailCopyButton: View {
    let label: String
    let text: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Label(label, systemImage: "doc.on.doc").labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
    }
}

/// Views laid out left to right, wrapping onto new lines: file chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += line + lineSpacing
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, min(x - spacing, width))
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            size.width = min(size.width, bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += line + lineSpacing
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

extension ToolActivity {
    /// A command's first line, marked when more follow (a heredoc, a script).
    static func firstLineOfCommand(_ command: String) -> String {
        let lines = command.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else { return command }
        return lines.count > 1 ? first + " …" : String(first)
    }
}
