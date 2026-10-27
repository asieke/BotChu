import AppKit
import SwiftUI
import BotChuCore

// The cells of the Projects tables, after GitChu's repository and pull request tables.

/// GitHub's Primer colors, so states read the way they do on github.com.
enum GitHubColors {
    static let open = Palette.dynamic(0x1A7F37, 0x3FB950)
    static let danger = Palette.dynamic(0xCF222E, 0xF85149)
    static let attention = Palette.dynamic(0x9A6700, 0xD29922)
    static let neutral = Palette.dynamic(0x59636E, 0x9198A1)
    /// Merged pull requests and closed issues.
    static let done = Palette.dynamic(0x8250DF, 0xA371F7)
}

extension Color {
    /// A GitHub label color: six hex digits.
    init(hex: String) {
        let value = UInt32(hex.prefix(6), radix: 16) ?? 0x888888
        self.init(.sRGB, red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

enum RelativeDate {
    static func text(_ date: Date, now: Date = .now) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        if s < 7 * 86400 { return "\(Int(s / 86400))d ago" }
        if Calendar.current.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return date.formatted(.dateTime.month(.abbreviated).year())
    }
}

/// A relative date; recent work stands out and stale work recedes. Hover for the full date.
struct DateCell: View {
    var date: Date?
    var body: some View {
        if let date, date > .distantPast {
            let days = Date().timeIntervalSince(date) / 86400
            Text(RelativeDate.text(date)).monospacedDigit()
                .foregroundStyle(days < 7 ? AnyShapeStyle(.primary) : days < 180 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .help(date.formatted(date: .long, time: .shortened))
        } else {
            Dash()
        }
    }
}

struct Dash: View {
    var body: some View { Text("—").foregroundStyle(.quaternary) }
}

/// A number with a leading glyph; zero recedes to a dash so the eye lands on what's non-zero.
struct CountView: View {
    var value: Int
    var systemImage: String
    var tint: Color
    var body: some View {
        if value == 0 {
            Dash()
        } else {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                Text("\(value)").monospacedDigit()
            }
        }
    }
}

/// GitHub avatars, read once per launch and kept in memory.
@MainActor final class AvatarCache {
    static let shared = AvatarCache()
    private var images: [URL: NSImage] = [:]
    private var loading: [URL: Task<Data?, Never>] = [:]

    func cached(_ url: URL) -> NSImage? { images[url] }

    func image(for url: URL) async -> NSImage? {
        if let image = images[url] { return image }
        let task = loading[url] ?? Task<Data?, Never> { try? await URLSession.shared.data(from: url).0 }
        loading[url] = task
        let data = await task.value
        loading[url] = nil
        if images[url] == nil, let data { images[url] = NSImage(data: data) }
        return images[url]
    }
}

/// A user's avatar (round) or an organization's (a rounded square, as on GitHub).
struct Avatar: View {
    var url: URL?
    var size: CGFloat = 16
    var square = false
    @State private var image: NSImage?

    var body: some View {
        let shape = square ? AnyShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)) : AnyShape(Circle())
        ZStack {
            if let image = image ?? url.flatMap({ AvatarCache.shared.cached($0) }) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                shape.fill(Color.primary.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .task(id: url) { if let url { image = await AvatarCache.shared.image(for: url) } }
    }
}

/// A small capsule badge such as “Fork” or “Draft”.
struct Tag: View {
    var text: String
    var tint: Color = GitHubColors.neutral
    var systemImage: String?

    init(_ text: String, tint: Color = GitHubColors.neutral, systemImage: String? = nil) {
        self.text = text; self.tint = tint; self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 8.5, weight: .bold)).foregroundStyle(tint) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
        .fixedSize()
        .help(text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// A GitHub label, in its own color.
struct LabelChip: View {
    var label: GitHubLookup.OpenItem.Label
    var body: some View {
        let value = UInt32(label.color.prefix(6), radix: 16) ?? 0x888888
        let luminance = 0.299 * Double(value >> 16 & 0xFF) + 0.587 * Double(value >> 8 & 0xFF) + 0.114 * Double(value & 0xFF)
        Text(label.name)
            .font(.system(size: 10, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .foregroundStyle(luminance > 150 ? Color.black : .white)
            .background(Capsule().fill(Color(hex: label.color)))
            .fixedSize()
            .help(label.name)
    }
}

struct RepoNameCell: View {
    var row: ProjectRow
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: row.repo.isPrivate ? "lock.fill" : "book.closed")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).frame(width: 12)
                .help(row.repo.isPrivate ? "Private" : "Public")
            Text(row.repo.name).fontWeight(.medium).lineLimit(1).layoutPriority(1)
            if row.repo.isFork { Tag("Fork", systemImage: "tuningfork") }
            if case .invalid = row.record { Tag("PROJECT.md", tint: GitHubColors.attention, systemImage: "exclamationmark") }
        }
        .help(row.metadata.map { "\($0.name) · \(row.repo.nameWithOwner)" } ?? row.repo.nameWithOwner)
    }
}

struct OwnerCell: View {
    var repo: GitHubLookup.Repo
    var body: some View {
        HStack(spacing: 6) {
            Avatar(url: repo.ownerAvatar, size: 16, square: repo.ownerIsOrganization)
            Text(repo.owner).lineLimit(1).foregroundStyle(.secondary)
        }
        .help(repo.owner)
    }
}

/// Where the code is deployed, from PROJECT.md: each target's machine (by the name BotChu knows it,
/// such as This Mac), Vercel project or registry, with an icon for its kind.
struct DeployCell: View {
    var row: ProjectRow
    /// What each target shows: a machine as BotChu knows it, else its name. Values rather than a
    /// lookup, so the cell is drawn again only when they change (#188).
    var names: [String]
    var body: some View {
        HStack(spacing: 8) {
            if case .loading = row.record {
                ProgressView().controlSize(.mini)
            } else if case .failed = row.record {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(GitHubColors.attention)
            } else if row.deploy.isEmpty {
                Dash()
            }
            ForEach(Array(zip(row.deploy, names).enumerated()), id: \.offset) { _, shown in
                let (target, name) = shown
                switch target.kind {
                case .none: Text(name).foregroundStyle(.tertiary)
                default:
                    HStack(spacing: 4) {
                        Image(systemName: Self.symbol(target.kind)).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(target.kind == .unrecognized ? GitHubColors.attention : GitHubColors.neutral)
                        Text(name)
                    }
                }
            }
        }
        .lineLimit(1)
        .help(help)
    }

    private var help: String {
        switch row.record {
        case .present(let metadata): metadata.deploy
        case .missing: "No PROJECT.md"
        case .failed(let error): "\(error) Refresh to try again."
        case .loading, .invalid: ""
        }
    }

    static func symbol(_ kind: DeployTarget.Kind) -> String {
        switch kind {
        case .local: "desktopcomputer"
        case .vercel: "cloud"
        case .registry: "shippingbox"
        case .none, .unrecognized: "questionmark.circle"
        }
    }
}

/// The project type from PROJECT.md, without its code/non-code suffix.
struct TypeCell: View {
    var row: ProjectRow
    var body: some View {
        switch row.record {
        case .loading: Dash()
        case .missing: Text("Unclassified").foregroundStyle(.tertiary).help("No PROJECT.md yet")
        case .invalid: Text("Unreadable").foregroundStyle(GitHubColors.attention).help("PROJECT.md could not be read")
        case .failed(let error): Text("Not read").foregroundStyle(GitHubColors.attention).help("\(error) Refresh to try again.")
        case .present(let metadata):
            Text(metadata.kind.label.components(separatedBy: " · ").first ?? metadata.kind.label).lineLimit(1)
                .foregroundStyle(metadata.status == .active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .help(metadata.status == .active ? metadata.kind.label : "\(metadata.kind.label), \(metadata.status.rawValue)")
        }
    }
}

/// Who may merge pull requests to the default branch, from PROJECT.md.
struct MergeCell: View {
    var row: ProjectRow
    var body: some View {
        switch row.metadata?.merge {
        case "agent": Text("Agent").foregroundStyle(GitHubColors.open).help("Agents may merge their own pull requests once checks pass")
        case "owner": Text("Owner").foregroundStyle(.secondary).help("Only the owner merges pull requests")
        default: Dash()
        }
    }
}

/// The computer tasks work on, and whether its checkout exists yet on this Mac.
struct WorkplaceCell: View {
    var row: ProjectRow
    var body: some View {
        let here = row.location.hostID == nil
        let path = here ? (row.location.path as NSString).abbreviatingWithTildeInPath : row.location.path
        let cloned = here && FileManager.default.fileExists(atPath: (row.location.path as NSString).appendingPathComponent(".git"))
        HStack(spacing: 4) {
            Text(row.workplace).lineLimit(1)
            Image(systemName: !here ? "network" : cloned ? "checkmark" : "arrow.down.circle")
                .font(.system(size: 10, weight: cloned ? .bold : .semibold))
                .foregroundStyle(cloned ? AnyShapeStyle(GitHubColors.open) : AnyShapeStyle(.tertiary))
        }
        .help(here && !cloned ? "Not cloned yet: \(path). The first task clones it." : "Tasks work in \(path)")
    }
}

struct ChecksIcon: View {
    var checks: GitHubLookup.OpenItem.Checks
    var body: some View {
        Group {
            switch checks {
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(GitHubColors.open)
            case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(GitHubColors.danger)
            case .pending: Image(systemName: "circle.dotted.circle").foregroundStyle(GitHubColors.attention)
            case .none: Dash()
            }
        }
        .help(checks.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(checks.label)
    }
}

struct ReviewBadge: View {
    var decision: String?
    var body: some View {
        switch decision {
        case "APPROVED": Tag("Approved", tint: GitHubColors.open, systemImage: "checkmark")
        case "CHANGES_REQUESTED": Tag("Changes requested", tint: GitHubColors.danger, systemImage: "exclamationmark")
        case "REVIEW_REQUIRED": Tag("Review required", tint: GitHubColors.attention, systemImage: "eye")
        default: Dash()
        }
    }
}

struct WorkTitleCell: View {
    var item: GitHubLookup.OpenItem
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.isPullRequest ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.isDraft ? GitHubColors.neutral : GitHubColors.open)
            Text(item.title).fontWeight(.medium).lineLimit(1).layoutPriority(1).help(item.title)
            if item.isDraft { Tag("Draft") }
            if item.fromFork { Tag("Fork", systemImage: "tuningfork") }
            ForEach(item.labels.prefix(3), id: \.name) { LabelChip(label: $0) }
            if item.labels.count > 3 { Text("+\(item.labels.count - 3)").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct WorkRepoCell: View {
    var item: GitHubLookup.OpenItem
    var repo: GitHubLookup.Repo?
    var body: some View {
        HStack(spacing: 6) {
            Avatar(url: repo?.ownerAvatar, size: 14, square: repo?.ownerIsOrganization ?? false)
            Text(item.repoName).lineLimit(1)
            Text("#\(item.number)").monospacedDigit().foregroundStyle(.tertiary)
        }
        .help("\(item.repo)#\(item.number)")
    }
}

struct PersonCell: View {
    var login: String
    var avatar: URL?
    var body: some View {
        HStack(spacing: 6) {
            Avatar(url: avatar, size: 16)
            Text(login).lineLimit(1).foregroundStyle(.secondary)
        }
    }
}

struct ChangesCell: View {
    var item: GitHubLookup.OpenItem
    var body: some View {
        HStack(spacing: 5) {
            Text("+\(item.additions)").foregroundStyle(GitHubColors.open)
            Text("−\(item.deletions)").foregroundStyle(GitHubColors.danger)
        }
        .font(.system(.body, design: .monospaced)).monospacedDigit()
    }
}

/// The bots with an open task on a repository, issue or pull request: their emoji, or a count.
struct TasksCell: View {
    var tasks: [(bot: Bot, task: BotTask)]
    var body: some View {
        if tasks.isEmpty {
            Dash()
        } else {
            HStack(spacing: 4) {
                Text(tasks.prefix(3).map(\.bot.emoji).joined())
                if tasks.count > 1 { Text("\(tasks.count)").monospacedDigit().foregroundStyle(.secondary) }
            }
            .help(tasks.map { "\($0.bot.name): \($0.task.title)" }.joined(separator: "\n"))
        }
    }
}
