import SwiftUI
import BotChuCore

/// The Inbox's colours, beside the conversation column's.
extension Palette {
    /// What waits on the owner: a question to answer.
    static let needs = dynamic(0xB25000, 0xFF9F0A)
    static let needsBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 159 / 255, blue: 10 / 255, alpha: 0.10)
            : NSColor(srgbRed: 178 / 255, green: 80 / 255, blue: 0, alpha: 0.075)
    })
    static let tertiaryText = dynamic(0x8E8E93, 0x7C7C83)
    static let chip = Color.primary.opacity(0.055)
    static let tile = dynamic(0xEFEEEC, 0x34333A)
    static let merged = dynamic(0x8250DF, 0xA371F7)
    static let added = dynamic(0x1A7F37, 0x3FB950)
    static let deleted = dynamic(0xCF222E, 0xF85149)
}

/// The Inbox: what the bots delivered, in a list beside the one being read (`InboxReader`).
struct InboxView: View {
    @Environment(AppModel.self) private var model
    /// The group the delivery being read was in when it was chosen, which it keeps until the
    /// owner leaves it.
    @State private var pinned: [UUID: InboxList.Section] = [:]
    @State private var showsDone = false
    @State private var width: CGFloat = 1240
    @FocusState private var listFocused: Bool

    var body: some View {
        let inbox = model.inbox!
        let deliveries = inbox.all
        let groups = InboxList.groups(deliveries, state: inbox.state, now: .now, pinned: pinned)
        let visible = groups.flatMap { $0.section == .done && !showsDone ? [] : $0.ids }
        HStack(spacing: 0) {
            InboxColumn(groups: groups, showsDone: $showsDone)
                .frame(width: width >= 1180 ? 392 : 320)
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    guard let selected = inbox.selected, let index = visible.firstIndex(of: selected) else { return .ignored }
                    let next = index + (press.key == .upArrow ? -1 : 1)
                    guard visible.indices.contains(next) else { return .handled }
                    inbox.selected = visible[next]
                    return .handled
                }
            Group {
                if let id = inbox.selected, let delivery = inbox.delivery(id), visible.contains(id) {
                    InboxReader(delivery: delivery)
                        .id(id)
                } else {
                    InboxEmpty(deliveries: deliveries, done: groups.first { $0.section == .done }?.ids.count ?? 0) { showsDone = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Inbox")
        .toolbar {
            if let id = inbox.selected, let delivery = inbox.delivery(id), visible.contains(id) {
                ToolbarItemGroup(placement: .primaryAction) { InboxToolbar(delivery: delivery) }
            }
        }
        .onAppear {
            inbox.isShowing = true
            if inbox.selected.map({ !visible.contains($0) }) ?? true { inbox.selected = groups.first { $0.section != .done }?.ids.first }
            read(inbox.selected, in: groups)
            listFocused = true
        }
        .onDisappear {
            inbox.isShowing = false
            pinned = [:]
        }
        .onChange(of: inbox.selected) { _, selected in read(selected, in: groups) }
        // Deliveries read after the page showed: the first is chosen.
        .onChange(of: deliveries.count) { _, _ in
            if inbox.selected == nil { inbox.selected = groups.first { $0.section != .done }?.ids.first }
        }
    }

    /// Reading a delivery: it is read, and keeps its place while it is.
    private func read(_ id: UUID?, in groups: [InboxList.Group]) {
        guard let id else { pinned = [:]; return }
        pinned = groups.first { $0.ids.contains(id) }.map { [id: $0.section] } ?? [:]
        if model.inbox.isUnread(id) { model.inbox.openedAsNews.insert(id) }
        model.inbox.markRead(id)
    }
}

/// The list: a group per section, each with its heading, Done collapsed at the end.
private struct InboxColumn: View {
    @Environment(AppModel.self) private var model
    let groups: [InboxList.Group]
    @Binding var showsDone: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.section) { group in
                        let done = group.section == .done
                        InboxGroupHeading(section: group.section, count: group.ids.count, expanded: done ? $showsDone : nil)
                        if !done || showsDone {
                            ForEach(group.ids, id: \.self) { id in
                                if let delivery = model.inbox.delivery(id) {
                                    InboxRow(delivery: delivery, selected: model.inbox.selected == id)
                                        .id(id)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .onChange(of: model.inbox.selected) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            Palette.conversationColumn
                .overlay(alignment: .trailing) { Rectangle().fill(Palette.hairline).frame(width: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Deliveries")
        .accessibilityIdentifier("inbox-list")
    }
}

/// "NEEDS YOU 3"; Done's opens and closes its group.
private struct InboxGroupHeading: View {
    let section: InboxList.Section
    let count: Int
    var expanded: Binding<Bool>?

    var body: some View {
        let label = HStack(spacing: 6) {
            if let expanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
            }
            Text(Self.title(section))
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.66)
                .textCase(.uppercase)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.secondaryText)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 5)
        .contentShape(Rectangle())
        if let expanded {
            Button { withAnimation(.easeOut(duration: 0.18)) { expanded.wrappedValue.toggle() } } label: { label }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inbox-done-toggle")
        } else {
            label
        }
    }

    static func title(_ section: InboxList.Section) -> String {
        switch section {
        case .needsYou: "Needs you"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .day(let date): date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        case .done: "Done"
        }
    }
}

/// One delivery in the list: the sender's pet (a credited bot's on its corner), who sent it, from
/// which conversation and when, its title, then what came with it.
struct InboxRow: View {
    @Environment(AppModel.self) private var model
    let delivery: Delivery
    let selected: Bool
    @State private var hovering = false

    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        let unread = model.inbox.isUnread(delivery.id)
        Button { model.inbox.selected = delivery.id } label: {
            HStack(alignment: .top, spacing: 10) {
                SenderAvatars(delivery: delivery, size: 34, cutout: selected ? Palette.chat : Palette.conversationColumn)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Text(model.bot(delivery.botID)?.name ?? "Bot")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.text)
                            .layoutPriority(1)
                        OriginLabel(delivery: delivery)
                            .foregroundStyle(Palette.secondaryText)
                        Spacer(minLength: 8)
                        Text(InboxTime.short(delivery.updatedAt))
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .lineLimit(1)
                    Text(delivery.title)
                        .font(.system(size: 13, weight: unread ? .semibold : .regular))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .padding(.top, 3)
                    DeliveryChips(delivery: delivery)
                        .padding(.top, 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(EdgeInsets(top: 8, leading: 24, bottom: 9, trailing: 12))
            .overlay(alignment: .topLeading) {
                if unread {
                    Circle().fill(Palette.news).frame(width: 8, height: 8).offset(x: 9, y: 21)
                }
            }
            .background { background }
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, ConversationColumn.rowInset)
        .onHover { hovering = $0 }
        .contextMenu { DeliveryMenu(delivery: delivery) }
        .accessibilityLabel("\(model.bot(delivery.botID)?.name ?? "Bot"): \(delivery.title)\(unread ? ", unread" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("inbox-row-\(delivery.id)")
    }

    @ViewBuilder private var background: some View {
        if selected {
            Self.shape.fill(Palette.chat)
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                .overlay { Self.shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
        } else if hovering {
            Self.shape.fill(Color.primary.opacity(0.045))
        }
    }
}

/// What came with a delivery, a chip each, after what it waits for.
struct DeliveryChips: View {
    @Environment(AppModel.self) private var model
    let delivery: Delivery

    var body: some View {
        HStack(spacing: 6) {
            if model.inbox.state.needsAnswer(delivery) {
                Label("Needs your answer", systemImage: "questionmark.circle")
                    .labelStyle(TightLabel())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.needs)
                    .fixedSize()
            } else if model.isRunning(model.inbox.target(of: delivery)), model.inbox.state[delivery.id].repliedAt != nil {
                Label("Working", systemImage: "circle.dotted")
                    .labelStyle(TightLabel())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.violet)
                    .fixedSize()
            }
            ForEach(delivery.files.prefix(3), id: \.name) { file in
                Chip(symbol: DeliveryFileLook.symbol(file.kind), text: DeliveryFileLook.label(file))
            }
            if delivery.files.count > 3 { Chip(symbol: nil, text: "+\(delivery.files.count - 3)") }
            if !delivery.pullRequests.isEmpty {
                Chip(symbol: "arrow.triangle.pull", text: DeliveryFileLook.numbers(delivery.pullRequests))
            }
            if !delivery.issues.isEmpty {
                Chip(symbol: "smallcircle.filled.circle", text: DeliveryFileLook.numbers(delivery.issues))
            }
        }
        .lineLimit(1)
    }
}

/// An icon close beside its text.
struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

struct Chip: View {
    let symbol: String?
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.secondaryText)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.chip))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// How a delivery's files and links are named in a chip.
enum DeliveryFileLook {
    static func symbol(_ kind: Delivery.File.Kind) -> String {
        switch kind {
        case .document: "doc.text"
        case .page: "macwindow"
        case .image: "photo"
        case .other: "doc"
        }
    }

    static func label(_ file: Delivery.File) -> String { file.name }

    /// "#118", "#150, #151" or "#150–#153" for a run, by number.
    static func numbers(_ links: [Delivery.Link]) -> String {
        let numbers = links.map(\.number).sorted()
        if numbers.count > 2, numbers.last! - numbers.first! == numbers.count - 1 { return "#\(numbers.first!)–#\(numbers.last!)" }
        return numbers.prefix(3).map { "#\($0)" }.joined(separator: ", ") + (numbers.count > 3 ? " +\(numbers.count - 3)" : "")
    }
}

/// The sender's pet, with a credited bot's small on its corner.
struct SenderAvatars: View {
    @Environment(AppModel.self) private var model
    let delivery: Delivery
    let size: CGFloat
    let cutout: Color

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let bot = model.bot(delivery.botID) {
                BotAvatar(bot: bot, size: size)
                    .overlay { Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
            } else {
                Circle().fill(Palette.tile).frame(width: size, height: size)
            }
            if let credit = delivery.credits.first, let bot = model.bot(credit.botID) {
                BotAvatar(bot: bot, size: size * 0.53)
                    .background { Circle().fill(cutout).padding(-2) }
                    .offset(x: size * 0.15, y: size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The conversation a delivery came from: Home, a task, or a job's run.
struct OriginLabel: View {
    @Environment(AppModel.self) private var model
    let delivery: Delivery

    var body: some View {
        let origin = InboxOrigin(model: model, delivery: delivery)
        HStack(spacing: 4) {
            Image(systemName: origin.symbol)
                .font(.system(size: 10))
                .foregroundStyle(Palette.tertiaryText)
            Text(origin.name)
                .truncationMode(.tail)
        }
        .font(.system(size: 12))
    }
}

/// Where a delivery came from, as the list, the reading pane and the composer name it.
struct InboxOrigin {
    var name: String
    var symbol: String
    /// "Open Home", "Open Task" or "Open Run".
    var open: String

    @MainActor init(model: AppModel, delivery: Delivery) {
        guard let task = delivery.taskID.flatMap({ model.task($0, of: delivery.botID) }) else {
            self.init(name: delivery.taskID == nil ? "Home" : "Closed task", symbol: delivery.taskID == nil ? "house" : "checklist",
                      open: delivery.taskID == nil ? "Open Home" : "Open Task")
            return
        }
        if let run = task.jobRun {
            self.init(name: run.jobTitle, symbol: "clock.arrow.circlepath", open: "Open Run")
        } else {
            self.init(name: task.title, symbol: task.review == nil ? "checklist" : "eye", open: "Open Task")
        }
    }

    init(name: String, symbol: String, open: String) {
        self.name = name
        self.symbol = symbol
        self.open = open
    }
}

enum InboxTime {
    /// Today's and yesterday's by the time, older ones by the day.
    static func short(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) || calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now)!) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "at 9:32 AM", "yesterday at 10:08 PM", "on 22 Oct at 7:00 AM": when it was, in a sentence.
    static func when(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time)" }
        if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now)!) { return "yesterday at \(time)" }
        return "on " + date.formatted(.dateTime.month(.abbreviated).day()) + " at \(time)"
    }

    /// "Today at 9:32 AM", "Yesterday at 10:08 PM", "22 Oct at 7:00 AM".
    static func long(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
        if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now)!) { return "Yesterday at \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " at \(time)"
    }
}

/// A delivery's menu, in its row and the toolbar.
struct DeliveryMenu: View {
    @Environment(AppModel.self) private var model
    let delivery: Delivery

    var body: some View {
        let inbox = model.inbox!
        Button(InboxOrigin(model: model, delivery: delivery).open) { model.openOrigin(of: delivery) }
        Divider()
        if inbox.isUnread(delivery.id) {
            Button("Mark as Read") { inbox.markRead(delivery.id) }
        } else {
            Button("Mark as Unread") { inbox.markRead(delivery.id, false) }
        }
        Button(inbox.isDone(delivery.id) ? "Move to Inbox" : "Done") { inbox.setDone(delivery.id, !inbox.isDone(delivery.id)) }
        if !delivery.files.isEmpty {
            Divider()
            Button("Show Copies in Finder") {
                let folder = InboxFolder(home: BotHome(workspace: model.bot(delivery.botID)?.persistencePath ?? ""))
                NSWorkspace.shared.activateFileViewerSelecting(delivery.files.map { folder.fileURL($0.name, of: delivery.id) })
            }
            let originals = delivery.files.compactMap(\.source).filter { FileManager.default.fileExists(atPath: $0) }
            Button("Reveal Originals") {
                NSWorkspace.shared.activateFileViewerSelecting(originals.map { URL(fileURLWithPath: $0) })
            }
            .disabled(originals.isEmpty)
        }
    }
}

/// The toolbar while a delivery is read: open its conversation, and Done.
private struct InboxToolbar: View {
    @Environment(AppModel.self) private var model
    let delivery: Delivery

    var body: some View {
        let inbox = model.inbox!
        let origin = InboxOrigin(model: model, delivery: delivery)
        Button { model.openOrigin(of: delivery) } label: {
            Label(origin.open, systemImage: "arrow.up.forward.app")
                .labelStyle(.titleAndIcon)
        }
        .help("\(origin.open) (⌘O)")
        .keyboardShortcut("o")
        .accessibilityIdentifier("inbox-open")
        let done = inbox.isDone(delivery.id)
        Button { inbox.setDone(delivery.id, !done) } label: {
            Label(done ? "Move to Inbox" : "Done", systemImage: done ? "tray.and.arrow.up" : "checkmark")
                .labelStyle(.titleAndIcon)
        }
        .help(done ? "Move to Inbox" : "Done (⌃⌘A)")
        .keyboardShortcut("a", modifiers: [.command, .control])
        .accessibilityIdentifier("inbox-done")
        Menu {
            DeliveryMenu(delivery: delivery)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("More")
    }
}

/// Nothing left to read: when the last delivery came, and Done to open.
private struct InboxEmpty: View {
    @Environment(AppModel.self) private var model
    let deliveries: [Delivery]
    let done: Int
    let showDone: () -> Void

    var body: some View {
        // In a scroll view, like the list and the reader, so the window draws the rule under its
        // header across the whole page, as on the other workspace pages.
        ScrollView {
            message
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var message: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.secondaryText)
                .padding(.bottom, 6)
            Text("You’re all caught up")
                .font(.system(size: 17, weight: .semibold))
            if let last = deliveries.first {
                Text("The last delivery came from \(model.bot(last.botID)?.name ?? "a bot") \(InboxTime.when(last.updatedAt)).")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
            }
            if done > 0 {
                Button("Show Done", action: showDone)
                    .padding(.top, 8)
            }
        }
        .padding(.bottom, 70)
        .accessibilityIdentifier("inbox-empty")
    }
}

extension AppModel {
    /// Shows a delivery in the Inbox.
    func showDelivery(_ id: UUID) {
        inbox.selected = id
        destination = .inbox
    }

    /// Opens the conversation that sent a delivery: its Home, its task (a closed one opens again),
    /// or its job's run.
    func openOrigin(of delivery: Delivery) {
        let target = inbox.target(of: delivery)
        if target.taskID == nil { show(target) } else if task(target) != nil { openTask(target) }
    }
}
