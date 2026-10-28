import SwiftUI
import BotChuCore

/// Registered providers from this Pi profile, plus an explicit ID for a remote or offline profile.
struct ModelProviderMenu: View {
    let providers: [ModelProvider]
    let selected: String
    let select: (String) -> Void
    @State private var showsCustom = false
    @State private var customID = ""

    var body: some View {
        Menu {
            ForEach(providers) { provider in
                Button { select(provider.id) } label: {
                    if provider.id == selected { Label(provider.name, systemImage: "checkmark") }
                    else { Text(provider.name) }
                }
            }
            Divider()
            Button("Use provider ID…") { customID = selected; showsCustom = true }
        } label: {
            Text(ModelProvider(id: selected).name).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Provider: \(ModelProvider(id: selected).name)")
        .help("Choose the model provider; the next message starts a new Pi session")
        .popover(isPresented: $showsCustom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pi provider").font(.headline)
                TextField("Provider ID", text: $customID).onSubmit(choose)
                    .accessibilityLabel("Provider ID")
                HStack {
                    Button("Cancel") { showsCustom = false }
                    Spacer()
                    Button("Use Provider", action: choose).disabled(value.isEmpty)
                }
            }
            .padding(16).frame(width: 300)
        }
    }

    private var value: String { customID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func choose() {
        guard !value.isEmpty else { return }
        select(value)
        showsCustom = false
    }
}
