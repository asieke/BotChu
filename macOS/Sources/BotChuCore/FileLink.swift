import Foundation

/// What a click on a link in a reply does (#363). A reply is a model's text, so a web page or a
/// mail address opens as the system would, a file only from its conversation's folder
/// (`FileLink`), and any other scheme (`shortcuts:`, `vscode:`, `ssh:`, `smb:`…), whose apps can
/// run or fetch things, not at all.
public enum ReplyLink: Equatable, Sendable {
    case web, file, none

    public static let webSchemes: Set<String> = ["http", "https", "mailto"]

    public init(_ link: URL) {
        if let scheme = link.scheme?.lowercased(), Self.webSchemes.contains(scheme) { self = .web }
        else if FileLink.names(link) { self = .file }
        else { self = .none }
    }
}

/// A link in a reply to a file (#363): `report.html`, `docs/plan.md` or a `file://` URL, rather
/// than a web page, an address or a place in the reply. It resolves against its conversation's
/// folder (`root(workspace:task:)`), and a click opens only a document inside it. A reply is a
/// model's text, so a click must not run or install anything, or reach outside that folder: what
/// could run or install, or isn't known to be a document, is shown in Finder instead, and what is
/// missing or outside, or in a task on another computer, does nothing.
public enum FileLink {
    public enum Action: Equatable, Sendable {
        /// A document, or a plain folder (`hasDirectoryPath`), at its real path: open it in the
        /// default app for its type.
        case open(URL)
        /// Something inside the folder that could run or install, or isn't known to be a
        /// document, at its real path: show it in Finder without opening it.
        case reveal(URL)
        /// Missing, outside the folder, or with no folder to resolve against.
        case ignore
    }

    /// The documents a click opens, by the extension of the file a link resolves to: their
    /// default apps show them. A list of what opens rather than of what doesn't, as some types
    /// that run or install pass for text (`.command`, `.mobileconfig`) and others for nothing in
    /// particular (`.terminal`, `.webloc`). Source code opens in an editor, but not scripts that
    /// a launcher runs (`.py`, `.rb`, `.js`, `.sh`, `.jsx`).
    public static let documents: Set<String> = [
        "html", "htm", "md", "markdown", "txt", "json", "csv", "tsv", "log", "yaml", "yml", "xml",
        "pdf", "rtf", "docx", "xlsx", "pptx", "pages", "numbers", "key",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "svg",
        "mp3", "m4a", "wav", "aiff", "mp4", "mov", "m4v",
        "swift", "c", "h", "cpp", "hpp", "m", "mm", "rs", "go", "java", "kt", "ts", "tsx", "css", "scss",
        "sql", "toml", "ini", "plist", "diff", "patch",
    ]

    /// Folders that are apps, plug-ins or installers, revealed even where the system doesn't take
    /// them for packages.
    static let bundles: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "prefpane", "saver", "workflow", "action",
        "scptd", "pkg", "mpkg", "xpc", "qlgenerator", "mdimporter",
    ]

    /// The folder a conversation's file links resolve against: a task's worktree, or the bot's
    /// folder for Home. None for a task on another computer, whose folder isn't on this Mac, or
    /// one without its worktree yet.
    public static func root(workspace: String, task: BotTask?) -> String? {
        guard let task else { return workspace }
        return task.isRemote ? nil : task.folder
    }

    /// Whether a link names a file: it has no scheme or `file`, and is more than a place in the
    /// reply (`#notes`).
    public static func names(_ link: URL) -> Bool {
        guard let scheme = link.scheme else { return !link.path.isEmpty || link.host != nil }
        return scheme.lowercased() == "file"
    }

    /// What a click on `link` does in a conversation whose folder is `root`. Every link is
    /// resolved, `..` and symbolic links alike, as the system will, and must end inside the
    /// folder, itself resolved; the result names what was checked.
    public static func action(for link: URL, root: String?) -> Action {
        guard names(link), let root, let folder = ToolLocator.realPath(root) else { return .ignore }
        // `file://host/…` and `//host/…` name another computer's file.
        if let host = link.host, !host.isEmpty, host.lowercased() != "localhost" { return .ignore }
        // The path as written, percent-escapes and all, decoded once; no `~` for a home folder.
        let path = link.path
        guard !path.isEmpty, !path.contains("\0") else { return .ignore }
        guard let real = ToolLocator.realPath(path.hasPrefix("/") ? path : folder + "/" + path),
              components(real).starts(with: components(folder)) else { return .ignore }
        var info = stat()
        guard stat(real, &info) == 0 else { return .ignore }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            let url = URL(fileURLWithPath: real, isDirectory: true)
            let package = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? true
            return package || bundles.contains(url.pathExtension.lowercased()) ? .reveal(url) : .open(url)
        case S_IFREG:
            let url = URL(fileURLWithPath: real, isDirectory: false)
            let executable = info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
            return executable || !documents.contains(url.pathExtension.lowercased()) ? .reveal(url) : .open(url)
        default:
            return .ignore
        }
    }

    /// A path's names, compared as Swift compares strings (canonically equivalent ones are
    /// equal), never by prefix: `/a/root-b` isn't inside `/a/root`.
    private static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// The scheme a rich reply's page links a file with (`RichMarkdown`): its page is the app's
    /// own, so a link relative to it would name a file in the app.
    public static let pageScheme = "botchu-file"
    private static let pageCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    /// The address a rich reply's page gives a file link: the link as written, escaped to letters,
    /// digits and `%`, after `pageScheme`. Nil for a link that doesn't name a file.
    public static func pageLink(_ link: URL) -> String? {
        guard names(link), let escaped = link.absoluteString.addingPercentEncoding(withAllowedCharacters: pageCharacters) else { return nil }
        return pageScheme + ":" + escaped
    }

    /// The file link a rich reply's page address stands for (`pageLink(_:)`), or nil.
    public static func link(fromPage address: URL) -> URL? {
        guard address.scheme?.lowercased() == pageScheme else { return nil }
        let escaped = address.absoluteString.dropFirst(pageScheme.count + 1)
        guard let link = String(escaped).removingPercentEncoding.flatMap(URL.init(string:)), names(link) else { return nil }
        return link
    }
}
