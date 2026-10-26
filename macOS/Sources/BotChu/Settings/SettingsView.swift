import AppKit
import SwiftUI
import BotChuCore

/// Settings, a page of the main window beside the app's sidebar (#191): its pages in a rail, or a
/// menu in the page's title when the window is narrow, and the shown page's form. Keys typed and not
/// saved stay while pages change; leaving Settings drops them, as closing its window did.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var drafts = SettingsDrafts()
    /// Whether each account's command is found by the login shell, checked as Settings opens.
    @State private var available: [String: Bool] = [:]
    @State private var compact = false
    @State private var height: CGFloat = 800

    var body: some View {
        @Bindable var settings = model.settings
        HStack(alignment: .top, spacing: 0) {
            if !compact {
                SettingsRail(page: $settings.settingsPage, mark: mark)
                    .frame(width: 200)
            }
            VStack(alignment: .leading, spacing: 0) {
                SettingsTitle(page: $settings.settingsPage, compact: compact, mark: mark)
                SettingsPageForm(page: settings.settingsPage, drafts: $drafts, available: $available, check: check)
                    .environment(\.settingsSheetHeight, height)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.leading, compact ? 4 : 16)
            .padding(.trailing, compact ? 4 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            compact = SettingsPage.isCompact(width: size.width)
            height = size.height
        }
        .navigationTitle("Settings")
        // Here, not on Accounts, so the rail's mark is right on any page.
        .task {
            await withTaskGroup(of: Void.self) { group in
                for account in model.settings.accounts { group.addTask { await check(account) } }
            }
        }
    }

    private func check(_ account: Account) async {
        let command = await MainActor.run { model.settings.command(for: account) }
        let found = await CommandCheck.isAvailable(command)
        await MainActor.run { available[account.id] = found }
    }

    private func mark(_ page: SettingsPage) -> SettingsMark? {
        switch page {
        case .accounts: return .accounts(found: available)
        case .github:
            if case .unavailable? = model.githubConnection { return .problem(count: nil) }
            return nil
        case .runReviews: return model.settings.evaluateRuns ? .on : nil
        case .openRouter: return drafts.openRouterKey.isUnsaved ? .unsaved : nil
        case .telegram:
            let telegram: TelegramBridge = model.telegram
            var problem = false
            switch telegram.state {
            case .needsToken, .running(.stopped), .running(.retrying): problem = true
            default: break
            }
            return .service(unsaved: drafts.telegramToken.isUnsaved, problem: problem, running: telegram.state != .off)
        case .remoteQueue:
            let queue: RemoteQueueBridge = model.remoteQueue
            return .service(unsaved: false, problem: queue.problem != nil || queue.unreachable, running: queue.servingURL != nil)
        case .general, .hosts, .pets: return nil
        }
    }
}

/// The keys typed in Settings and not saved yet, which outlive a change of page.
struct SettingsDrafts {
    var openRouterKey = SettingsKeyDraft()
    var telegramToken = SettingsKeyDraft()
}

extension EnvironmentValues {
    /// How tall Settings is, so its sheets fit the window (at least the compact window's 600 points).
    @Entry var settingsSheetHeight: CGFloat = 800
}

/// The pages, in three groups.
private struct SettingsRail: View {
    @Binding var page: SettingsPage
    let mark: (SettingsPage) -> SettingsMark?

    var body: some View {
        // Not scrolling: nine rows fit the shortest window, and a scroll view would draw the
        // toolbar's edge over the rail alone.
        VStack(alignment: .leading, spacing: 14) {
            ForEach(SettingsPage.groups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group) { item in
                        SettingsRailItem(page: item, selected: item == page, mark: mark(item)) { page = item }
                    }
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 14)
    }
}

private struct SettingsRailItem: View {
    let page: SettingsPage
    let selected: Bool
    let mark: SettingsMark?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(width: 20)
                Text(page.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if let mark { SettingsMarkView(mark: mark) }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
            .background(selected ? Color.primary.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mark.map { "\(page.title), \($0.label)" } ?? page.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings-page-\(page.rawValue)")
    }
}

/// A page's mark, in its own words or symbol, never colour alone.
struct SettingsMarkView: View {
    let mark: SettingsMark

    var body: some View {
        Group {
            switch mark {
            case .problem(let count):
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    if let count { Text("\(count)").monospacedDigit() }
                }
                .foregroundStyle(Palette.warning)
            case .on:
                Text("On").foregroundStyle(.secondary)
            case .unsaved:
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
        }
        .font(.system(size: 12))
        .help(mark.label)
    }
}

/// The page's name, which stays put while its form scrolls; a menu of the pages when narrow.
private struct SettingsTitle: View {
    @Binding var page: SettingsPage
    let compact: Bool
    let mark: (SettingsPage) -> SettingsMark?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if compact {
                Menu {
                    Picker("Page", selection: $page) {
                        ForEach(SettingsPage.groups, id: \.self) { group in
                            Section {
                                ForEach(group) { item in
                                    Label(mark(item).map { "\(item.title) · \($0.label)" } ?? item.title, systemImage: item.symbol)
                                        .tag(item)
                                }
                            }
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(page.title).font(.system(size: 22, weight: .bold))
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Settings page, \(page.title)")
            } else {
                Text(page.title).font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            if let link = page.link {
                Link(destination: link.url) {
                    Label(link.title, systemImage: "arrow.up.right").labelStyle(TrailingIconLabelStyle())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 4)
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.title; configuration.icon.imageScale(.small) }
    }
}

private extension SettingsPage {
    /// Where a page's service is set up, outside BotChu.
    var link: (title: String, url: URL)? {
        switch self {
        case .openRouter: ("Get a Key", URL(string: "https://openrouter.ai/keys")!)
        case .telegram: ("Set Up", URL(string: "https://github.com/asieke/BotChu/blob/main/docs/telegram.md")!)
        default: nil
        }
    }
}

/// The shown page's controls, in one readable column.
private struct SettingsPageForm: View {
    @Environment(AppModel.self) private var model
    let page: SettingsPage
    @Binding var drafts: SettingsDrafts
    @Binding var available: [String: Bool]
    let check: (Account) async -> Void

    var body: some View {
        Form {
            switch page {
            case .general: GeneralSettings()
            case .accounts: AccountsSettings(available: available, check: check)
            case .github: GitHubSettings()
            case .hosts:
                ThisMacSettings()
                HostsSection()
                RepoLocationsSection()
            case .runReviews: RunReviewSettings()
            case .pets: PetsSettings(key: $drafts.openRouterKey)
            case .openRouter: OpenRouterSettings(key: $drafts.openRouterKey)
            case .telegram: TelegramSection(token: $drafts.telegramToken)
            case .remoteQueue: RemoteQueueSection()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .id(page)
    }
}

/// Settings ▸ General: the bots folder and what every bot shares there.
private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsSheetHeight) private var height
    @State private var sharedDocument: DocumentEditorRequest?

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            LabeledContent("Bots folder") {
                HStack {
                    TextField("Bots folder", text: $settings.botsRoot)
                        .labelsHidden()
                        .settingsField()
                        .font(.system(size: 12, design: .monospaced))
                    Button("Choose…") { if let url = chooseFolder() { settings.botsRoot = url.path } }
                }
            }
            .help("New bots get a folder here by default.")
        }
        Section("Shared by every bot") {
            ForEach(SharedDocument.allCases) { document in
                LabeledContent {
                    Button("Edit…") { sharedDocument = DocumentEditorRequest(shared: document, botsRoot: settings.botsRoot) }
                        .accessibilityLabel("Edit \(document.rawValue)")
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(document == .team ? "Team playbook" : "Shared memory")
                        Text(document.rawValue).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .help(document == .team
                      ? "While it has anything in it, a playbook every bot follows: stages, handoffs, who calls whom."
                      : "Memory every bot shares, in the bots folder.")
            }
        }
        .sheet(item: $sharedDocument) { request in
            BotDocumentEditor(request: request)
                .frame(width: 560, height: min(620, max(360, height - 40)))
        }
    }
}

/// Settings ▸ Accounts: each profile's command, and whether the login shell finds it.
private struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    let available: [String: Bool]
    let check: (Account) async -> Void

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            ForEach(model.settings.accounts) { account in
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Command", text: Binding(
                            get: { settings.commands[account.id] ?? "" },
                            set: { settings.commands[account.id] = $0 }), prompt: Text(account.defaultCommand))
                            .labelsHidden()
                            .settingsField()
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { Task { await check(account) } }
                            .accessibilityLabel("\(account.name) command")
                        CommandStatus(found: available[account.id])
                    }
                } label: {
                    ProviderLabel(account)
                }
            }
        } header: {
            HStack {
                Text("Commands")
                Spacer()
                Label("zsh -l · Permission prompts bypassed", systemImage: "checkmark.shield")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .help("Each account runs its command through your login shell (zsh -l), headless, in the bot's folder or a task's worktree, with permission prompts bypassed. Leave a command empty for the default.")
            }
        }
    }
}

/// Whether the login shell found a command: a symbol with words, never colour alone.
private struct CommandStatus: View {
    let found: Bool?

    var body: some View {
        Group {
            switch found {
            case true?:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("Found")
            case false?:
                Label("Not found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warning)
                    .help("Not found by the login shell")
            case nil:
                ProgressView().controlSize(.small).accessibilityLabel("Checking")
            }
        }
        .font(.system(size: 12))
        .fixedSize()
    }
}

/// Settings ▸ Hosts, this Mac's part: where its checkouts are.
private struct ThisMacSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            LabeledContent("Repositories folder") {
                HStack {
                    TextField("Repositories folder", text: $settings.reposRoot, prompt: Text("~/Desktop/WORKSPACE"))
                        .labelsHidden()
                        .settingsField()
                        .font(.system(size: 12, design: .monospaced))
                    Button("Choose…") {
                        if let url = chooseFolder() { settings.reposRoot = (url.path as NSString).abbreviatingWithTildeInPath }
                    }
                }
            }
            .help("Tasks work on your GitHub repositories, in worktrees of their checkouts. On this Mac, checkouts are here, one folder each, and BotChu clones a repository here that isn't yet.")
        } header: {
            HStack {
                Text("This Mac")
                Spacer()
                if let name = model.settings.thisMacName {
                    Text(name).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Settings ▸ Pets: who draws a pet's stills and what animates them.
private struct PetsSettings: View {
    @Environment(AppModel.self) private var model
    @Binding var key: SettingsKeyDraft

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Picker("Draw stills with", selection: $settings.petAccountID) {
                ForEach(model.settings.accounts.filter { $0.kind == .codex }) { account in
                    ProviderMenuLabel(account).tag(account.id)
                }
            }
            .help("A pet's stills are drawn by Codex: a bot on a Codex account draws its own, and every other bot's are drawn by this account, on its image generation allowance.")
            Picker("Animate on", selection: $settings.petModelID) {
                ForEach(PetVideo.models) { video in
                    Text(String(format: "%@ (about $%.2f a pet)", video.name, PetVideo.estimatedCost(video))).tag(video.id)
                }
            }
            .help("OpenRouter turns each still into a short looping clip with its key, which costs OpenRouter credit.")
            LabeledContent("OpenRouter key") {
                if key.saved.isEmpty {
                    HStack {
                        Label("Not saved", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                        Button("Add Key…") { model.openSettings(.openRouter) }
                    }
                } else {
                    Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
        .onAppear { key.seed(saved: model.openRouterKey()) }
    }
}

/// Settings ▸ OpenRouter: the key the Pi agent and pets use, kept in the Keychain, and the default model.
private struct OpenRouterSettings: View {
    @Environment(AppModel.self) private var model
    @Binding var key: SettingsKeyDraft
    @State private var saved = false

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            LabeledContent("API key") {
                HStack {
                    SecureField("API key", text: Binding(get: { key.text ?? "" }, set: { key.text = $0; saved = false }), prompt: Text("sk-or-…"))
                        .labelsHidden()
                        .settingsField()
                        .onSubmit(save)
                        .help("Kept in your Keychain")
                    Button(saved ? "Saved" : "Save", action: save)
                        .disabled(!key.isUnsaved)
                        .buttonStyle(.borderedProminentIf(key.isUnsaved))
                }
            }
            LabeledContent("Default model") {
                TextField("Default model", text: $settings.openRouterModel, prompt: Text(CommandBuilder.defaultOpenRouterModel))
                    .labelsHidden()
                    .settingsField()
            }
            .help("Used by the OpenRouter account (the Pi agent).")
        }
        .onAppear { key.seed(saved: model.openRouterKey()) }
    }

    private func save() {
        guard key.isUnsaved else { return }
        Keychain.set(key.save(), for: Keychain.openRouterAccount)
        model.settings.usageCredentialRevision += 1
        saved = true
    }
}

extension PrimitiveButtonStyle where Self == BorderedProminentIfStyle {
    /// Prominent while `prominent`, as a Save with something to save is.
    static func borderedProminentIf(_ prominent: Bool) -> BorderedProminentIfStyle { BorderedProminentIfStyle(prominent: prominent) }
}

struct BorderedProminentIfStyle: PrimitiveButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        if prominent {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(.borderedProminent)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(.bordered)
        }
    }
}

extension View {
    /// A field of Settings: it reads as a field, from its start, as the form's rows otherwise
    /// right-align it.
    func settingsField() -> some View {
        textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
    }
}

/// The folder the owner picks, or nil.
@MainActor func chooseFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Use Folder"
    return panel.runModal() == .OK ? panel.url : nil
}

/// The sidebar's gear: Settings, in the window, shown selected while it shows (⌘, too).
struct SettingsGearButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.destination == .settings
        Button { model.openSettings() } label: {
            Image(systemName: "gearshape")
                .frame(width: 26, height: 26)
                .background(selected ? Color.primary.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar-settings")
    }
}
