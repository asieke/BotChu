import SwiftUI
import BotChuCore

/// Every CLI profile in one table: its family, command, allowance and when that was read. The
/// columns share out the table's width (`ProvidersColumns`) and the allowance gets the rest, so its
/// bars grow with the window; rows stay short in every state, the longer explanations in tooltips
/// and the details popover. The numbers come from the app's usage board, kept current in the
/// background and saved between launches, so the table opens on them without checking.
struct ProvidersView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var adding = false
    /// The table's width, which its columns are worked out from.
    @State private var tableWidth = 0.0
    private var matches: [Account] {
        model.settings.accounts.filter { query.isEmpty || [$0.name, $0.kind.displayName].joined(separator: " ").localizedCaseInsensitiveContains(query) }
    }
    private func request(_ account: Account) -> UsageRequest {
        UsageRequest(account: account, command: model.settings.command(for: account), credentialRevision: model.settings.usageCredentialRevision)
    }
    var body: some View {
        let board = model.usageBoard
        let requests = model.usageRequests
        VStack(alignment: .leading, spacing: 0) {
            LibraryHeading(title: "Providers", subtitle: "Your CLI profiles and their available allowance.", count: model.settings.accounts.count) {
                Button { adding = true } label: { Label("Add CLI", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            LibrarySearch(text: $query, prompt: "Search providers").padding(.horizontal, 24).padding(.bottom, 16)
            if matches.isEmpty {
                LibraryEmpty(title: "No matching providers", subtitle: "Try a profile name or CLI family.", symbol: "terminal")
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    // The timeline's date is its last tick, before a reading made since.
                    let now = max(context.date, Date())
                    // Every row's lines take the same widths, so their bars and resets line up.
                    let widths = UsageLineWidths.measured(matches.flatMap { board.states[request($0)]?.reading?.rowLines(at: now).shown ?? [] })
                    let columns = ProvidersColumns(width: tableWidth)
                    // Made once its width is known, and made anew in another size: the table
                    // itself resizes only the allowance column, and a width changed after it is
                    // laid out would come on top of that.
                    if tableWidth > 0 {
                        Table(matches) {
                            TableColumn("Provider") { (account: Account) in ProviderNameCell(account: account) }
                                .width(columns.provider)
                            TableColumn("Command") { (account: Account) in
                                ProviderCommandCell(command: model.settings.command(for: account), found: board.found[model.settings.command(for: account)])
                            }
                            .width(columns.command)
                            TableColumn("Allowance") { (account: Account) in
                                let request = request(account)
                                ProviderAllowanceCell(request: request, state: board.states[request], checking: board.checking.contains(request), now: now, widths: widths)
                            }
                            .width(min: ProvidersColumns.minimumAllowance)
                            TableColumn("Updated") { (account: Account) in
                                let request = request(account)
                                ProviderFreshnessCell(request: request, state: board.states[request], checking: board.checking.contains(request)) {
                                    Task { await board.refresh(request, usage: model.usage, openRouterKey: model.openRouterKey, manual: true) }
                                }
                            }
                            .width(columns.updated)
                        }
                        .tableStyle(.inset(alternatesRowBackgrounds: true))
                        .id(columns.size)
                    } else {
                        Color.clear
                    }
                }
                .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { tableWidth = $0 }
            }
        }.background(Color(nsColor: .windowBackgroundColor)).frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity).navigationTitle("Providers")
        .sheet(isPresented: $adding) { AddProviderSheet().environment(model) }
        // Every profile, not only the ones the search shows, at the shorter interval while shown;
        // the cache decides when a check is due.
        .task(id: requests) { await board.watch(requests, usage: model.usage, openRouterKey: model.openRouterKey) }
    }
}

/// Each profile's allowance as the shared usage cache last gave it, and whether its command is
/// found. A table's cells share no state, so its rows read them from here. The app keeps one,
/// refreshed in the background (`AppModel`) and while Providers shows.
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

    /// Shows what the cache has, then checks if that is due: after the request's own interval,
    /// or its longer `backgroundInterval` for a check nobody is looking at.
    func refresh(_ request: UsageRequest, usage: UsageCache, openRouterKey: @MainActor () -> String?, manual: Bool = false, background: Bool = false) async {
        await sync(request, usage: usage)
        let maxAge = background ? request.backgroundInterval : nil
        guard !checking.contains(request), await usage.isDue(request, manual: manual, maxAge: maxAge) else { return }
        checking.insert(request)
        defer { checking.remove(request) }
        let key = request.account.kind == .pi ? openRouterKey() : nil
        states[request] = await usage.read(request, openRouterKey: key, manual: manual, maxAge: maxAge)
    }

    /// What the cache last read for the profile, also when something else read it.
    func sync(_ request: UsageRequest, usage: UsageCache) async {
        if let saved = await usage.saved(request), saved != states[request] { states[request] = saved }
    }

    private func check(_ command: String) async {
        found[command] = await CommandCheck.isAvailable(command)
    }
}

private struct ProviderNameCell: View {
    let account: Account
    var body: some View {
        HStack(spacing: 10) {
            ProviderLogo(kind: account.kind, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(account.kind.displayName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .help("\(account.name) · \(account.kind.displayName)")
    }
}

private struct ProviderCommandCell: View {
    let command: String
    let found: Bool?
    var body: some View {
        HStack(spacing: 6) {
            if let found {
                Image(systemName: found ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(found ? .green : .orange)
                    .accessibilityLabel(found ? "CLI found" : "Command not found")
            }
            // Its end tells profiles apart (`~/.local/bin/claude-…`).
            Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }
        .help(found == false ? "The login shell can’t find this command: \(command). Change it in Settings." : command)
    }
}

/// One line per allowance window, at most four, so a row stays under 100 points (the rest are in
/// the tooltip), then the account's chips: money left under a spending limit, usage credits and
/// free resets. Each line is laid out across the cell's width (`UsageLineLayout`) from widths every
/// row shares, so bars, percentages and resets line up down the table.
private struct ProviderAllowanceCell: View {
    let request: UsageRequest
    let state: UsageState?
    let checking: Bool
    let now: Date
    let widths: UsageLineWidths
    var body: some View {
        Group {
            if let reading = state?.reading, !reading.windows.isEmpty {
                let lines = reading.rowLines(at: now)
                let badges = reading.badges(at: now)
                let stale = state?.isStale(at: now, interval: request.backgroundInterval) == true
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines.shown) { ProviderUsageLine(line: $0, widths: widths, dimmed: stale) }
                    if lines.more > 0 {
                        Text("+\(lines.more) more").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !badges.isEmpty { UsageBadges(badges: badges).padding(.top, 2) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(reading.details(at: now))
            } else if let note = state?.reading?.note {
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).help(note)
            } else if let error = state?.error {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage unavailable").font(.system(size: 12, weight: .medium))
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(error)
            } else if state == nil || checking {
                Text(request.account.kind == .muse ? "Checking with a brief Muse request…" : "Checking…")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Usage unavailable").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}

/// A window's line: its title, the share used, a bar across what is left, and its reset, the
/// weekday and the time apart so times line up.
private struct ProviderUsageLine: View {
    let line: UsageLine
    let widths: UsageLineWidths
    let dimmed: Bool
    var body: some View {
        UsageLineStack(widths: widths, dated: line.resetDay != nil) {
            Text(line.title).font(UsageLineWidths.font(.title)).lineLimit(1)
            Text(line.percentText).font(UsageLineWidths.font(.percent)).foregroundStyle(line.percent == nil ? .tertiary : .primary).lineLimit(1)
            if let percent = line.percent {
                UsageBar(title: line.title, percent: percent, track: .primary.opacity(0.1), dimmed: dimmed)
            } else {
                Capsule().fill(.primary.opacity(0.1))
            }
            Text(line.resetDay ?? "").font(UsageLineWidths.font(.day)).foregroundStyle(.secondary).lineLimit(1)
            Text(line.resetTime ?? "").font(UsageLineWidths.font(.time)).foregroundStyle(.secondary).lineLimit(1)
            Text(line.reset).font(UsageLineWidths.font(.reset)).foregroundStyle(.secondary).lineLimit(1)
        }
        // A part with no room is put outside the line, which doesn't draw it.
        .clipped()
    }
}

/// Places a usage line's parts where `UsageLineLayout` puts them in the width its cell gives it,
/// so the line follows its column as that is resized: the title, the share used, the bar, then
/// the reset as a weekday and a time (`dated`) or in words.
private struct UsageLineStack: Layout {
    let widths: UsageLineWidths
    let dated: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? UsageLineLayout.idealWidth(widths), height: 16)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = UsageLineLayout(width: bounds.width, widths: widths)
        func place(_ index: Int, _ slot: UsageLineLayout.Slot?, height: Double = 16, trailing: Bool = false) {
            guard let slot, slot.width > 0 else {
                subviews[index].place(at: CGPoint(x: bounds.maxX + 1, y: bounds.minY), proposal: .zero)
                return
            }
            subviews[index].place(at: CGPoint(x: bounds.minX + (trailing ? slot.x + slot.width : slot.x), y: bounds.midY),
                                  anchor: trailing ? .trailing : .leading, proposal: ProposedViewSize(width: slot.width, height: height))
        }
        place(0, layout.title)
        place(1, layout.percent, trailing: true)
        place(2, layout.bar, height: 6)
        let reset = layout.reset
        place(3, dated ? reset.map { .init(x: $0.x, width: widths.day) } : nil)
        place(4, dated ? reset.map { .init(x: $0.x + widths.day + UsageLineWidths.dayGap, width: widths.time) } : nil, trailing: true)
        place(5, dated ? nil : reset)
    }
}

/// The account's chips in a row, or a chip a line where the cell is too narrow for that.
private struct UsageBadges: View {
    let badges: [UsageBadge]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 4) { chips }
        }
    }

    private var chips: some View {
        ForEach(badges) { badge in
            HStack(spacing: 4) {
                Image(systemName: Self.symbol(badge.kind)).font(.system(size: 10, weight: .semibold))
                Text(badge.text).monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(badge.available ? AnyShapeStyle(GitHubColors.open) : AnyShapeStyle(.secondary))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(badge.available ? GitHubColors.open.opacity(0.14) : Color.primary.opacity(0.07), in: Capsule())
            .help(badge.help)
        }
    }

    private static func symbol(_ kind: UsageBadge.Kind) -> String {
        switch kind {
        case .spend: "dollarsign.circle"
        case .credits: "creditcard"
        case .resets: "arrow.counterclockwise"
        }
    }
}

private extension UsageLineWidths {
    /// Each part's font, measured as it is drawn; numbers in tabular digits.
    static func nsFont(_ part: UsageLine.Part) -> NSFont {
        switch part {
        case .title: .systemFont(ofSize: 12, weight: .medium)
        case .percent, .time: .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case .day, .reset: .systemFont(ofSize: 12)
        }
    }

    static func font(_ part: UsageLine.Part) -> Font { Font(nsFont(part) as CTFont) }

    static func measured(_ lines: [UsageLine]) -> UsageLineWidths {
        // A point to spare, so a title never comes out a hair too wide for its own width.
        UsageLineWidths(lines) { text, part in NSAttributedString(string: text, attributes: [.font: nsFont(part)]).size().width + 1 }
    }
}

/// When the reading was made, whether it is stale or failed (details in a popover), and refresh.
private struct ProviderFreshnessCell: View {
    let request: UsageRequest
    let state: UsageState?
    let checking: Bool
    let refresh: () -> Void
    @State private var showsDetails = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            // The timeline's date is its last tick, before a reading made since.
            let now = max(context.date, Date())
            HStack(spacing: 4) {
                status(now: now)
                Spacer(minLength: 0)
                Button(action: refresh) {
                    if checking { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .frame(width: 22, height: 22)
                .disabled(checking || !canRefresh(at: now))
                .help(refreshHelp(at: now))
                .accessibilityLabel("Refresh \(request.account.name) usage")
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private func status(now: Date) -> some View {
        if let error = state?.error {
            VStack(alignment: .leading, spacing: 1) {
                Button { showsDetails = true } label: {
                    Label(state?.reading == nil ? "Failed" : "Stale", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange).lineLimit(1)
                }
                .buttonStyle(.borderless)
                .help(error)
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) { details(error: error) }
                if let reading = state?.reading { age(reading, now: now) }
            }
        } else if let reading = state?.reading {
            VStack(alignment: .leading, spacing: 1) {
                if state?.isStale(at: now, interval: request.backgroundInterval) == true {
                    Text("Stale").font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                }
                age(reading, now: now)
            }
        } else {
            Text(state == nil || checking ? "Checking…" : "—").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// As old as the Projects table says its dates are.
    private func age(_ reading: ProviderUsage, now: Date) -> some View {
        Text(RelativeDate.text(reading.readAt, now: now)).monospacedDigit()
            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            .help("Read \(reading.readAt.formatted(date: .complete, time: .standard))")
    }

    private func details(error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state?.reading == nil ? "Usage unavailable" : "Stale reading").font(.headline)
            Text(error).fixedSize(horizontal: false, vertical: true)
            if let reading = state?.reading {
                Text("Showing the reading from \(reading.readAt.formatted(date: .abbreviated, time: .shortened)).").foregroundStyle(.secondary)
            }
            Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    private var note: String {
        switch request.account.kind {
        case .muse: "Muse is checked with a brief request, at most hourly automatically and every five minutes with Refresh."
        case .pi: "Pi profiles share the OpenRouter key in Settings."
        default: "Usage is read with the profile’s own CLI and sign-in."
        }
    }

    private var nextCheck: Date? {
        [state?.retryAt, state?.checkedAt.map { $0.addingTimeInterval(request.manualInterval) }].compactMap { $0 }.max()
    }

    private func canRefresh(at now: Date) -> Bool { nextCheck.map { now >= $0 } ?? true }

    private func refreshHelp(at now: Date) -> String {
        if !canRefresh(at: now), let next = nextCheck { return "Can be checked again at \(next.formatted(date: .omitted, time: .shortened))" }
        switch request.account.kind {
        case .muse: return "Check Muse with a brief request (at most once every five minutes)"
        case .pi: return "Refresh the OpenRouter key’s allowance"
        default: return "Refresh usage"
        }
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
            Text("Add CLI Profile").font(.headline).padding(20)
            Form {
                TextField("Profile name", text: $name, prompt: Text("Claude Research"))
                Picker("CLI family", selection: $kind) { ForEach(AgentKind.allCases, id: \.self) { ProviderMenuLabel(title: $0.displayName, kind: $0).tag($0) } }
                TextField("Command", text: $command, prompt: Text("~/.local/bin/claude-research"))
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: command) { found = nil }
                Text("Use an installed CLI or profile wrapper with its own login. BotChu uses this family’s streaming, session, and usage support. Sign in through the CLI in Terminal first.").font(.caption).foregroundStyle(.secondary)
                if kind == .pi { Text("Pi profiles use OpenRouter and the shared key in Settings.").font(.caption).foregroundStyle(.secondary) }
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
                    if let found { Label(found ? "Command found" : "Command not found", systemImage: found ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(found ? .green : .orange) }
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
