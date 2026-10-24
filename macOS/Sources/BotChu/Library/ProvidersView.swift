import SwiftUI
import BotChuCore

/// Every CLI profile in one compact table: its family, command, allowance and when that was read.
/// Rows stay short in every state; the longer explanations are in tooltips and the details popover.
struct ProvidersView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var adding = false
    @State private var board = ProviderUsageBoard()
    private var matches: [Account] {
        model.settings.accounts.filter { query.isEmpty || [$0.name, $0.kind.displayName].joined(separator: " ").localizedCaseInsensitiveContains(query) }
    }
    private func request(_ account: Account) -> UsageRequest {
        UsageRequest(account: account, command: model.settings.command(for: account), credentialRevision: model.settings.usageCredentialRevision)
    }
    var body: some View {
        let requests = model.settings.accounts.map(request)
        VStack(alignment: .leading, spacing: 0) {
            LibraryHeading(title: "Providers", subtitle: "Your CLI profiles and their available allowance.", count: model.settings.accounts.count) {
                Button { adding = true } label: { Label("Add CLI", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            LibrarySearch(text: $query, prompt: "Search providers").padding(.horizontal, 24).padding(.bottom, 16)
            if matches.isEmpty {
                LibraryEmpty(title: "No matching providers", subtitle: "Try a profile name or CLI family.", symbol: "terminal")
            } else {
                Table(matches) {
                    TableColumn("Provider") { (account: Account) in ProviderNameCell(account: account) }
                        .width(min: 130, ideal: 190, max: 300)
                    TableColumn("Command") { (account: Account) in
                        ProviderCommandCell(command: model.settings.command(for: account), found: board.found[model.settings.command(for: account)])
                    }
                    .width(min: 80, ideal: 170, max: 320)
                    TableColumn("Allowance") { (account: Account) in
                        let request = request(account)
                        ProviderAllowanceCell(request: request, state: board.states[request], checking: board.checking.contains(request))
                    }
                    .width(min: 180, ideal: 340)
                    TableColumn("Updated") { (account: Account) in
                        let request = request(account)
                        ProviderFreshnessCell(request: request, state: board.states[request], checking: board.checking.contains(request)) {
                            Task { await board.refresh(request, usage: model.usage, manual: true) }
                        }
                    }
                    .width(min: 104, ideal: 132, max: 180)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }.background(Color(nsColor: .windowBackgroundColor)).frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity).navigationTitle("Providers")
        .sheet(isPresented: $adding) { AddProviderSheet().environment(model) }
        // Every profile, not only the ones the search shows; the cache decides when a check is due.
        .task(id: requests) { await board.watch(requests, usage: model.usage) }
    }
}

/// Each profile's allowance as the shared usage cache last gave it, and whether its command is
/// found. A table's cells share no state, so its rows read them from here.
@MainActor @Observable final class ProviderUsageBoard {
    private(set) var states: [UsageRequest: UsageState] = [:]
    private(set) var checking: Set<UsageRequest> = []
    private(set) var found: [String: Bool] = [:]

    /// Reads each profile's usage now and every minute, until the table goes.
    func watch(_ requests: [UsageRequest], usage: UsageCache) async {
        await withTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask {
                    while !Task.isCancelled {
                        await self.refresh(request, usage: usage)
                        do { try await Task.sleep(for: .seconds(60)) } catch { break }
                    }
                }
            }
            for command in Set(requests.map(\.command)) {
                group.addTask { await self.check(command) }
            }
        }
    }

    func refresh(_ request: UsageRequest, usage: UsageCache, manual: Bool = false) async {
        guard !checking.contains(request) else { return }
        checking.insert(request)
        defer { checking.remove(request) }
        let key = request.account.kind == .pi ? Keychain.get(Keychain.openRouterAccount) : nil
        states[request] = await usage.read(request, openRouterKey: key, manual: manual)
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
        .padding(.vertical, 6)
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

/// One line per allowance window, its reset when the column has room. At most four lines, so a
/// row stays under 100 points; the rest are in the tooltip.
private struct ProviderAllowanceCell: View {
    let request: UsageRequest
    let state: UsageState?
    let checking: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = max(context.date, Date())
            Group {
                if let reading = state?.reading, !reading.windows.isEmpty {
                    let shown = reading.windows.count > 4 ? Array(reading.windows.prefix(3)) : reading.windows
                    VStack(alignment: .leading, spacing: 3) {
                        ViewThatFits(in: .horizontal) {
                            windows(shown, now: now, resets: true)
                            windows(shown, now: now, resets: false)
                        }
                        if shown.count < reading.windows.count {
                            Text("+\(reading.windows.count - shown.count) more").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .help(details(reading, now: now))
                } else if let note = state?.reading?.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).help(note)
                } else if let error = state?.error {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Usage unavailable").font(.system(size: 12, weight: .medium))
                        Text(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(error)
                } else if state == nil || checking {
                    Text(request.account.kind == .muse ? "Checking with a brief Muse request…" : "Checking…")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Usage unavailable").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func windows(_ windows: [UsageWindow], now: Date, resets: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            ForEach(windows) { window in
                let percent = window.currentPercent(at: now)
                GridRow {
                    Text(window.title).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize(horizontal: resets, vertical: false)
                    Group {
                        if let percent { UsageBar(title: window.title, percent: percent) } else { Capsule().fill(Palette.rowDivider) }
                    }
                    .frame(width: 48, height: 4)
                    Text(percent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "—")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                        .gridColumnAlignment(.trailing)
                    if resets { Text(reset(window, now: now)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize() }
                }
            }
        }
    }

    private func reset(_ window: UsageWindow, now: Date) -> String {
        if window.hasReset(at: now) { return "Reset passed" }
        if let date = window.resetsAt { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return window.resetDescription ?? "—"
    }

    private func details(_ reading: ProviderUsage, now: Date) -> String {
        let lines = reading.windows.map { window in
            let percent = window.currentPercent(at: now).map { "\($0.formatted(.number.precision(.fractionLength(0))))% used" } ?? "not reported"
            let reset = window.hasReset(at: now) ? "reset passed, awaiting an update"
                : window.resetsAt.map { "resets \($0.formatted(date: .complete, time: .shortened))" } ?? window.resetDescription ?? "reset time not reported"
            return ["\(window.title): \(percent), \(reset)", window.hasReset(at: now) ? nil : window.detail].compactMap { $0 }.joined(separator: " · ")
        }
        return (lines + [reading.note].compactMap { $0 }).joined(separator: "\n")
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
            .padding(.vertical, 6)
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
                if state?.isStale(at: now, interval: request.refreshInterval) == true {
                    Text("Stale").font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                }
                age(reading, now: now)
            }
        } else {
            Text(state == nil || checking ? "Checking…" : "—").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func age(_ reading: ProviderUsage, now: Date) -> some View {
        Text(now.timeIntervalSince(reading.readAt) < 60 ? "Just now" : reading.readAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
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
