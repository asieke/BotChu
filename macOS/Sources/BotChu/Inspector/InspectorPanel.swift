import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case activity, model, session, memory

    static let storageKey = "inspector.selectedTab"
    var id: Self { self }

    var title: String {
        switch self {
        case .activity: "Activity"
        case .model: "Model & Usage"
        case .session: "Session"
        case .memory: "Memory"
        }
    }

    var symbol: String {
        switch self {
        case .activity: "list.bullet"
        case .model: "slider.horizontal.3"
        case .session: "clock.arrow.circlepath"
        case .memory: "touchid"
        }
    }
}

/// Home and tasks share the same navigation. Only the selected area's contents scroll;
/// the character, tabs and conversation actions stay in place.
struct InspectorPanel<Header: View, Content: View, Actions: View>: View {
    @AppStorage(InspectorTab.storageKey) private var selection: InspectorTab = .activity
    @ViewBuilder let header: Header
    @ViewBuilder var content: (InspectorTab) -> Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                header
                InspectorTabBar(selection: $selection)
            }
            .padding(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    content(selection)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 4, leading: 16, bottom: 24, trailing: 16))
            }
            // Start each area at the top without recreating the character or moving keyboard focus.
            .id(selection)
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Explicit, so the sidebar's vibrancy doesn't recolor text on the opaque cards.
        .foregroundStyle(Palette.text)
        .background(Palette.sidebar)
        .onAppear {
            if let tab = DevHooks.inspectorTab { selection = tab }
        }
    }
}

struct InspectorTabBar: View {
    @Binding var selection: InspectorTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: InspectorTab?
    @State private var hovered: InspectorTab?
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            ForEach(InspectorTab.allCases) { tab in
                Button {
                    selection = tab
                    focused = tab
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(selection == tab ? Palette.text : Palette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background {
                            if selection == tab {
                                Capsule().fill(Palette.card)
                                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            } else if hovered == tab {
                                Capsule().fill(Palette.card.opacity(0.45))
                            }
                        }
                        .overlay {
                            if focused == tab {
                                Capsule().strokeBorder(Palette.violet, lineWidth: 2)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focused, equals: tab)
                .focusEffectDisabled()
                .onHover { hovered = $0 ? tab : nil }
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier("inspector-tab-\(tab.rawValue)")
                .overlay(alignment: .trailing) {
                    if let next = nextTab(after: tab), selection != tab, selection != next {
                        Rectangle().fill(Palette.hairline).frame(width: 1, height: 16)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .padding(4)
        .background(Capsule().fill(Palette.dynamic(0xE8E6E3, 0x17171B)))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status sections")
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty, let focused,
                  let index = InspectorTab.allCases.firstIndex(of: focused) else { return .ignored }
            let tabs = InspectorTab.allCases
            let offset = press.key == .rightArrow ? 1 : -1
            let next = tabs[(index + offset + tabs.count) % tabs.count]
            selection = next
            self.focused = next
            return .handled
        }
    }

    private func nextTab(after tab: InspectorTab) -> InspectorTab? {
        let tabs = InspectorTab.allCases
        guard let index = tabs.firstIndex(of: tab), index + 1 < tabs.count else { return nil }
        return tabs[index + 1]
    }
}
