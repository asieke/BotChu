import Foundation
import Testing
@testable import BotChuCore

/// Links in replies to files (#363): what a click opens, shows in Finder, or leaves alone.
@Suite struct FileLinkTests {
    /// A conversation's folder, `root`, beside files outside it. The temporary folder is under
    /// `/var`, itself a link to `/private/var`, so every test resolves a linked root.
    final class Folder {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-file-link-\(UUID().uuidString)")
        var root: URL { base.appendingPathComponent("root") }
        /// Where a link to `path` in the root resolves: its real path.
        func real(_ path: String, directory: Bool = false) -> URL {
            URL(fileURLWithPath: ToolLocator.realPath(base.path)! + "/" + path, isDirectory: directory)
        }

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        @discardableResult func file(_ path: String, mode: Int = 0o644) throws -> URL {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("<p>hi</p>".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url
        }

        func folder(_ path: String) throws {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(path), withIntermediateDirectories: true)
        }

        func link(_ path: String, to destination: String) throws {
            try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent(path).path, withDestinationPath: destination)
        }

        func action(_ link: String) -> FileLink.Action {
            FileLink.action(for: URL(string: link)!, root: root.path)
        }

        deinit { try? FileManager.default.removeItem(at: base) }
    }

    @Test func relativeLinksAndFileURLsOpenDocumentsInTheRoot() throws {
        let folder = try Folder()
        try folder.file("root/model-power-rankings-oct-2026.html")
        try folder.file("root/docs/my report.pdf")
        try folder.file("root/résumé.md")
        try folder.file("root/REPORT.HTML")
        try folder.file("root/Sources/App.swift")
        let report = folder.real("root/model-power-rankings-oct-2026.html")
        #expect(folder.action("model-power-rankings-oct-2026.html") == .open(report))
        #expect(folder.action("./model-power-rankings-oct-2026.html#ranks") == .open(report))
        #expect(folder.action("model-power-rankings-oct-2026.html?sort=1") == .open(report))
        #expect(folder.action("docs/my%20report.pdf") == .open(folder.real("root/docs/my report.pdf")))
        #expect(folder.action("docs/../model-power-rankings-oct-2026.html") == .open(report))
        #expect(folder.action("r%C3%A9sum%C3%A9.md") == .open(folder.real("root/résumé.md")))
        #expect(folder.action("REPORT.HTML") == .open(folder.real("root/REPORT.HTML")))
        #expect(folder.action("Sources/App.swift") == .open(folder.real("root/Sources/App.swift")))
        // A file URL, or an absolute path, to a file in the root: as written by the bot, through
        // `/var`, or already resolved.
        let written = folder.root.appendingPathComponent("model-power-rankings-oct-2026.html")
        #expect(FileLink.action(for: written, root: folder.root.path) == .open(report))
        #expect(folder.action("file://localhost" + written.path) == .open(report))
        #expect(folder.action(report.absoluteString) == .open(report))
        #expect(folder.action(written.path) == .open(report))
    }

    @Test func nothingOutsideTheRootOpens() throws {
        let folder = try Folder()
        try folder.file("outside.html")
        try folder.file("root-evil/report.html")
        try folder.file("root/inside.html")
        for link in ["../outside.html", "%2e%2e%2foutside.html", "..%2Foutside.html", "inside.html/../../outside.html",
                     "sub/../../outside.html", "../root-evil/report.html", "/etc/hosts", "file:///etc/hosts",
                     folder.base.appendingPathComponent("outside.html").absoluteString,
                     folder.real("root-evil/report.html").path,
                     "~/outside.html", "missing.html", "inside.html%00.command", "file://evil.example/" + folder.root.path + "/inside.html",
                     "//evil.example/inside.html"] {
            #expect(folder.action(link) == .ignore, "\(link)")
        }
        // A root that isn't there, or none.
        #expect(FileLink.action(for: URL(string: "inside.html")!, root: folder.base.appendingPathComponent("gone").path) == .ignore)
        #expect(FileLink.action(for: URL(string: "inside.html")!, root: nil) == .ignore)
    }

    @Test func symbolicLinksAreFollowedAndMustEndInTheRoot() throws {
        let folder = try Folder()
        try folder.file("outside.html")
        try folder.file("secrets/notes.md")
        try folder.file("root/real.html")
        try folder.link("root/out.html", to: folder.base.appendingPathComponent("outside.html").path)
        try folder.link("root/escape", to: "../secrets")
        try folder.link("root/alias.html", to: "real.html")
        try folder.link("root/loop.html", to: "loop.html")
        #expect(folder.action("out.html") == .ignore)
        #expect(folder.action("escape/notes.md") == .ignore)
        #expect(folder.action("escape") == .ignore)
        #expect(folder.action("loop.html") == .ignore)
        // A link within the root opens what it leads to, which is what was checked.
        #expect(folder.action("alias.html") == .open(folder.real("root/real.html")))
        // A root reached through a link of its own resolves too.
        try folder.link("shortcut", to: "root")
        #expect(FileLink.action(for: URL(string: "real.html")!, root: folder.base.appendingPathComponent("shortcut").path)
                == .open(folder.real("root/real.html")))
    }

    @Test func whatCouldRunOrInstallIsRevealedNotOpened() throws {
        let folder = try Folder()
        for name in ["build.command", "run.tool", "Basic.terminal", "go.sh", "tool.py", "x.rb", "x.js", "x.jsx", "x.scpt", "x.applescript", "x.workflow",
                     "x.pkg", "x.mpkg", "x.dmg", "x.mobileconfig", "x.jar", "x.shortcut", "x.webloc", "x.inetloc", "x.fileloc",
                     "x.url", "x.ipa", "x.docm", "x.zip", "x.ics", "Makefile", ".env"] {
            try folder.file("root/" + name)
            #expect(folder.action(name) == .reveal(folder.real("root/" + name)), "\(name)")
        }
        // A document marked executable could be run as a program.
        try folder.file("root/report.html", mode: 0o755)
        try folder.file("root/notes.txt", mode: 0o641)
        #expect(folder.action("report.html") == .reveal(folder.real("root/report.html")))
        #expect(folder.action("notes.txt") == .reveal(folder.real("root/notes.txt")))
        // Apps, bundles and other packages are folders: shown, never opened.
        for name in ["Tool.app", "Plug.bundle", "Flow.workflow", "Script.scptd", "Pane.prefPane", "Kit.framework", "Doc.rtfd", "Install.pkg"] {
            try folder.folder("root/" + name + "/Contents")
            #expect(folder.action(name) == .reveal(folder.real("root/" + name, directory: true)), "\(name)")
            #expect(folder.action(name + "/Contents") == .open(folder.real("root/" + name + "/Contents", directory: true)), "\(name)")
        }
    }

    @Test func plainFoldersOpenAndOtherFilesAreLeftAlone() throws {
        let folder = try Folder()
        try folder.folder("root/out/charts")
        #expect(folder.action("out/charts/") == .open(folder.real("root/out/charts", directory: true)))
        #expect(folder.action(".") == .open(folder.real("root", directory: true)))
        if case .open(let url) = folder.action("out") { #expect(url.hasDirectoryPath) } else { Issue.record("The folder doesn't open") }
        let fifo = folder.root.appendingPathComponent("pipe.txt").path
        #expect(mkfifo(fifo, 0o644) == 0)
        #expect(folder.action("pipe.txt") == .ignore)
    }

    @Test func onlyLinksWithoutASchemeOrToFilesAreFileLinks() {
        for link in ["report.html", "docs/plan.md", "file:///tmp/x.html", "FILE:///tmp/x.html", "../x", "/etc/hosts", "report.html#top", "//host/x"] {
            #expect(FileLink.names(URL(string: link)!), "\(link)")
        }
        for link in ["https://example.com/report.html", "http://example.com", "mailto:alex@example.com", "#top", "?q=1",
                     "javascript:alert(1)", "data:text/html,hi", "x-apple.systempreferences:com.apple.preference.security",
                     "vscode://file/tmp/x", "ssh://host", "smb://host/share", "C:\\x", "botchu-file:report%2Ehtml"] {
            #expect(!FileLink.names(URL(string: link)!), "\(link)")
            #expect(FileLink.action(for: URL(string: link)!, root: "/tmp") == .ignore, "\(link)")
        }
    }

    @Test func onlyWebPagesMailAndFilesAreReplyLinksThatOpen() {
        for link in ["https://example.com/report.html", "HTTP://example.com", "mailto:alex@example.com"] {
            #expect(ReplyLink(URL(string: link)!) == .web, "\(link)")
        }
        for link in ["report.html", "file:///tmp/x.html", "../x", "//host/x"] {
            #expect(ReplyLink(URL(string: link)!) == .file, "\(link)")
        }
        for link in ["#top", "?q=1", "javascript:alert(1)", "data:text/html,hi", "shortcuts://run-shortcut?name=Wipe",
                     "x-apple.systempreferences:com.apple.preference.security", "vscode://file/tmp/x", "ssh://host", "smb://host/share",
                     "botchu-file:report%2Ehtml", "C:\\x"] {
            #expect(ReplyLink(URL(string: link)!) == .none, "\(link)")
        }
    }

    @Test func aConversationsFolderIsItsTasksWorktreeOrTheBotsAndNoneOnAnotherComputer() {
        let bot = Bot(name: "Scout", workspace: "/Users/alex/Desktop/BOTS/Scout")
        var task = BotTask(for: bot, repo: "octocat/hello-world", checkout: "/Users/alex/hello-world", work: nil, brief: "Look")
        #expect(FileLink.root(workspace: bot.workspace, task: nil) == bot.workspace)
        #expect(FileLink.root(workspace: bot.workspace, task: task) == nil)
        task.folder = "/Users/alex/hello-world/.claude/worktrees/fix-x"
        #expect(FileLink.root(workspace: bot.workspace, task: task) == task.folder)
        task.hostID = UUID()
        #expect(FileLink.root(workspace: bot.workspace, task: task) == nil)
    }

    @Test func aRichReplysPageCarriesTheLinkAsWritten() throws {
        for link in ["report.html", "my%20report.html", "../x.html", "file:///tmp/a%20b.html", "docs/plan.md#top", "r%C3%A9sum%C3%A9.md"] {
            let page = try #require(FileLink.pageLink(URL(string: link)!))
            #expect(page.hasPrefix("botchu-file:"))
            #expect(page.dropFirst("botchu-file:".count).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "%") }, "\(page)")
            #expect(FileLink.link(fromPage: try #require(URL(string: page)))?.absoluteString == link)
        }
        #expect(FileLink.pageLink(URL(string: "https://example.com")!) == nil)
        #expect(FileLink.pageLink(URL(string: "#top")!) == nil)
        #expect(FileLink.link(fromPage: URL(string: "https://example.com/report.html")!) == nil)
        #expect(FileLink.link(fromPage: URL(string: "file:///tmp/report.html")!) == nil)
        // A page address that decodes to something other than a file link isn't one.
        #expect(FileLink.link(fromPage: URL(string: "botchu-file:https%3A%2F%2Fexample%2Ecom")!) == nil)
    }
}
