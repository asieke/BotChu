import SwiftUI
import WebKit
import BotChuCore

/// What came with a delivery, a card each: documents, HTML pages, images, other files, then its
/// pull requests and issues, by repository. Each file is the copy taken when it was sent.
struct DeliveryCards: View {
    @Environment(AppModel.self) private var model
    let delivery: Delivery

    var body: some View {
        let folder = InboxFolder(home: BotHome(workspace: model.bot(delivery.botID)?.workspace ?? ""))
        VStack(alignment: .leading, spacing: 14) {
            ForEach(delivery.files, id: \.name) { file in
                let url = folder.fileURL(file.name, of: delivery.id)
                switch file.kind {
                case .document: DocumentCard(file: file, url: url)
                case .page: PageCard(file: file, url: url)
                case .image: ImageCard(file: file, url: url)
                case .other: FileCard(file: file, url: url)
                }
            }
            ForEach(Self.byRepo(delivery.pullRequests), id: \.repo) { group in
                WorkCard(repo: group.repo, links: group.links, pullRequests: true)
            }
            ForEach(Self.byRepo(delivery.issues), id: \.repo) { group in
                WorkCard(repo: group.repo, links: group.links, pullRequests: false)
            }
        }
    }

    static func byRepo(_ links: [Delivery.Link]) -> [(repo: String, links: [Delivery.Link])] {
        var order: [String] = []
        var grouped: [String: [Delivery.Link]] = [:]
        for link in links {
            if grouped[link.repo] == nil { order.append(link.repo) }
            grouped[link.repo, default: []].append(link)
        }
        return order.map { ($0, grouped[$0]!) }
    }
}

/// A card's frame: a raised rounded rectangle, as the mock's.
private struct CardFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}

/// A card's head: its icon in a tile, its title, a line about it, and its buttons.
private struct CardHead<Actions: View>: View {
    let symbol: String
    var tint: Color = Palette.secondaryText
    let title: String
    let meta: Text
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.tile))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                meta
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions }
                .controlSize(.small)
        }
        .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 12))
    }
}

/// A file's line: whose work it is (when not the sender's), its name, and its size or lines.
private func fileMeta(_ file: Delivery.File, detail: String) -> Text {
    (file.credit.map { Text($0.name + " · ") } ?? Text("")) + Text(file.name + " · " + detail)
}

private func fileMenu(_ file: Delivery.File, url: URL) -> some View {
    Menu {
        Button("Show Copy in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Reveal Original") { if let source = file.source { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source)]) } }
            .disabled(file.source.map { !FileManager.default.fileExists(atPath: $0) } ?? true)
    } label: {
        Image(systemName: "ellipsis")
    }
    .menuIndicator(.hidden)
    .fixedSize()
    .help("More")
}

// MARK: Documents

/// A Markdown or text file, with the chat's Markdown: its first 260 points, then Show all.
private struct DocumentCard: View {
    let file: Delivery.File
    let url: URL
    @State private var text: String?
    @State private var expanded = false
    @State private var height: CGFloat = 0

    /// How much of it shows before Show all.
    static let folded: CGFloat = 260
    /// The most of a file read to show.
    static let readLimit = 512 << 10

    var body: some View {
        let lines = text.map { $0.split(separator: "\n", omittingEmptySubsequences: false).count } ?? 0
        CardFrame {
            CardHead(symbol: "doc.text", title: text.flatMap(Self.heading) ?? file.name,
                     meta: fileMeta(file, detail: "\(lines) \(lines == 1 ? "line" : "lines")")) {
                Button("Open") { NSWorkspace.shared.open(url) }
                fileMenu(file, url: url)
            }
            if let text {
                Divider().opacity(0.6)
                let tall = height > Self.folded
                MarkdownText(text: text)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .frame(maxHeight: expanded || !tall ? nil : Self.folded, alignment: .top)
                    .clipped()
                    .mask {
                        if tall && !expanded {
                            LinearGradient(stops: [.init(color: .black, location: 0.64), .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                        } else {
                            Rectangle()
                        }
                    }
                if tall {
                    Button(expanded ? "Show less" : "Show all \(lines) lines") {
                        withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                    }
                    .controlSize(.small)
                    .padding(EdgeInsets(top: 2, leading: 14, bottom: 12, trailing: 14))
                    .accessibilityIdentifier("inbox-document-more")
                } else {
                    Color.clear.frame(height: 10)
                }
            }
        }
        .task(id: url) {
            let url = url
            let limit = Self.readLimit
            text = await Task.detached(priority: .userInitiated) {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil as String? }
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: limit)) ?? Data()
                return String(decoding: data, as: UTF8.self)
            }.value
        }
    }

    /// The document's first heading, as its title.
    static func heading(_ text: String) -> String? {
        text.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: Pages

/// An HTML page: the copy in a web view with its scripts on and the network off.
private struct PageCard: View {
    let file: Delivery.File
    let url: URL
    @State private var title: String?

    var body: some View {
        CardFrame {
            CardHead(symbol: "macwindow", title: title ?? file.name,
                     meta: fileMeta(file, detail: ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))) {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
                fileMenu(file, url: url)
            }
            OfflinePage(url: url, title: $title)
                .frame(height: 460)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .padding(EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12))
        }
    }
}

/// A page from a delivery's folder, which can run its scripts but reach nothing beyond its folder:
/// every load that isn't a file, data or blob is blocked, and a link the owner clicks opens in
/// their browser instead.
struct OfflinePage: NSViewRepresentable {
    let url: URL
    @Binding var title: String?

    /// Blocks everything, then lets local loads through.
    /// (A content blocker's filter has no alternatives, so a rule per scheme.)
    static let rules = """
        [{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
         {"trigger": {"url-filter": "^file:"}, "action": {"type": "ignore-previous-rules"}},
         {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
         {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}},
         {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}}]
        """

    /// Its own class, so the dev snapshot finds it (`DevHooks.webViewFrames`).
    final class WebView: WKWebView {}

    func makeCoordinator() -> Coordinator { Coordinator(title: $title) }

    func makeNSView(context: Context) -> WebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.watch(view)
        view.setValue(false, forKey: "drawsBackground")
        let url = url
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "BotChuInboxOffline", encodedContentRuleList: Self.rules) { list, _ in
            // Without the rules, nothing loads: the page would reach the network.
            guard let list else { return }
            view.configuration.userContentController.add(list)
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ view: WebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let title: Binding<String?>
        private var observation: NSKeyValueObservation?

        init(title: Binding<String?>) { self.title = title }

        /// The page's title, as it sets it (also from its scripts).
        func watch(_ view: WKWebView) {
            observation = view.observe(\.title, options: [.new]) { [weak self] view, _ in
                let found = view.title.flatMap { $0.isEmpty ? nil : $0 }
                DispatchQueue.main.async { self?.title.wrappedValue = found }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if ["file", "about", "data", "blob"].contains(url.scheme?.lowercased() ?? "") { return .allow }
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            return .cancel
        }
    }
}

// MARK: Images and other files

private struct ImageCard: View {
    let file: Delivery.File
    let url: URL

    var body: some View {
        CardFrame {
            CardHead(symbol: "photo", title: file.name,
                     meta: fileMeta(file, detail: ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))) {
                Button("Open") { NSWorkspace.shared.open(url) }
                fileMenu(file, url: url)
            }
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 460)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12))
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .accessibilityLabel(file.name)
            }
        }
    }
}

private struct FileCard: View {
    let file: Delivery.File
    let url: URL

    var body: some View {
        CardFrame {
            CardHead(symbol: "doc", title: file.name,
                     meta: fileMeta(file, detail: ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))) {
                Button("Open") { NSWorkspace.shared.open(url) }
                fileMenu(file, url: url)
            }
        }
    }
}

// MARK: Pull requests and issues

/// A repository's pull requests (or issues) in a delivery, a row each as GitHub has them now, each
/// opening in Projects.
private struct WorkCard: View {
    @Environment(AppModel.self) private var model
    let repo: String
    let links: [Delivery.Link]
    let pullRequests: Bool
    @State private var details: [Int: GitHubLookup.WorkDetail] = [:]

    var body: some View {
        let states = Set(links.compactMap { details[$0.number]?.state })
        CardFrame {
            CardHead(symbol: pullRequests ? "arrow.triangle.pull" : "smallcircle.filled.circle",
                     tint: states == ["MERGED"] ? Palette.merged : Palette.secondaryText,
                     title: title, meta: Text(repo)) {
                if states.count == 1, let state = states.first { StatePill(state: state, pullRequest: pullRequests) }
            }
            ForEach(links, id: \.number) { link in
                Divider().opacity(0.6)
                WorkRow(link: link, detail: details[link.number]) {
                    model.projectSelection = ProjectSelection(repo: repo, tab: pullRequests ? .pulls : .issues, item: link.number)
                    model.destination = .projects
                }
            }
            Divider().opacity(0.6)
            HStack(spacing: 8) {
                Button("Open in Projects") {
                    model.projectSelection = ProjectSelection(repo: repo, tab: pullRequests ? .pulls : .issues)
                    model.destination = .projects
                }
                if let url = links.count == 1 ? links[0].url : URL(string: "https://github.com/\(repo)/\(pullRequests ? "pulls" : "issues")") {
                    Link(destination: url) { Label("GitHub", systemImage: "arrow.up.right").labelStyle(TitleThenIcon()) }
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        }
        .task(id: links) {
            for link in links {
                let key = "\(repo)#\(link.number)"
                if let known = model.workDetails[key] { details[link.number] = known; continue }
                if case .success(let read) = await model.workDetailLookup(repo, link.number, pullRequests) {
                    model.workDetails[key] = read
                    details[link.number] = read
                }
            }
        }
    }

    private var title: String {
        if links.count == 1 { return "\(pullRequests ? "Pull request" : "Issue") #\(links[0].number)" }
        return "\(links.count) \(pullRequests ? "pull requests" : "issues") in \(repo)"
    }
}

private struct WorkRow: View {
    let link: Delivery.Link
    let detail: GitHubLookup.WorkDetail?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                WorkIcon(isPullRequest: link.isPullRequest, isDraft: detail?.isDraft ?? false, state: detail?.state ?? "OPEN")
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    (Text(detail?.title ?? (link.isPullRequest ? "Pull request" : "Issue")) + Text(" #\(link.number)").foregroundStyle(Palette.secondaryText))
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if let detail {
                        Text(Self.summary(detail))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let detail, link.isPullRequest {
                    (Text("+\(detail.additions.formatted())").foregroundStyle(Palette.added)
                        + Text("  −\(detail.deletions.formatted())").foregroundStyle(Palette.deleted))
                        .font(.system(size: 12))
                        .monospacedDigit()
                    Text("\(detail.changedFiles) \(detail.changedFiles == 1 ? "file" : "files")")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.tertiaryText)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(hovering ? Color.primary.opacity(0.035) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open in Projects")
    }

    /// "Merged · 25 Oct", "Open · by asieke".
    static func summary(_ detail: GitHubLookup.WorkDetail) -> String {
        let state = detail.isDraft && detail.state == "OPEN" ? "Draft" : detail.state.capitalized
        return "\(state) · updated \(detail.updatedAt.formatted(.relative(presentation: .named)))"
    }
}

private struct StatePill: View {
    let state: String
    let pullRequest: Bool

    var body: some View {
        let color = state == "MERGED" ? Palette.merged : state == "OPEN" ? Palette.added : Palette.secondaryText
        Text(state.capitalized)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Palette.chip))
    }
}

/// "GitHub ↗".
private struct TitleThenIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}
