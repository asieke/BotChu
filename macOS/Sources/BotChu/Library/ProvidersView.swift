import AppKit
import SwiftUI
import BotChuCore

/// Every CLI profile in one table: its 5-hour and Weekly allowance by model group, its credits and
/// free resets, and the agents set to it. The columns are fixed widths for the table's size
/// (`ProvidersColumns`) and Agents takes the rest; a row’s second line names its family, and the plan its CLI reports, until
/// something is wrong, and says what. One freshness for the page is in the heading, with Refresh.
/// The numbers come from the app's usage board, kept current in the background and saved between
/// launches, so the table opens on them without checking. Selecting a profile shows it on the right.
struct ProvidersView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var adding = false
    @State private var sortOrder: [KeyPathComparator<ProviderRow>] = []
    @State private var removing: Account?
    /// Refresh is checking every profile again.
    @State private var refreshing = false
    /// The table's width, which its columns are worked out from.
    @State private var tableWidth = 0.0
    private var matches: [Account] {
        model.settings.accounts.filter { query.isEmpty || [$0.name, $0.kind.displayName].joined(separator: " ").localizedCaseInsensitiveContains(query) }
    }
    private func request(_ account: Account) -> UsageRequest { model.usageRequest(for: account) }

    var body: some View {
        let board = model.usageBoard
        let requests = model.usageRequests
        VStack(alignment: .leading, spacing: 0) {
            LibraryHeading(title: "Providers", count: model.settings.accounts.count) {
                ProvidersFreshness(requests: requests, refreshing: refreshing)
                // Never disabled: each profile keeps its own limit, so Muse is asked at most every five minutes.
                Button { refresh(requests) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Check every profile’s allowance again, as often as each allows")
                Button { adding = true } label: { Label("New Profile", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            LibrarySearch(text: $query, prompt: "Search providers").padding(.horizontal, 24).padding(.bottom, 16)
            if matches.isEmpty {
                LibraryEmpty(title: "No matching providers", subtitle: "Try a profile name or CLI family.", symbol: "terminal")
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    // The timeline's date is its last tick, before a reading made since.
                    let now = max(context.date, Date())
                    let newest = ProviderRow.newest(requests.map { board.states[$0] })
                    let rows = matches.map { account in
                        let request = request(account)
                        return ProviderRow(request: request, state: board.states[request], checking: board.checking.contains(request),
                                           found: board.found[request.command], newest: newest, now: now)
                    }
                    // Made once its width is known, and made anew in another size: the table itself
                    // resizes only the column that takes the rest, and a width changed after it is
                    // laid out would come on top of that.
                    if tableWidth > 0 {
                        ProvidersTable(rows: rows.sorted(using: sortOrder), columns: ProvidersColumns(width: tableWidth), sortOrder: $sortOrder, now: now,
                                       changeCommand: changeCommand, remove: { removing = $0 })
                    } else {
                        Color.clear
                    }
                }
                .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { tableWidth = $0 }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor)).frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity).navigationTitle("Providers")
        .sheet(isPresented: $adding) { AddProviderSheet().environment(model) }
        // Every profile, not only the ones the search shows, at the shorter interval while shown;
        // the cache decides when a check is due.
        .task(id: requests) { await board.watch(requests, usage: model.usage, openRouterKey: model.openRouterKey) }
        // The selected profile; closing the sidebar deselects it.
        .inspector(isPresented: Binding(get: { model.providerSelection != nil }, set: { if !$0 { model.providerSelection = nil } })) {
            Group {
                if let account = model.settings.accounts.first(where: { $0.id == model.providerSelection }) {
                    ProviderInspector(account: account, changeCommand: changeCommand, remove: { removing = account })
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 480)
        }
        .confirmationDialog("Remove \(removing?.name ?? "profile")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { account in
            Button("Remove Profile", role: .destructive) { remove(account) }
        } message: { _ in
            Text("It leaves Providers and the account menus. Agents set to it keep its CLI family and command; its sign-in stays with the CLI.")
        }
    }

    /// Settings, at Accounts, where each profile's command is.
    private func changeCommand() {
        model.openSettings(.accounts)
    }

    private func refresh(_ requests: [UsageRequest]) {
        refreshing = true
        Task {
            await withTaskGroup(of: Void.self) { group in
                for request in requests {
                    group.addTask { await model.usageBoard.refresh(request, usage: model.usage, openRouterKey: model.openRouterKey, for: .manual) }
                }
            }
            refreshing = false
        }
    }

    private func remove(_ account: Account) {
        if model.providerSelection == account.id { model.providerSelection = nil }
        model.settings.customAccounts.removeAll { $0.id == account.id }
        model.settings.commands[account.id] = nil
        model.connectorBoard.prune()
    }
}

/// The page's freshness, as Projects shows its sync: when the newest reading was made, that Refresh
/// is checking, or, before anything is read, that the first checks are under way. The background's
/// own checks don't change it until they bring a reading.
private struct ProvidersFreshness: View {
    @Environment(AppModel.self) private var model
    let requests: [UsageRequest]
    let refreshing: Bool

    var body: some View {
        let board = model.usageBoard
        let newest = ProviderRow.newest(requests.map { board.states[$0] })
        let checking = newest == nil && requests.contains { board.checking.contains($0) }
        if refreshing || checking { ProgressView().controlSize(.small) }
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Group {
                if refreshing || checking {
                    Text(checking ? "Checking…" : "Updating…")
                } else if let newest {
                    Text("Updated \(RelativeDate.text(newest, now: max(context.date, Date())))").monospacedDigit()
                        .help("Read \(newest.formatted(date: .complete, time: .standard))")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// The profiles, one row each, sortable by name and by the highest share used in 5-hour or Weekly.
private struct ProvidersTable: View {
    @Environment(AppModel.self) private var model
    let rows: [ProviderRow]
    let columns: ProvidersColumns
    @Binding var sortOrder: [KeyPathComparator<ProviderRow>]
    let now: Date
    let changeCommand: () -> Void
    let remove: (Account) -> Void

    var body: some View {
        let spacing = ProvidersColumns.spacing
        let meter = columns.meter
        let selection = Binding<String?>(get: { model.providerSelection }, set: { model.providerSelection = $0 })
        let bots = Dictionary(grouping: model.bots, by: \.accountID)
        // Agents goes first when the table is too narrow for every column.
        var visibility = TableColumnCustomization<ProviderRow>()
        visibility[visibility: "agents"] = columns.showsAgents ? .visible : .hidden
        // The cells that read the model are given it, so a cell still has it while a removed
        // profile's row goes.
        return Table(rows, selection: selection, sortOrder: $sortOrder, columnCustomization: .constant(visibility)) {
            TableColumn("Provider", value: \ProviderRow.name) { (row: ProviderRow) in
                ProviderNameCell(row: row, now: now, changeCommand: changeCommand).environment(model)
            }
            .width(columns.provider - spacing)
            TableColumn("Models") { (row: ProviderRow) in ProviderModelsCell(row: row) }
                .width(columns.models - spacing)
            TableColumn("5-hour", value: \ProviderRow.shortShare) { (row: ProviderRow) in ProviderWindowsCell(row: row, long: false, layout: meter) }
                .width(columns.window - spacing)
            TableColumn("Weekly", value: \ProviderRow.longShare) { (row: ProviderRow) in ProviderWindowsCell(row: row, long: true, layout: meter) }
                .width(columns.window - spacing)
            TableColumn("Credits & resets") { (row: ProviderRow) in ProviderCreditsCell(row: row) }
                .width(min: columns.credits - spacing, ideal: columns.credits - spacing, max: columns.showsAgents ? columns.credits - spacing : nil)
            TableColumn("Agents") { (row: ProviderRow) in ProviderAgentsCell(bots: bots[row.id] ?? []).environment(model) }
                .width(min: 56 - spacing)
                .customizationID("agents")
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .id("\(columns.size) \(columns.showsAgents)")
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) { menu(row.account) }
        }
    }

    @ViewBuilder private func menu(_ account: Account) -> some View {
        let request = model.usageRequest(for: account)
        Button("Refresh") { Task { await model.usageBoard.refresh(request, usage: model.usage, openRouterKey: model.openRouterKey, for: .manual) } }
        Button("Copy Command") { copy(request.command) }
        Button("Change Command…", action: changeCommand)
        // Home and the Tasks started after use the profile; Tasks under way keep theirs.
        let agents = model.bots.filter { !$0.isRemoteQueue }
        if !agents.isEmpty {
            Divider()
            Menu("Assign to Agent") {
                ForEach(agents) { bot in
                    Toggle(bot.name, isOn: Binding(get: { bot.accountID == account.id },
                                                   set: { if $0 { model.setAccount(account.id, for: .home(bot.id)) } }))
                        .disabled(model.isRunning(.home(bot.id)))
                }
            }
        }
        if model.settings.customAccounts.contains(where: { $0.id == account.id }) {
            Divider()
            Button("Remove Profile…", role: .destructive) { remove(account) }
        }
    }
}

/// Puts a command on the clipboard.
@MainActor private func copy(_ command: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
}

/// Each line of a row is this tall, and a row has 10 points above and below its tallest cell: this
/// much in the cell, and the 4 the table adds.
private enum ProviderLine {
    static let height = 18.0
    static let padding = 6.0
}

/// What a row's allowance cells show.
private enum ProviderRowContent {
    /// Nothing read yet, a check under way: empty tracks.
    case checking
    /// Nothing read, the check failed or the command is missing: a dash.
    case unavailable
    /// A reading with no windows, and what it says instead.
    case note(String)
    case groups([UsageGroup])

    init(_ row: ProviderRow) {
        if !row.groups.isEmpty { self = .groups(row.groups) }
        else if let note = row.note { self = .note(note) }
        else if row.status == .checking { self = .checking }
        else { self = .unavailable }
    }
}

/// The logo, the name and line 2: the family, its age when it lags the page's newest reading, or the
/// problem as a button that opens its cause and Try Again.
private struct ProviderNameCell: View {
    let row: ProviderRow
    let now: Date
    let changeCommand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProviderLogo(kind: row.account.kind, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                status
            }
        }
        .frame(minHeight: 2 * ProviderLine.height, alignment: .leading)
        .padding(.vertical, ProviderLine.padding)
        .help("\(row.name) · \(row.family)")
    }

    @ViewBuilder private var status: some View {
        let family = row.family
        Group {
            switch row.status {
            case .current: Text(family)
            case .behind(let date): Text("\(family) · \(RelativeDate.text(date, now: now))").monospacedDigit()
            case .checking:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Checking…")
                }
            case .stale, .failed, .missingCommand:
                ProviderProblemButton(row: row, now: now, changeCommand: changeCommand)
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// A row's problem, in the warning colour: Stale · 2h ago, Usage unavailable, Command not found.
/// It opens what went wrong, with Try Again, and Change Command… for a missing command.
private struct ProviderProblemButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.backgroundProminence) private var prominence
    let row: ProviderRow
    let now: Date
    let changeCommand: () -> Void
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails = true } label: {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                Text(label).monospacedDigit().lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(Palette.warning))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Show what went wrong")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            ProviderProblemDetails(account: row.account, status: row.status, changeCommand: {
                showsDetails = false
                changeCommand()
            })
            .environment(model)
        }
    }

    private var label: String {
        switch row.status {
        case .stale(let date): "Stale · \(RelativeDate.text(date, now: now))"
        case .missingCommand: "Command not found"
        default: "Usage unavailable"
        }
    }
}

/// What went wrong with a profile's reading, and Try Again, which waits for the profile's own limit.
private struct ProviderProblemDetails: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let account: Account
    let status: ProviderRow.Status
    let changeCommand: () -> Void

    var body: some View {
        let request = model.usageRequest(for: account)
        let state = model.usageBoard.states[request]
        let checking = model.usageBoard.checking.contains(request)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = max(context.date, Date())
            let next = state?.nextManualCheck(interval: request.manualInterval)
            let waiting = status != .missingCommand && next.map { now < $0 } == true
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Group {
                    if status == .missingCommand {
                        Text("Your login shell can’t find ") + Text(request.command).font(.system(size: 12, design: .monospaced)) + Text(".")
                    } else {
                        if let error = state?.error { Text(error) }
                        if let reading = state?.reading {
                            Text("Showing the reading from \(reading.readAt.formatted(date: .abbreviated, time: .shortened)).")
                        }
                    }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(waiting ? "Try Again at \(next!.formatted(date: .omitted, time: .shortened))" : "Try Again") {
                        Task {
                            if status == .missingCommand { await model.usageBoard.check(request.command) }
                            await model.usageBoard.refresh(request, usage: model.usage, openRouterKey: model.openRouterKey, for: .manual)
                        }
                    }
                    .disabled(waiting || checking)
                    .modifier(Prominent(status != .missingCommand))
                    if status == .missingCommand {
                        Button("Change Command…", action: changeCommand).buttonStyle(.borderedProminent)
                    } else if request.usesLegacyOpenRouterKey {
                        // Pi's usage is the shared OpenRouter key's, set in Settings (#232).
                        Button("Open Settings") {
                            dismiss()
                            model.openSettings(.openRouter)
                        }
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            .padding(16)
            .frame(width: 300, alignment: .leading)
            // Not the row's second line's, which it opens from.
            .lineLimit(nil)
            .foregroundStyle(.primary)
        }
    }

    private var title: String {
        switch status {
        case .missingCommand: "Command not found"
        case .stale: "Stale reading"
        default: "Usage unavailable"
        }
    }
}

/// The bordered-prominent style, or the plain bordered one.
private struct Prominent: ViewModifier {
    let on: Bool
    init(_ on: Bool) { self.on = on }

    func body(content: Content) -> some View {
        if on { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

/// Each model group's name, once, beside its meters.
private struct ProviderModelsCell: View {
    let row: ProviderRow

    var body: some View {
        ProviderLines {
            switch ProviderRowContent(row) {
            case .checking: EmptyView()
            case .unavailable, .note: line(UsageWindow.allModels)
            case .groups(let groups): ForEach(groups) { line($0.name) }
            }
        }
    }

    private func line(_ name: String) -> some View {
        Text(name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            .frame(height: ProviderLine.height).help(name)
    }
}

/// A row's short windows (5-hour) or long ones (Weekly): a meter for each group that has one, and a
/// blank line for each that doesn't, so every meter is beside its group.
private struct ProviderWindowsCell: View {
    let row: ProviderRow
    let long: Bool
    let layout: UsageMeterLayout

    var body: some View {
        let dimmed = row.status.isStale
        ProviderLines {
            switch ProviderRowContent(row) {
            case .checking:
                Capsule().fill(.primary.opacity(0.1)).frame(width: layout.bar, height: UsageMeterLayout.barHeight).frame(height: ProviderLine.height)
            case .unavailable:
                Text("—").font(.system(size: 12)).foregroundStyle(.tertiary).frame(height: ProviderLine.height)
            case .note(let note):
                if long {
                    Text(note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(height: ProviderLine.height).help(note)
                }
            case .groups(let groups):
                ForEach(groups) { group in
                    if let line = long ? group.long : group.short {
                        UsageMeter(line: line, layout: layout, dimmed: dimmed)
                    } else {
                        Color.clear.frame(width: 1, height: ProviderLine.height)
                    }
                }
            }
        }
    }
}

/// A window's meter: its bar, with a tick for the time gone by, the share used, the time left and when
/// the reset is, each in its own slot so they line up down the column. A passed reset reads "Reset at
/// 5:40 AM" across both, until the next reading.
struct UsageMeter: View {
    let line: UsageLine
    let layout: UsageMeterLayout
    var dimmed = false

    var body: some View {
        let both = UsageMeterLayout.timeLeft + (layout.showsResetTime ? UsageMeterLayout.spacing + UsageMeterLayout.resetTime : 0)
        HStack(spacing: UsageMeterLayout.spacing) {
            UsageBar(title: line.title, percent: line.percent ?? 0, track: .primary.opacity(0.1), dimmed: dimmed, elapsed: line.elapsed)
                .frame(width: layout.bar, height: UsageMeterLayout.barHeight)
            Text(line.percentText).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(line.percent == nil ? .secondary : .primary)
                .opacity(dimmed ? 0.45 : 1)
                .frame(width: UsageMeterLayout.share, alignment: .trailing)
            if layout.showsTimeLeft {
                if let left = line.timeLeft, let time = line.resetTime {
                    (Text("in ").foregroundStyle(.secondary) + Text(left).foregroundStyle(.primary))
                        .frame(width: UsageMeterLayout.timeLeft, alignment: .leading)
                    if layout.showsResetTime {
                        Text(time).foregroundStyle(.secondary).frame(maxWidth: UsageMeterLayout.resetTime, alignment: .leading)
                    }
                } else {
                    Text(line.reset).foregroundStyle(.secondary).frame(maxWidth: both, alignment: .leading)
                }
            }
        }
        .font(.system(size: 12)).monospacedDigit().lineLimit(1)
        .frame(height: ProviderLine.height, alignment: .leading)
        .help(line.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.title)
        .accessibilityValue("\(line.percent == nil ? "Not known" : "\(line.percentText) used")"
                            + "\(line.elapsedText.map { ", \($0) of the window elapsed" } ?? ""), \(line.reset)")
    }
}

/// Money left under a spending limit, usage credits and free resets, a line each; the amount bright
/// while there is some, the line dim when there is none.
private struct ProviderCreditsCell: View {
    let row: ProviderRow

    var body: some View {
        ProviderLines {
            ForEach(row.badges) { badge in
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(badge.kind)).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 13)
                    text(badge).font(.system(size: 12)).monospacedDigit().lineLimit(1).truncationMode(.tail)
                }
                .frame(height: ProviderLine.height)
                .help(badge.help)
            }
        }
    }

    private func text(_ badge: UsageBadge) -> Text {
        guard badge.available, let amount = badge.amount, let range = badge.text.range(of: amount) else {
            return Text(badge.text).foregroundStyle(.secondary)
        }
        return Text(badge.text[..<range.lowerBound]).foregroundStyle(.secondary)
            + Text(amount).fontWeight(.medium).foregroundStyle(.primary)
            + Text(badge.text[range.upperBound...]).foregroundStyle(.secondary)
    }

    static func symbol(_ kind: UsageBadge.Kind) -> String {
        switch kind {
        case .spend: "dollarsign.circle"
        case .credits: "creditcard"
        case .resets: "arrow.counterclockwise"
        }
    }
}

/// A cell's lines, one under another, with room above and below as every row has.
private struct ProviderLines<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, ProviderLine.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The agents set to the account, their faces overlapping: as many as the column holds (four at
/// most), else one fewer and how many more.
private struct ProviderAgentsCell: View {
    let bots: [Bot]
    static let size = 22.0
    static let overlap = 6.0

    var body: some View {
        GeometryReader { geometry in
            let step = Self.size - Self.overlap
            let fit = min(4, max(1, Int((geometry.size.width - Self.size) / step) + 1))
            let shown = bots.count > fit ? fit - 1 : bots.count
            let more = bots.count - shown
            HStack(spacing: -Self.overlap) {
                ForEach(Array(bots.prefix(shown).enumerated()), id: \.element.id) { index, bot in
                    BotAvatar(bot: bot, size: Self.size)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                        .mask { AvatarGap(cut: index < shown - 1 || more > 0, step: step) }
                }
                if more > 0 {
                    Text("+\(more)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: Self.size, minHeight: Self.size)
                        .background(Circle().fill(.primary.opacity(0.08)))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 2 * ProviderLine.height)
        .help(bots.map(\.name).formatted(.list(type: .and)))
    }
}

/// A face's mask: all of it, but for a ring around the next face, which sits on top, so a gap in
/// the row's own colour shows between them.
private struct AvatarGap: View {
    let cut: Bool
    let step: Double

    var body: some View {
        Rectangle()
            .overlay {
                if cut {
                    Circle().frame(width: ProviderAgentsCell.size + 4, height: ProviderAgentsCell.size + 4)
                        .offset(x: step).blendMode(.destinationOut)
                }
            }
            .compositingGroup()
    }
}

/// Each profile's allowance as the shared usage cache last gave it, and whether its command is
/// found. A table's cells share no state, so its rows read them from here, and a conversation's
/// Model & Usage reads its account's from here too. The app keeps one, refreshed in the background
/// (`AppModel`), while Providers shows, and with either one's Refresh.
@MainActor @Observable final class ProviderUsageBoard {
    private(set) var states: [UsageRequest: UsageState] = [:]
    private(set) var checking: Set<UsageRequest> = []
    private(set) var found: [String: Bool] = [:]

    /// Reads each profile's usage now and every minute, until the table goes.
    func watch(_ requests: [UsageRequest], usage: UsageCache, openRouterKey: @escaping @MainActor () -> String?) async {
        await withTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask {
                    while !Task.isCancelled {
                        await self.refresh(request, usage: usage, openRouterKey: openRouterKey)
                        do { try await Task.sleep(for: .seconds(60)) } catch { break }
                    }
                }
            }
            for command in Set(requests.map(\.command)) {
                group.addTask { await self.check(command) }
            }
        }
    }

    /// Shows what the cache has, then checks if that is due for who asks (`UsageCheck`).
    func refresh(_ request: UsageRequest, usage: UsageCache, openRouterKey: @MainActor () -> String?, for check: UsageCheck = .providers) async {
        await sync(request, usage: usage)
        guard !checking.contains(request), await usage.isDue(request, for: check) else { return }
        checking.insert(request)
        defer { checking.remove(request) }
        let key = request.usesLegacyOpenRouterKey ? openRouterKey() : nil
        states[request] = await usage.read(request, openRouterKey: key, for: check)
    }

    /// What the cache last read for the profile, also when something else read it.
    func sync(_ request: UsageRequest, usage: UsageCache) async {
        if let saved = await usage.saved(request), saved != states[request] { states[request] = saved }
    }

    /// Whether the login shell finds the command.
    func check(_ command: String) async {
        found[command] = await CommandCheck.isAvailable(command)
    }
}

/// The profile selected in Providers, on the right: its allowance as Model & Usage shows it, its
/// connectors, the agents set to it, its command, and, for one added here, Remove Profile.
private struct ProviderInspector: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let changeCommand: () -> Void
    let remove: () -> Void

    var body: some View {
        let request = model.usageRequest(for: account)
        let bots = model.bots.filter { $0.accountID == account.id }
        let found = model.usageBoard.found[request.command]
        let plan = model.usageBoard.states[request]?.reading?.planLabel
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProviderLogo(kind: account.kind, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text([account.kind.displayName, plan].compactMap(\.self).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Palette.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { model.providerSelection = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close")
                    .accessibilityLabel("Close provider sidebar")
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 14))
            Rectangle().fill(Palette.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AccountUsageSection(request: request, isRunning: false).id(request)
                    ProviderConnectorsSection(account: account).id(account.id)
                    if !bots.isEmpty {
                        InspectorSection("Agents", trailing: "\(bots.count)", preferenceKey: "provider.agents") {
                            InspectorCard {
                                ForEach(Array(bots.enumerated()), id: \.element.id) { index, bot in
                                    AgentRow(bot: bot, last: index == bots.count - 1)
                                }
                            }
                        }
                    }
                    InspectorSection("Command", preferenceKey: "provider.command") {
                        InspectorCard(padded: true) {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    if let found {
                                        Image(systemName: found ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                            .foregroundStyle(found ? AnyShapeStyle(GitHubColors.open) : AnyShapeStyle(Palette.warning))
                                            .accessibilityLabel(found ? "CLI found" : "Command not found")
                                    }
                                    Text(request.command).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.pathText)
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                                .help(found == false ? "The login shell can’t find this command." : request.command)
                            }
                        }
                        // As the bot inspector's Workspace has its buttons.
                        HStack(spacing: 8) {
                            Button { copy(request.command) } label: { Label("Copy", systemImage: "doc.on.doc") }
                            Button(action: changeCommand) { Label("Change…", systemImage: "pencil") }.help("Change it in Settings ▸ Accounts")
                        }
                        .buttonStyle(InspectorButtonStyle(fill: true))
                    }
                    if model.settings.customAccounts.contains(where: { $0.id == account.id }) {
                        Button(role: .destructive, action: remove) { Text("Remove Profile…").foregroundStyle(GitHubColors.danger) }
                            .buttonStyle(InspectorButtonStyle(fill: true))
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Palette.text)
        .background(Palette.sidebar)
        .task(id: request.command) { await model.usageBoard.check(request.command) }
    }
}

/// An agent set to the profile, opening its Home.
private struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    let last: Bool

    var body: some View {
        Button { model.show(.home(bot.id)) } label: {
            HStack(spacing: 10) {
                BotAvatar(bot: bot, size: 24)
                Text(bot.name).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
        }
        .help("Show \(bot.name)’s Home")
    }
}

struct AddProviderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = AgentKind.claude
    @State private var command = ""
    @State private var testing = false
    @State private var found: Bool?
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.contains(where: \.isNewline)
    }
    var body: some View {
        VStack(spacing: 0) {
            Text("New CLI Profile").font(.headline).padding(20)
            Form {
                TextField("Profile name", text: $name, prompt: Text("Claude Research"))
                Picker("CLI family", selection: $kind) { ForEach(AgentKind.profileFamilies, id: \.self) { ProviderMenuLabel(title: $0.displayName, kind: $0).tag($0) } }
                TextField("Command", text: $command, prompt: Text("~/.local/bin/claude-research"))
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: command) { found = nil }
                if RuntimeAdapters.adapter(for: kind).offersProviders {
                    Text("This profile uses Pi’s own sign-in and environment credentials. Its providers and models appear after it is added.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(testing ? "Testing…" : "Test Command") {
                        testing = true
                        let tested = command
                        Task {
                            let result = await CommandCheck.isAvailable(tested)
                            if command == tested { found = result }
                            testing = false
                        }
                    }.disabled(!valid || testing)
                    if let found {
                        Label(found ? "Command found" : "Command not found", systemImage: found ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(found ? AnyShapeStyle(GitHubColors.open) : AnyShapeStyle(Palette.warning))
                    }
                }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Profile") { save() }.buttonStyle(.borderedProminent).disabled(!valid || testing)
            }.padding(20)
        }.frame(width: 540, height: 410).background(Color(nsColor: .windowBackgroundColor))
    }
    private func save() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = model.settings.accounts.first { $0.kind == kind }?.symbol ?? "terminal"
        model.settings.customAccounts.append(Account(id: "custom-" + UUID().uuidString.lowercased(), name: name, kind: kind, defaultCommand: command, symbol: symbol))
        dismiss()
    }
}
