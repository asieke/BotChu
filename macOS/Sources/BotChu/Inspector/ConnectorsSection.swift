import SwiftUI
import BotChuCore

/// The connectors the conversation's provider says it has (#183), under Usage in Model & Usage:
/// what a check of its profile in this folder found, or, on a host, what Claude Code reported as
/// this session's turn started. Unknown is a sentence, never an empty list.
struct ConnectorsSection: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    @State private var showsAll = false

    /// Connected names shown before "+N more".
    static let tokenLimit = 12

    var body: some View {
        let card = model.connectorCard(of: target)
        let scope = model.connectorScope(of: target)
        let task = model.task(target)
        let kind = model.runSettings(of: target)?.account.kind
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = max(context.date, Date())
            InspectorSection("Connectors", trailing: task?.isRemote == true ? task.map { "on \(model.machineName($0.hostID, fallback: $0.hostName))" } : nil) {
                InspectorCard(padded: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        header(card, scope: scope, now: now)
                        content(card, scope: scope, now: now)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // A check runs only on demand: when the section shows and the last one is over an hour old.
        .task(id: scope) {
            if case .profile = card, let scope, let kind { await model.connectorBoard.check(scope, kind: kind) }
        }
    }

    private func header(_ card: ConnectorCard, scope: ConnectorScope?, now: Date) -> some View {
        HStack {
            Text(card.title)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .help(titleHelp(card, scope: scope))
            Spacer()
            if case .profile(let check) = card, let scope, let kind = model.runSettings(of: target)?.account.kind {
                let checking = model.connectorBoard.evidence.checking.contains(scope)
                Button { Task { await model.connectorBoard.check(scope, kind: kind, force: true) } } label: {
                    if checking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 22, height: 22)
                .disabled(checking || check?.canRetry(at: now) == false)
                .accessibilityLabel("Check connectors again")
                .help(check?.canRetry(at: now) == false ? "Can be checked again in a minute" : "Check this profile’s connectors again")
            }
        }
    }

    @ViewBuilder private func content(_ card: ConnectorCard, scope: ConnectorScope?, now: Date) -> some View {
        switch card {
        case .session(let report, _):
            list(report, stale: false)
            footer("Reported \(RelativeDate.text(report.at, now: now))", at: report.at)
        case .profile(let check):
            let checking = scope.map { model.connectorBoard.evidence.checking.contains($0) } ?? false
            if let report = check?.report {
                list(report, stale: check?.isStale == true)
            }
            profileFooter(check, scope: scope, checking: checking, now: now)
        case .unavailable, .notChecked, .notReported:
            EmptyView()
        }
    }

    @ViewBuilder private func list(_ report: ConnectorReport, stale: Bool) -> some View {
        let connected = report.connected
        let rows = report.rows
        if report.connectors.isEmpty {
            Text("None").font(.system(size: 12))
        }
        if !connected.isEmpty {
            let shown = showsAll ? connected : Array(connected.prefix(Self.tokenLimit))
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(shown, id: \.self) { connector in
                    ConnectorToken(name: connector.name, stale: stale).help(connector.detail)
                }
                if connected.count > shown.count {
                    Button("+\(connected.count - shown.count) more") { showsAll = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .frame(height: 22)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Connected: \(connected.map(\.name).joined(separator: ", "))")
        }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.state) { row in
                    ConnectorStateRow(state: row.state, connectors: row.connectors, stale: stale)
                }
            }
            .padding(.top, connected.isEmpty ? 0 : 12)
            .overlay(alignment: .top) {
                if !connected.isEmpty { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
            }
        }
    }

    @ViewBuilder private func profileFooter(_ check: ConnectorCheck?, scope: ConnectorScope?, checking: Bool, now: Date) -> some View {
        let folder = scope.map { ($0.folder as NSString).lastPathComponent } ?? ""
        if let report = check?.report {
            if check?.isStale == true {
                HStack(spacing: 4) {
                    Label("Stale", systemImage: "exclamationmark.triangle.fill").fontWeight(.medium).foregroundStyle(Palette.warning)
                    Text("· checked in \(folder) \(RelativeDate.text(report.at, now: now))").foregroundStyle(Palette.secondaryText)
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .help("Checked \(report.at.formatted(date: .complete, time: .standard))")
            } else {
                footer("Checked in \(folder) · \(RelativeDate.text(report.at, now: now))", at: report.at)
            }
        } else if checking || check == nil {
            Text("Checking \(model.runSettings(of: target)?.account.name ?? "the profile")…")
                .font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
        } else if check?.error != nil {
            Label("Couldn’t check", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.warning)
        }
        if let error = check?.error {
            Text(error).font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
        }
    }

    private func footer(_ text: String, at date: Date) -> some View {
        Text(text)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(Palette.secondaryText)
            .help(date.formatted(date: .complete, time: .standard))
    }

    private func titleHelp(_ card: ConnectorCard, scope: ConnectorScope?) -> String {
        switch card {
        case .session(_, let current):
            current ? "What Claude Code reported as this session’s latest turn started; a connection can change after that"
                : "What an earlier session in this folder reported; the next turn reports this session’s"
        case .profile:
            "What \(model.runSettings(of: target)?.account.kind.displayName ?? "the CLI") lists for this profile in \(scope.map { ($0.folder as NSString).abbreviatingWithTildeInPath } ?? "this folder"), checked separately from this conversation’s session"
        case .notReported: "Claude Code reports its connectors as a turn starts"
        case .notChecked: "Codex profiles are checked on this Mac only"
        case .unavailable: "BotChu can’t ask this CLI which connectors it has"
        }
    }
}

/// A connected name: a soft chip, or secondary text when the list is stale.
private struct ConnectorToken: View {
    let name: String
    let stale: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(name)
            .font(.system(size: 12))
            .lineLimit(1)
            .foregroundStyle(stale ? Palette.secondaryText : Palette.text)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.055)))
    }
}

/// A state's word and symbol, never colour alone, with its names.
private struct ConnectorStateRow: View {
    let state: Connector.State
    let connectors: [Connector]
    let stale: Bool

    private static let error = Palette.dynamic(0xD93A2F, 0xFF6B60)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(state.label, systemImage: symbol)
                .fontWeight(emphasized && !stale ? .medium : .regular)
                .foregroundStyle(stale ? Palette.secondaryText : color)
                .fixedSize()
            Spacer(minLength: 4)
            Text(connectors.map(\.name).joined(separator: ", "))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(stale ? Palette.secondaryText : Palette.text)
                .help(connectors.map { "\($0.name): \($0.detail)" }.joined(separator: "\n"))
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }

    private var emphasized: Bool { state == .needsAuth || state == .failed }

    private var symbol: String {
        switch state {
        case .connected: "checkmark.circle"
        case .needsAuth: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .off: "minus.circle"
        case .unconfirmed: "circle.dashed"
        }
    }

    private var color: Color {
        switch state {
        case .needsAuth: Palette.warning
        case .failed: Self.error
        default: Palette.secondaryText
        }
    }
}
