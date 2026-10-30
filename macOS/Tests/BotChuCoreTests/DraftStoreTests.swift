import Foundation
import Testing
@testable import BotChuCore

/// #357: what is typed in a message box and not sent is still there after a relaunch, kept where
/// only the owner can read it, and gone once it is sent, cleared or its conversation is.
/// These tests block only their own threads, never the main one, which other suites time.
@Suite struct DraftStoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-drafts-\(UUID().uuidString)", isDirectory: true)
    let bot = UUID(), task = UUID()

    func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }

    func names(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    @Test func aDraftComesBackWithItsReferencesInItsOwnConversationOnly() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = DraftStore(root: root), storage = StorageQueue()
        let references = [MessageReference(kind: .agent, target: UUID().uuidString.lowercased(), label: "@QA Duck", location: 4),
                          MessageReference(kind: .project, target: "asieke/BotChu", label: "#asieke/BotChu", location: 18, login: "asieke")]
        let typed = ComposerDraft(text: "Ask @QA Duck about #asieke/BotChu\n  and keep this line ", references: references)
        drafts.save(typed, for: .init(bot: bot, task: task), storage: storage)
        drafts.save(ComposerDraft(text: "Home's own"), for: .init(bot: bot), storage: storage)
        await storage.settle()

        let restored = DraftStore(root: root).restore(tasks: [bot: [task]])
        #expect(restored == [.init(bot: bot, task: task): typed, .init(bot: bot): ComposerDraft(text: "Home's own")])
        #expect(restored[.init(bot: bot, task: task)]?.references == references)
    }

    @Test func draftsAreTheOwnersAloneAndLeftOutOfBackups() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = DraftStore(root: root), storage = StorageQueue()
        // A folder left readable to others (made by hand, or by an older build) is closed up.
        try FileManager.default.createDirectory(at: drafts.folder(bot: bot), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: drafts.url.path)
        // So is a file: `Data.write(.atomic)` would keep its mode, or make a new one 0644.
        let file = drafts.fileURL(.init(bot: bot))
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        drafts.save(ComposerDraft(text: "sk-not-a-real-key"), for: .init(bot: bot), storage: storage)
        drafts.save(ComposerDraft(text: "a task's"), for: .init(bot: bot, task: task), storage: storage)
        await storage.settle()

        #expect(try mode(drafts.url) == 0o700)
        #expect(try mode(drafts.folder(bot: bot)) == 0o700)
        #expect(try mode(file) == 0o600)
        #expect(try mode(drafts.fileURL(.init(bot: bot, task: task))) == 0o600)
        #expect(try drafts.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(names(drafts.folder(bot: bot)) == ["home.json", task.uuidString.lowercased() + ".json"].sorted(), "No file is left from the writes")
    }

    @Test func aNewFileIsOwnerOnlyFromTheMomentItIsMade() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("draft.json")
        try DraftStore.writeOwnerOnly(Data("one".utf8), to: file)
        #expect(try mode(file) == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one")
        // A write that can't land leaves nothing beside the file it was for.
        let folder = root.appendingPathComponent("a-folder.json", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("inside"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try DraftStore.writeOwnerOnly(Data("two".utf8), to: folder) }
        #expect(names(root) == ["a-folder.json", "draft.json"])
    }

    @Test func changesWaitTogetherAndOnlyTheLastIsWrittenAsQuittingWrites() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let lanes = Box()
        let storage = StorageQueue(before: { lanes.append($0.lane) })
        // A delay no test waits out: only quitting's `wait` writes what waits.
        let drafts = DraftStore(root: root, delay: 60)
        let key = DraftStore.Key(bot: bot, task: task)
        for text in ["H", "He", "Hel", "Hell", "Hello"] { drafts.save(ComposerDraft(text: text), for: key, storage: storage) }
        #expect(!FileManager.default.fileExists(atPath: drafts.fileURL(key).path))
        #expect(storage.wait(timeout: 10).isEmpty)
        #expect(lanes.all == [drafts.fileURL(key).path], "Five changes, one write")
        #expect(DraftStore(root: root).restore(tasks: [bot: [task]])[key] == ComposerDraft(text: "Hello"))
        #expect(storage.stats.coalesced == 4)
    }

    @Test func aSentOrClearedDraftIsRemovedAheadOfAWriteWaitingForIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageQueue()
        let drafts = DraftStore(root: root, delay: 60)
        let key = DraftStore.Key(bot: bot)
        drafts.save(ComposerDraft(text: "To send"), for: key, storage: storage)
        #expect(storage.wait(timeout: 10).isEmpty)
        #expect(FileManager.default.fileExists(atPath: drafts.fileURL(key).path))
        // Typing on waits its delay; sending (or clearing the box) doesn't, and takes its place.
        drafts.save(ComposerDraft(text: "To send, and more"), for: key, storage: storage)
        drafts.save(nil, for: key, storage: storage)
        await storage.settle()
        #expect(names(drafts.folder(bot: bot)).isEmpty, "Nothing is left behind, not even an empty file")
        #expect(DraftStore(root: root).restore(tasks: [bot: []]).isEmpty)
        // A box holding only an empty string is a cleared one.
        drafts.save(ComposerDraft(text: "Again"), for: key, storage: storage)
        drafts.save(ComposerDraft(text: ""), for: key, storage: storage)
        await storage.settle()
        #expect(names(drafts.folder(bot: bot)).isEmpty)
    }

    @Test func aDeletedBotsDraftsGoAndAWriteWaitingForThemNeverMakesThemAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageQueue()
        let drafts = DraftStore(root: root, delay: 0.05)
        let other = UUID()
        drafts.save(ComposerDraft(text: "Home"), for: .init(bot: bot), storage: storage)
        drafts.save(ComposerDraft(text: "Another bot's"), for: .init(bot: other), storage: storage)
        await storage.settle()
        drafts.save(ComposerDraft(text: "Typed as it went"), for: .init(bot: bot, task: task), storage: storage)
        drafts.removeBot(bot, storage: storage, timeout: 5)
        await storage.settle()
        #expect(!FileManager.default.fileExists(atPath: drafts.folder(bot: bot).path))
        #expect(names(drafts.url) == [other.uuidString.lowercased()])
        // Its folder takes drafts again (a bot made with its id, in tests).
        drafts.save(ComposerDraft(text: "Later"), for: .init(bot: bot), storage: storage)
        await storage.settle()
        #expect(FileManager.default.fileExists(atPath: drafts.fileURL(.init(bot: bot)).path))
    }

    @Test func aWriteThatOutlastsDeletingItsBotLeavesNothingBehind() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let writing = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let storage = StorageQueue()
        var drafts = DraftStore(root: root, delay: 0)
        // The write has its draft and is under way when the bot is deleted, and outlasts the wait.
        drafts.writing = { _ in
            writing.signal()
            proceed.wait()
        }
        drafts.save(ComposerDraft(text: "Being written"), for: .init(bot: bot), storage: storage)
        writing.wait()
        drafts.removeBot(bot, storage: storage, timeout: 0.05)
        proceed.signal()
        for _ in 0..<500 where FileManager.default.fileExists(atPath: drafts.folder(bot: bot).path) || !storage.isIdle() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!FileManager.default.fileExists(atPath: drafts.folder(bot: bot).path))
    }

    @Test func launchPutsBackOnlyTheDraftsOfConversationsThereAreAndSweepsTheRest() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = DraftStore(root: root)
        let gone = UUID(), missing = UUID(), deletedTask = UUID(), unreadTask = UUID(), corruptTask = UUID(), emptyTask = UUID(), unknownTask = UUID()
        func put(_ text: String, _ bot: UUID, _ name: String) throws {
            try FileManager.default.createDirectory(at: drafts.folder(bot: bot), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: drafts.folder(bot: bot).appendingPathComponent(name))
        }
        let json = { (text: String) in String(decoding: try Store.encoder.encode(ComposerDraft(text: text)), as: UTF8.self) }
        try put(json("Home"), bot, "home.json")
        try put(json("Task"), bot, task.uuidString.lowercased() + ".json")
        try put(json("A deleted task's"), bot, deletedTask.uuidString.lowercased() + ".json")
        try put(json("A task whose record couldn't be read"), bot, unreadTask.uuidString.lowercased() + ".json")
        try put("{\"text\": \"cut off", bot, corruptTask.uuidString.lowercased() + ".json")
        try put(json(""), bot, emptyTask.uuidString.lowercased() + ".json")
        try put("half", bot, ".home.json.\(UUID().uuidString).tmp")
        try put("?", bot, "notes.txt")
        try put(json("A deleted bot's"), gone, "home.json")
        try put(json("On a drive not connected"), missing, unknownTask.uuidString.lowercased() + ".json")
        try put("half", missing, ".home.json.\(UUID().uuidString).tmp")
        try Data("?".utf8).write(to: drafts.url.appendingPathComponent("stray"))

        // Its folder is there, so it isn't gone: its draft waits for it, not put back meanwhile.
        let restored = drafts.restore(tasks: [bot: [task, corruptTask, emptyTask]], missing: [missing]) { $0.task != unreadTask }
        #expect(restored == [.init(bot: bot): ComposerDraft(text: "Home"), .init(bot: bot, task: task): ComposerDraft(text: "Task")])
        #expect(names(drafts.url).sorted() == [bot.uuidString.lowercased(), missing.uuidString.lowercased()].sorted())
        #expect(names(drafts.folder(bot: bot)) == ["home.json", task.uuidString.lowercased() + ".json", unreadTask.uuidString.lowercased() + ".json"].sorted())
        #expect(names(drafts.folder(bot: missing)) == [unknownTask.uuidString.lowercased() + ".json"], "A missing bot keeps its drafts")
        // Nothing to restore from a folder never made.
        #expect(DraftStore(root: root.appendingPathComponent("none")).restore(tasks: [bot: [task]]).isEmpty)
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ value: String) { lock.withLock { stored.append(value) } }
        var all: [String] { lock.withLock { stored } }
    }
}
