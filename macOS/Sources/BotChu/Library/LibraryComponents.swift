import SwiftUI

/// A library page's title and count, with its actions. No subtitle (#232): the page's name, its
/// controls and what it lists say what it is.
struct LibraryHeading<Actions: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack {
            HStack(spacing: 10) {
                Text(title).font(.largeTitle.weight(.bold))
                if let count { Text("\(count)").font(.callout.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 3).background(.quaternary, in: Capsule()) }
            }
            Spacer()
            actions()
        }.padding(24)
    }
}
struct LibrarySearch: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
        }.padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
struct LibraryLayoutPicker: View {
    @Binding var layout: String
    var body: some View {
        Picker("Layout", selection: $layout) {
            Image(systemName: "square.grid.2x2").tag("gallery").help("Gallery")
            Image(systemName: "list.bullet").tag("table").help("List")
        }.pickerStyle(.segmented).frame(width: 80).labelsHidden()
    }
}
struct LibraryIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(color)
            .frame(width: 44, height: 44).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
    }
}
struct LibraryEmpty: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View { ContentUnavailableView(title, systemImage: symbol, description: Text(subtitle)).frame(maxWidth: .infinity, maxHeight: .infinity) }
}
extension View {
    func libraryCard() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08)))
    }
}
