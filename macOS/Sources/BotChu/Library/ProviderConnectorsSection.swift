import SwiftUI
import BotChuCore

/// The selected profile's connectors in Providers (#212), checked in one named folder (a
/// conversation's, as its Manage chose, or the profile's default), every entry with its state and
/// the action its provider supports: Connections, Tools, and the provider's own entries folded
/// under System. Management stays the provider's: its settings in the browser, or its CLI in
/// Terminal, as this profile in this folder.
struct ProviderConnectorsSection: View {
    @Environment(AppModel.self) private var model
    let account: Account

    var body: some View {
        let workspace = model.connectorWorkspace(for: account)
        let card = model.connectorCard(of: workspace, kind: account.kind)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = max(context.date, Date())
            let stale: Bool = if case .profile(let check) = card { check?.isStale(at: now) == true } else { false }
            InspectorSection("Connectors", trailing: summary(card.report), preferenceKey: "provider.connectors") {
                VStack(alignment: .leading, spacing: 10) {
                    InspectorCard {
                        folderPicker(workspace)
                        Rectangle().fill(Palette.rowDivider).frame(height: 1)
                        VStack(alignment: .leading, spacing: 10) {
                            ConnectorCardHeader(card: card, scope: workspace.scope, kind: account.kind, now: now)
                            ConnectorCheckFooter(card: card, scope: workspace.scope, profile: account.name, now: now)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                    }
                    if let report = card.report {
                        groups(report, stale: stale, scope: workspace.scope)
                    }
                    actions(workspace.scope)
                }
            }
        }
        .task(id: workspace.scope) {
            if case .profile = card { await model.connectorBoard.check(workspace.scope, kind: account.kind) }
        }
    }

    private func summary(_ report: ConnectorReport?) -> String? {
        guard let report else { return nil }
        let visible = report.connectors.filter { $0.category != .system }
        let attention = visible.filter(\.state.needsAttention).count
        if attention > 0 { return "\(attention) need\(attention == 1 ? "s" : "") attention" }
        return "\(visible.filter { $0.state == .connected }.count) connected"
    }

    /// Which folder (and computer) the profile is checked in, by name, and the others to choose.
    private func folderPicker(_ workspace: ConnectorWorkspace) -> some View {
        InspectorRow("Folder", last: true) {
            Menu {
                ForEach(model.connectorWorkspaces(for: account)) { choice in
                    Button { model.providerConnectorWorkspace = choice } label: {
                        Text(title(choice)) + Text("  " + place(choice)).foregroundStyle(.secondary)
                    }
                }
            } label: {
                InspectorChoiceLabel(title: title(workspace))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help(place(workspace))
            .accessibilityLabel("Folder: \(title(workspace)), \(place(workspace))")
        }
    }

    private func title(_ workspace: ConnectorWorkspace) -> String {
        guard let hostID = workspace.scope.hostID else { return workspace.title }
        return "\(workspace.title) on \(model.machineName(hostID))"
    }

    private func place(_ workspace: ConnectorWorkspace) -> String {
        (workspace.scope.folder as NSString).abbreviatingWithTildeInPath
    }

    @ViewBuilder private func groups(_ report: ConnectorReport, stale: Bool, scope: ConnectorScope) -> some View {
        let connections = report.listed(.connection)
        let tools = report.listed(.tool)
        let system = report.listed(.system)
        if report.connectors.isEmpty {
            InspectorCard(padded: true) { Text("None").font(.system(size: 12)) }
        }
        if !connections.isEmpty { group(.connection, connections, stale: stale, scope: scope) }
        if !tools.isEmpty { group(.tool, tools, stale: stale, scope: scope) }
        if !system.isEmpty {
            // Folded until opened, and remembered so: the provider's own plumbing, there to look up.
            InspectorSection(Connector.Category.system.title, trailing: "\(system.count)", preferenceKey: "provider.connectors.system",
                             expandedByDefault: false) {
                rows(system, stale: stale, scope: scope)
            }
        }
    }

    private func group(_ category: Connector.Category, _ list: [Connector], stale: Bool, scope: ConnectorScope) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(category.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 4)
            rows(list, stale: stale, scope: scope)
        }
    }

    private func rows(_ list: [Connector], stale: Bool, scope: ConnectorScope) -> some View {
        InspectorCard {
            ForEach(Array(list.enumerated()), id: \.element) { index, connector in
                ConnectorRow(connector: connector, stale: stale, scope: scope, kind: account.kind)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) {
                        if index < list.count - 1 { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
                    }
            }
        }
    }

    /// The provider's own places to manage connectors: its settings, and its CLI here (this Mac only).
    @ViewBuilder private func actions(_ scope: ConnectorScope) -> some View {
        if let settings = ConnectorSettings(account.kind) {
            VStack(spacing: 8) {
                Button { model.perform(.settings(settings), connector: nil, scope: scope, kind: account.kind) } label: {
                    Label(settings.title, systemImage: "arrow.up.right.square")
                }
                .help("Opens in your browser, with whichever account is signed in there")
                if scope.isLocal {
                    Button { model.perform(.terminal, connector: nil, scope: scope, kind: account.kind) } label: {
                        Label("Open in Terminal", systemImage: "terminal")
                    }
                    .help("Opens \(account.name) in \((scope.folder as NSString).abbreviatingWithTildeInPath); /mcp manages its servers")
                }
            }
            .buttonStyle(InspectorButtonStyle(fill: true))
        }
    }
}
