import SwiftUI

extension EnvironmentValues {
    /// Scrolls the status sidebar's selected area, to show something in it (a sub-agent the chat opened).
    @Entry var inspectorScroll: ScrollViewProxy?
    /// The selected area's scrolling: its size, and a bar it can pin above what scrolls.
    @Entry var inspectorArea: InspectorScrollArea?
}

/// What the selected area pins above its scrolling contents (a sub-agent's Back and Stop), and how
/// big the part that scrolls is. Contents place themselves in `space`, which is the visible part.
@MainActor @Observable
final class InspectorScrollArea {
    nonisolated static let space = "inspector-scroll"
    private(set) var bar: AnyView?
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored var viewport: CGSize = .zero

    func pin(_ bar: some View, owner: UUID) {
        self.owner = owner
        self.bar = AnyView(bar)
    }

    /// Only its own: the next area may have pinned its bar already.
    func unpin(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        bar = nil
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case activity, subagents, model, session, memory

    static let storageKey = "inspector.selectedTab"
    var id: Self { self }

    var title: String {
        switch self {
        case .activity: "Activity"
        case .subagents: "Sub-agents"
        case .model: "Model & Usage"
        case .session: "Session"
        case .memory: "Memory"
        }
    }

    var symbol: String {
        switch self {
        case .activity: "list.bullet"
        case .subagents: "arrow.triangle.branch"
        case .model: "cpu"
        case .session: "clock.arrow.circlepath"
        case .memory: "touchid"
        }
    }
}

/// Home and tasks share the same navigation. Only the selected area's contents scroll;
/// the character, tabs and conversation actions stay in place.
struct InspectorPanel<Header: View, Content: View, Actions: View>: View {
    var badgeCounts: [InspectorTab: Int] = [:]
    @ViewBuilder let header: Header
    @ViewBuilder var content: (InspectorTab) -> Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            InspectorAreas(badgeCounts: badgeCounts, header: header, content: content)
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Explicit, so the sidebar's vibrancy doesn't recolor text on the opaque cards.
        .foregroundStyle(Palette.text)
        .background(Palette.sidebar)
    }
}

/// The tabs and the selected area. Only this reads which tab is selected, not the panel around it:
/// a view whose body reads an `@AppStorage` value is evaluated again at every UserDefaults write,
/// whatever its key, and the panel's conversation actions needn't be (#348).
private struct InspectorAreas<Header: View, Content: View>: View {
    @AppStorage(InspectorTab.storageKey) private var selection: InspectorTab = .activity
    let badgeCounts: [InspectorTab: Int]
    let header: Header
    let content: (InspectorTab) -> Content
    @State private var area = InspectorScrollArea()

    var body: some View {
        VStack(spacing: 16) {
            header
            InspectorTabBar(selection: $selection, badgeCounts: badgeCounts)
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
        if let bar = area.bar {
            bar.padding(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
        }
        ScrollViewReader { proxy in
            ScrollView {
                InspectorArea(tab: selection, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 4, leading: 16, bottom: 24, trailing: 16))
            }
            .coordinateSpace(.named(InspectorScrollArea.space))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { area.viewport = $0 }
            // Start each area at the top without recreating the character or moving keyboard focus.
            .id(selection)
            .environment(\.inspectorScroll, proxy)
            .environment(\.inspectorArea, area)
        }
        .onAppear {
            if let tab = DevHooks.inspectorTab { selection = tab }
        }
    }
}

/// The selected tab's sections, built only when the tab or what they show changes: given the same
/// tab, the areas around it are evaluated again at a UserDefaults write without building them anew.
private struct InspectorArea<Content: View>: View {
    let tab: InspectorTab
    let content: (InspectorTab) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            content(tab)
        }
    }
}

struct InspectorTabBar: View {
    @Binding var selection: InspectorTab
    var badgeCounts: [InspectorTab: Int] = [:]
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
                        .overlay(alignment: .topTrailing) {
                            if let count = badgeCounts[tab], count > 0 {
                                Text(String(count)).font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(Capsule().fill(Palette.accent)).allowsHitTesting(false)
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
                .accessibilityLabel(tab.title + ((badgeCounts[tab] ?? 0) > 0 ? ", \(badgeCounts[tab]!) running" : ""))
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
