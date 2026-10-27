import SwiftUI
import BotChuCore

/// The connectors the conversation's provider says it has (#183), under Usage in Model & Usage:
/// what a check of its profile in this folder found, or, on a host, what Claude Code reported as
/// this session's turn started. Unknown is a sentence, never an empty list. What needs the owner
/// comes first with its action, then connected services, then tools; the provider's own entries
/// are left to Providers, which Manage opens on this profile and folder (#212).
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
        let account = model.runSettings(of: target)?.account
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = max(context.date, Date())
            InspectorSection("Connectors", trailing: task?.isRemote == true ? task.map { "on \(model.machineName($0.hostID, fallback: $0.hostName))" } : nil) {
                InspectorCard(padded: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        ConnectorCardHeader(card: card, scope: scope, kind: account?.kind, now: now)
                        if let report = card.report, let scope, let kind = account?.kind {
                            list(report, stale: isStale(card, now: now), scope: scope, kind: kind)
                        }
                        HStack(alignment: .firstTextBaseline) {
                            ConnectorCheckFooter(card: card, scope: scope, profile: account?.name, now: now)
                            Spacer(minLength: 8)
                            if let account, ConnectorSettings(account.kind) != nil {
                                Button("Manage") { model.manageConnectors(of: target) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Palette.violet)
                                    .help("Show \(account.name)’s connectors in Providers")
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // A check runs only on demand: when the section shows and the last one is over an hour old.
        .task(id: scope) {
            if case .profile = card, let scope, let kind = account?.kind { await model.connectorBoard.check(scope, kind: kind) }
        }
    }

    private func isStale(_ card: ConnectorCard, now: Date) -> Bool {
        if case .profile(let check) = card { return check?.isStale(at: now) == true }
        return false
    }

    @ViewBuilder private func list(_ report: ConnectorReport, stale: Bool, scope: ConnectorScope, kind: AgentKind) -> some View {
        let connections = report.listed(.connection)
        let tools = report.listed(.tool)
        let attention = (connections + tools).filter(\.state.needsAttention)
        let connected = connections.filter { $0.state == .connected }
        let rows = ConnectorReport(connectors: connections.filter { !$0.state.needsAttention && $0.state != .connected }).rows
        let quietTools = tools.filter { !$0.state.needsAttention }
        if connections.isEmpty && tools.isEmpty {
            Text("None").font(.system(size: 12))
        }
        if !attention.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(attention, id: \.self) { connector in
                    ConnectorRow(connector: connector, stale: stale, scope: scope, kind: kind, compact: true)
                }
            }
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
            .divided(above: !attention.isEmpty)
        }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.state) { row in
                    ConnectorStateRow(state: row.state, connectors: row.connectors, stale: stale)
                }
            }
            .divided(above: !attention.isEmpty || !connected.isEmpty)
        }
        if !quietTools.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Tools").foregroundStyle(Palette.secondaryText)
                Spacer(minLength: 4)
                Text(quietTools.map { $0.state == .connected ? $0.name : "\($0.name) · \($0.state.label)" }.joined(separator: ", "))
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(stale ? Palette.secondaryText : Palette.text)
                    .help(quietTools.map { "\($0.name): \($0.detail)" }.joined(separator: "\n"))
            }
            .font(.system(size: 12))
            .accessibilityElement(children: .combine)
            .divided(above: !attention.isEmpty || !connected.isEmpty || !rows.isEmpty)
        }
    }
}

private extension View {
    /// A hairline above, between the card's groups.
    func divided(above: Bool) -> some View {
        padding(.top, above ? 12 : 0)
            .overlay(alignment: .top) {
                if above { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
            }
    }
}

/// The card's first line: what its evidence is, and Refresh for a profile check on this Mac.
struct ConnectorCardHeader: View {
    @Environment(AppModel.self) private var model
    let card: ConnectorCard
    let scope: ConnectorScope?
    let kind: AgentKind?
    let now: Date

    var body: some View {
        HStack {
            Text(card.title)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .help(titleHelp)
            Spacer()
            if case .profile(let check) = card, let scope, let kind {
                let checking = model.connectorBoard.evidence.isChecking(scope)
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

    private var titleHelp: String {
        switch card {
        case .session(_, let current):
            current ? "What Claude Code reported as this session’s latest turn started; a connection can change after that"
                : "What an earlier session in this folder reported; the next turn reports this session’s"
        case .profile:
            "What \(kind?.displayName ?? "the CLI") lists for this profile in \(scope.map { ($0.folder as NSString).abbreviatingWithTildeInPath } ?? "this folder"), checked separately from any session"
        case .notReported: "Claude Code reports its connectors as a turn starts"
        case .notChecked: "Codex profiles are checked on this Mac only"
        case .unavailable: "BotChu can’t ask this CLI which connectors it has"
        }
    }
}

/// When the card's evidence is from, in which folder, and whether it is stale or failed.
struct ConnectorCheckFooter: View {
    @Environment(AppModel.self) private var model
    let card: ConnectorCard
    let scope: ConnectorScope?
    /// The profile's name, while its first check runs.
    let profile: String?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch card {
            case .session(let report, _):
                stamp("Reported \(RelativeDate.text(report.at, now: now))", at: report.at)
            case .profile(let check):
                profileFooter(check)
            case .unavailable, .notChecked, .notReported:
                EmptyView()
            }
        }
    }

    @ViewBuilder private func profileFooter(_ check: ConnectorCheck?) -> some View {
        let folder = scope.map { ($0.folder as NSString).lastPathComponent } ?? ""
        let checking = scope.map { model.connectorBoard.evidence.isChecking($0) } ?? false
        if let report = check?.report {
            if check?.isStale(at: now) == true {
                HStack(spacing: 4) {
                    Label("Stale", systemImage: "exclamationmark.triangle.fill").fontWeight(.medium).foregroundStyle(Palette.warning)
                    Text("· checked in \(folder) \(RelativeDate.text(report.at, now: now))").foregroundStyle(Palette.secondaryText)
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .help("Checked \(report.at.formatted(date: .complete, time: .standard))")
            } else {
                stamp("Checked in \(folder) · \(RelativeDate.text(report.at, now: now))", at: report.at)
            }
        } else if checking || check == nil {
            Text("Checking \(profile ?? "the profile")…")
                .font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
        } else if check?.error != nil {
            Label("Couldn’t check", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.warning)
        }
        if let error = check?.error {
            Text(error).font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
        }
    }

    private func stamp(_ text: String, at date: Date) -> some View {
        Text(text)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(Palette.secondaryText)
            .help(date.formatted(date: .complete, time: .standard))
    }
}

/// One connector: its name, its state as a symbol and word (never colour alone), and the action
/// its provider supports, if it needs one. A compact row with an action leaves the word to the
/// tooltip and VoiceOver.
struct ConnectorRow: View {
    @Environment(AppModel.self) private var model
    let connector: Connector
    let stale: Bool
    let scope: ConnectorScope
    let kind: AgentKind
    var compact = false

    var body: some View {
        let action = ConnectorAction.make(for: connector, kind: kind, local: scope.isLocal)
        HStack(spacing: 8) {
            if compact {
                name
                Spacer(minLength: 4)
                ConnectorStateLabel(state: connector.state, stale: stale, showsWord: action == nil)
            } else {
                // The state under the name, so neither is cut short beside the action.
                VStack(alignment: .leading, spacing: 2) {
                    name
                    HStack(spacing: 4) {
                        ConnectorStateLabel(state: connector.state, stale: stale)
                        if connector.state == .connected, let count = connector.toolCount {
                            Text("· \(count) \(count == 1 ? "tool" : "tools")").foregroundStyle(Palette.secondaryText).monospacedDigit()
                        }
                    }
                    .font(.system(size: 11))
                }
                Spacer(minLength: 4)
            }
            if let action {
                Button(action.title) { model.perform(action, connector: connector, scope: scope, kind: kind) }
                    .buttonStyle(ConnectorActionStyle())
                    .help(help(action))
                    .disabled(action == .retry && !canRetry)
            }
        }
        .font(.system(size: 12))
        .frame(minHeight: 22)
        .help("\(connector.name): \(connector.state.label) · \(connector.detail)")
        .accessibilityElement(children: .combine)
    }

    /// As Refresh: not while a check runs, nor within a minute of the last.
    private var canRetry: Bool {
        let evidence = model.connectorBoard.evidence
        return !evidence.isChecking(scope) && evidence.check(for: scope)?.canRetry(at: Date()) != false
    }

    private var name: some View {
        Text(connector.name)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(stale ? Palette.secondaryText : Palette.text)
    }

    private func help(_ action: ConnectorAction) -> String {
        switch action {
        case .signIn: "Runs “mcp login” for \(connector.name) in Terminal, as this profile in \((scope.folder as NSString).abbreviatingWithTildeInPath)"
        case .terminal: "Opens this profile’s CLI in Terminal, in \((scope.folder as NSString).abbreviatingWithTildeInPath); /mcp manages its servers"
        case .settings(let settings): "\(settings.title) in your browser, with whichever account is signed in there"
        case .retry: "Check this profile’s connectors again"
        }
    }
}

/// A state's symbol, in its colour, with its word unless the row is compact.
struct ConnectorStateLabel: View {
    let state: Connector.State
    let stale: Bool
    var showsWord = true

    private static let error = Palette.dynamic(0xD93A2F, 0xFF6B60)

    var body: some View {
        Group {
            if showsWord {
                Label(state.label, systemImage: Self.symbol(state))
            } else {
                Image(systemName: Self.symbol(state)).accessibilityLabel(state.label)
            }
        }
        .fontWeight(emphasized && !stale ? .medium : .regular)
        .foregroundStyle(stale ? Palette.secondaryText : Self.color(state))
        .lineLimit(1)
        .fixedSize()
    }

    private var emphasized: Bool { state == .needsAuth || state == .failed }

    static func symbol(_ state: Connector.State) -> String {
        switch state {
        case .connected: "checkmark.circle"
        case .needsAuth: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .pending: "hand.raised"
        case .off: "minus.circle"
        case .unconfirmed: "circle.dashed"
        case .configured: "circle.dotted"
        }
    }

    static func color(_ state: Connector.State) -> Color {
        switch state {
        case .needsAuth, .pending: Palette.warning
        case .failed: error
        default: Palette.secondaryText
        }
    }
}

/// A row's action: a small soft button.
struct ConnectorActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.buttonText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.button))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Rectangle())
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ConnectorStateLabel(state: state, stale: stale)
            Spacer(minLength: 4)
            Text(connectors.map(\.name).joined(separator: ", "))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(stale ? Palette.secondaryText : Palette.text)
                .help(connectors.map { "\($0.name): \($0.detail)" }.joined(separator: "\n"))
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }
}
