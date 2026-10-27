import SwiftUI
import BotChuCore

struct ModelPicker: View {
    @Environment(\.dismiss) private var dismiss
    let data: ModelPickerData
    let accountName: String
    let catalog: ModelCatalog
    let disabled: Bool
    let select: (String) -> Void
    /// The profile whose own list `data` shows (#220), checked as the picker opens when it is due.
    var scope: ModelCatalogScope?
    @State private var query = ""
    @State private var highlighted: String?
    @State private var showsCustom = false
    @State private var customID = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var customFocused: Bool

    private var choices: [ModelPickerData.Choice] { data.matching(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(showsCustom ? "Custom model" : "Choose model").font(.system(size: 15, weight: .semibold))
                Spacer()
                ProviderLabel(title: accountName, kind: data.kind, size: 12).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(16)
            if showsCustom {
                customForm
            } else {
                search
                modelList
                footer
            }
        }
        .frame(width: 380)
        .lineLimit(nil)
        .multilineTextAlignment(.leading)
        .foregroundStyle(Palette.text)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            highlighted = data.selectedID
            searchFocused = true
        }
        .onExitCommand { dismiss() }
        .onChange(of: choices.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == highlighted }) { highlighted = ids.first }
        }
        .onChange(of: disabled) { _, running in if running { dismiss() } }
        .task {
            if data.kind == .pi { await catalog.load() }
            if let scope { await catalog.refresh(scope) }
        }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search models…", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit(chooseHighlighted)
                .onKeyPress(keys: [.upArrow, .downArrow]) { key in
                    move(key.key == .downArrow ? 1 : -1)
                    return .handled
                }
                .accessibilityLabel("Search models")
            if !query.isEmpty {
                Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 11).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.055)))
        .padding(.horizontal, 12).padding(.bottom, 8)
        .onChange(of: query) { _, _ in highlighted = choices.first?.id }
    }

    private var modelList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if choices.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(.tertiary)
                            Text("No matching models").font(.system(size: 13, weight: .medium))
                            Text("Try a different name or use a custom model ID.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                    ForEach(choices) { choice in
                        Button { choose(choice.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: choice.id.isEmpty ? "arrow.triangle.branch" : "cpu")
                                    .font(.system(size: 14))
                                    .foregroundStyle(choice.id == data.selectedID ? Palette.violet : Color.secondary)
                                    .frame(width: 28, height: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(choice.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(choice.detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                                if choice.id == data.selectedID {
                                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.violet)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(PickerRowStyle(selected: choice.id == data.selectedID, highlighted: choice.id == highlighted))
                        .help(choice.detail)
                        .accessibilityLabel("\(choice.title), \(choice.detail)")
                        .accessibilityAddTraits(choice.id == data.selectedID ? .isSelected : [])
                        .id(choice.id)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .frame(height: min(330, max(110, CGFloat(choices.count) * 58)))
            .onChange(of: highlighted) { _, value in
                if let value { proxy.scrollTo(value) }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if data.kind == .pi {
                HStack(spacing: 6) {
                    if catalog.loading { ProgressView().controlSize(.mini) }
                    Text(catalog.loading ? "Loading OpenRouter models…" : catalog.unavailable
                         ? "Catalog unavailable · current and custom models still work"
                         : "OpenRouter · models with tool support")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            if let scope { nativeStatus(catalog.status(for: scope), scope: scope) }
            HStack {
                Button {
                    customID = query.isEmpty ? data.effectiveID : query
                    showsCustom = true
                    customFocused = true
                } label: {
                    Label("Use custom model ID…", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("↑↓  navigate   ↵  select")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .top) { Divider() }
    }

    /// When the profile's list was read, or why it couldn't be, with Refresh models beside it.
    private func nativeStatus(_ status: NativeCatalogStatus, scope: ModelCatalogScope) -> some View {
        HStack(spacing: 6) {
            if status.checking { ProgressView().controlSize(.mini) }
            else if status.failure != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
            }
            Text(status.summary(at: Date()))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .help(status.failure ?? "")
            Spacer(minLength: 4)
            Button { Task { await catalog.refresh(scope, force: true) } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(status.checking)
            .help("Refresh models")
            .accessibilityLabel("Refresh models")
        }
    }

    private var customForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(data.kind == .pi ? "Enter an OpenRouter model ID, including its provider." : "Enter a model ID supported by this account.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(data.kind == .pi ? "provider/model-name" : "Model ID", text: $customID)
                .textFieldStyle(.roundedBorder).focused($customFocused).onSubmit(saveCustom)
                .accessibilityLabel("Custom model ID")
            HStack {
                Button("Back") { showsCustom = false; searchFocused = true }
                Spacer()
                Button("Use model", action: saveCustom)
                    .buttonStyle(.borderedProminent)
                    .disabled(customID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || disabled)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
    }

    private func move(_ amount: Int) {
        guard !choices.isEmpty else { return }
        let current = choices.firstIndex { $0.id == highlighted } ?? (amount > 0 ? -1 : choices.count)
        highlighted = choices[min(choices.count - 1, max(0, current + amount))].id
    }

    private func chooseHighlighted() {
        guard let id = highlighted, choices.contains(where: { $0.id == id }) else { return }
        choose(id)
    }

    private func saveCustom() {
        let id = customID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        choose(id)
    }

    private func choose(_ id: String) {
        guard !disabled else { return }
        select(id)
        dismiss()
    }
}
