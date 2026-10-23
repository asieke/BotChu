import SwiftUI
import BotChuCore

struct ProvidersView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("providersLayout") private var layout = "gallery"
    @State private var query = ""
    @State private var adding = false
    private var matches: [Account] {
        model.settings.accounts.filter { query.isEmpty || [$0.name, $0.kind.displayName].joined(separator: " ").localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryHeading(title: "Providers", subtitle: "Your CLI profiles and their available allowance.", count: model.settings.accounts.count) {
                Button { adding = true } label: { Label("Add CLI", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            HStack {
                LibrarySearch(text: $query, prompt: "Search providers")
                LibraryLayoutPicker(layout: $layout)
            }.padding(.horizontal, 24).padding(.bottom, 16)
            if matches.isEmpty { LibraryEmpty(title: "No matching providers", subtitle: "Try a profile name or CLI family.", symbol: "terminal") }
            ScrollView {
                LazyVGrid(columns: layout == "gallery" ? [GridItem(.adaptive(minimum: 310), spacing: 16)] : [GridItem(.flexible())], spacing: 16) {
                    ForEach(matches) { account in
                        ProviderCard(account: account, compact: layout != "gallery")
                            .id(UsageRequest(account: account, command: model.settings.command(for: account), credentialRevision: model.settings.usageCredentialRevision))
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
        }.background(Color(nsColor: .windowBackgroundColor)).frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity).navigationTitle("Providers")
        .sheet(isPresented: $adding) { AddProviderSheet().environment(model) }
    }
}

private struct ProviderCard: View {
    @Environment(AppModel.self) private var model
    let account: Account
    var compact: Bool
    @State private var usage = UsageState()
    @State private var loading = false
    @State private var available: Bool?
    private var request: UsageRequest { UsageRequest(account: account, command: model.settings.command(for: account), credentialRevision: model.settings.usageCredentialRevision) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProviderLogo(kind: account.kind, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.name).font(.headline)
                    Text(account.kind.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await refresh(manual: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading).help("Refresh usage").accessibilityLabel("Refresh \(account.name) usage")
            }
            HStack {
                Text(model.settings.command(for: account)).font(.system(.caption, design: .monospaced)).lineLimit(1).textSelection(.enabled)
                Spacer()
                if let available { Image(systemName: available ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(available ? .green : .orange).help(available ? "CLI found" : "Command not found") }
            }.foregroundStyle(.secondary)
            Divider()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    if let reading = usage.reading {
                        if compact {
                            HStack(alignment: .top, spacing: 24) { ForEach(reading.windows) { UsageWindowView(window: $0, now: context.date).frame(maxWidth: .infinity) } }
                        } else { ForEach(reading.windows) { UsageWindowView(window: $0, now: context.date) } }
                        if let note = reading.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        Text("\(usage.isStale(at: context.date, interval: request.refreshInterval) ? "Stale · read" : "Updated") \(reading.readAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))").font(.caption2).foregroundStyle(.secondary)
                    } else { Text(loading ? "Reading usage…" : "Usage unavailable").font(.callout).foregroundStyle(.secondary) }
                    if let error = usage.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                    if account.kind == .muse { Text("Usage checks make a brief Muse request, at most hourly automatically.").font(.caption2).foregroundStyle(.secondary) }
                    if account.kind == .pi { Text("Shares the OpenRouter key configured in Settings.").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).libraryCard()
        .task(id: request) {
            available = await CommandCheck.isAvailable(request.command)
            while !Task.isCancelled {
                await refresh(manual: false)
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
    }
    private func refresh(manual: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let current = request
        let reading = await model.usage.read(current, openRouterKey: account.kind == .pi ? Keychain.get(Keychain.openRouterAccount) : nil, manual: manual)
        guard !Task.isCancelled, request == current else { return }
        usage = reading
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
