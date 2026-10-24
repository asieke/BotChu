import Foundation
import Testing
@testable import BotChuCore

/// A transcript entry that can't be read is never lost when its conversation is next saved: the
/// original is kept beside it, byte for byte, and the conversation says so.
@Suite struct TranscriptTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    func tempHome() -> (root: URL, home: BotHome) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-transcripts-\(UUID().uuidString)")
        return (root, BotHome(workspace: root.appendingPathComponent("bot").path))
    }

    func line(_ message: ChatMessage) throws -> String {
        String(decoding: try Store.lineEncoder.encode(message), as: UTF8.self)
    }

    /// The copies kept beside `file`.
    func kept(beside file: URL) -> [URL] {
        let stem = file.deletingPathExtension().lastPathComponent + ".unreadable-"
        return ((try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(stem) }
    }

    /// A Home or task thread, a sub-agent's or a queue, each with its reader and writer.
    struct Conversation {
        let name: String
        let file: URL
        let load: () -> [ChatMessage]
        let save: ([ChatMessage]) throws -> Void
    }

    func conversations(_ home: BotHome) -> [Conversation] {
        let task = UUID(), run = UUID()
        return [
            Conversation(name: "home", file: home.threadURL, load: { home.loadThread() }, save: { try home.saveThread($0) }),
            Conversation(name: "task", file: home.taskThreadURL(task), load: { home.loadThread(task: task) },
                         save: { try home.saveThread($0, task: task) }),
            Conversation(name: "sub-agent", file: home.subagentURL(id: run, taskID: task).appendingPathComponent("thread.jsonl"),
                         load: { home.loadSubagentThread(id: run, taskID: task) },
                         save: { try home.saveSubagentThread($0, id: run, taskID: task) }),
            Conversation(name: "queue", file: home.url.appendingPathComponent("queued.jsonl"), load: { home.loadQueuedMessages() },
                         save: { try home.saveQueuedMessages($0) }),
        ]
    }

    @Test func missingAndEmptyFilesAreEmptyConversations() throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(TranscriptRead.read(home.threadURL) == TranscriptRead())
        try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
        try Data("\n  \n".utf8).write(to: home.threadURL)
        let read = TranscriptRead.read(home.threadURL)
        #expect(read.messages.isEmpty && !read.isDamaged && read.note(for: .conversation) == nil)
        #expect(home.loadThread().isEmpty)
        #expect(kept(beside: home.threadURL).isEmpty)
    }

    /// One line that isn't JSON, then a normal save: the readable messages stay, with a note, and
    /// the original is kept.
    @Test func anInvalidLineIsKeptBeforeTheNextSave() throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        for conversation in conversations(home) {
            let first = ChatMessage(role: .user, text: "first", date: date)
            let last = ChatMessage(role: .user, text: "last", date: date)
            try conversation.save([first, last])
            let original = Data((try line(first) + "\n{\"role\": \"user\", \"text\": tru\n" + line(last) + "\n").utf8)
            try original.write(to: conversation.file)

            let loaded = conversation.load()
            #expect(loaded.prefix(2) == [first, last], "\(conversation.name)")
            let next = ChatMessage(role: .user, text: "next", date: date)
            try conversation.save(loaded + [next])

            let copies = kept(beside: conversation.file)
            #expect(copies.count == 1, "\(conversation.name)")
            #expect(try copies.map { try Data(contentsOf: $0) } == [original], "\(conversation.name)")
            #expect(TranscriptRead.read(conversation.file).isDamaged == false, "\(conversation.name)")
            #expect(conversation.load().map(\.id).suffix(1) == [next.id], "\(conversation.name)")
        }
        // A conversation's note stays in it; a queue's is for its conversation (`readQueuedMessages`).
        let note = try #require(home.loadThread().first { $0.role == .note })
        #expect(note.text.hasPrefix("1 entry in this conversation couldn't be read (1 not valid JSON)"))
        #expect(note.text.contains(".botchu/thread.unreadable-"))
        #expect(!home.loadQueuedMessages().contains { $0.role == .note })
    }

    /// JSON that isn't a message this version knows, such as one from a newer BotChu with a new role.
    @Test func anUnsupportedRoleIsKeptBeforeTheNextSave() throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ChatMessage(role: .assistant, text: "Hello", date: date)
        try home.saveThread([first])
        let unknown = #"{"date":"2027-01-15T08:00:00Z","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"verdict","text":"Ship it"}"#
        let original = Data((try line(first) + "\n" + unknown + "\n").utf8)
        try original.write(to: home.threadURL)

        let loaded = home.loadThread()
        #expect(loaded.count == 2)
        #expect(loaded.first == first)
        #expect(loaded.last?.role == .note)
        #expect(loaded.last?.text.hasPrefix("1 entry in this conversation couldn't be read (1 of a kind this version of BotChu doesn't know), so it isn't shown.") == true)
        try home.saveThread(loaded + [ChatMessage(role: .user, text: "next", date: date)])

        let copy = try #require(kept(beside: home.threadURL).first)
        #expect(try Data(contentsOf: copy) == original)
        #expect(try String(contentsOf: copy, encoding: .utf8).contains(#""role":"verdict""#))
        #expect(home.loadThread().map(\.text).suffix(1) == ["next"])
    }

    /// A file that is no text at all reads as empty, and is kept.
    @Test func aWholeFileThatDoesNotDecodeIsKept() throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try home.saveThread([])
        let original = Data([0xFF, 0xFE, 0x00, 0x9F, 0x0A, 0xC3, 0x28, 0x7B])
        try original.write(to: home.threadURL)

        let read = TranscriptRead.read(home.threadURL, now: date)
        #expect(read.messages.isEmpty && read.malformed == 2 && read.unsupported == 0 && read.failure == nil)
        #expect(read.kept?.lastPathComponent == "thread.unreadable-\(TranscriptRead.stamp.string(from: date)).jsonl")
        // Reading it again keeps another copy, never replacing the first.
        #expect(TranscriptRead.read(home.threadURL, now: date).kept?.lastPathComponent == "thread.unreadable-\(TranscriptRead.stamp.string(from: date))-2.jsonl")

        let loaded = home.loadThread()
        #expect(loaded.map(\.role) == [.note])
        #expect(loaded.first?.text.hasPrefix("2 entries in this conversation couldn't be read (2 not valid JSON), so they aren't shown.") == true)
        try home.saveThread(loaded + [ChatMessage(role: .user, text: "next", date: date)])
        let copies = kept(beside: home.threadURL)
        #expect(copies.count == 3)
        #expect(try copies.allSatisfy { try Data(contentsOf: $0) == original })
    }

    /// A file that can't be read at all is moved aside, unchanged, and the conversation starts again.
    @Test func aFileThatCannotBeReadIsMovedAsideBeforeTheNextSave() throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = UUID()
        let message = ChatMessage(role: .user, text: "Remember the vault", date: date)
        try home.saveThread([message], task: task)
        try home.saveQueuedMessages([message], task: task)
        let file = home.taskThreadURL(task), queue = home.taskURL(task).appendingPathComponent("queued.jsonl")
        let original = try Data(contentsOf: file), originalQueue = try Data(contentsOf: queue)
        for unreadable in [file, queue] {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        }

        let loaded = home.loadThread(task: task)
        #expect(loaded.map(\.role) == [.note])
        #expect(loaded.first?.text.hasPrefix("This conversation's file couldn't be read (") == true)
        #expect(loaded.first?.text.contains("so it starts again here. The original file is kept, unchanged, at ") == true)
        let queued = home.readQueuedMessages(task: task)
        #expect(queued.messages.isEmpty && queued.failure != nil && queued.kept != nil)
        #expect(queued.note(for: .queue)?.text.hasPrefix("The file of pending messages couldn't be read (") == true)
        try home.saveThread(loaded + [ChatMessage(role: .user, text: "next", date: date)], task: task)
        try home.saveQueuedMessages([], task: task)

        for (unreadable, bytes) in [(file, original), (queue, originalQueue)] {
            let copy = try #require(kept(beside: unreadable).first)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
            #expect(try Data(contentsOf: copy) == bytes)
        }
        #expect(home.loadThread(task: task).map(\.text).suffix(1) == ["next"])
    }

    @Test func aQueueNotesWhatItCouldNotRead() throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let message = ChatMessage(role: .user, text: "Send me", date: date)
        try home.saveQueuedMessages([message])
        let file = home.url.appendingPathComponent("queued.jsonl")
        try Data((try line(message) + "\nnot json\n{\"id\": 1}\n").utf8).write(to: file)

        let read = home.readQueuedMessages()
        #expect(read.messages == [message] && read.malformed == 1 && read.unsupported == 1)
        let note = try #require(read.note(for: .queue, date: date))
        #expect(note.role == .note && note.date == date)
        #expect(note.text.hasPrefix("2 pending messages couldn't be read (1 not valid JSON, 1 of a kind this version of BotChu doesn't know), so they aren't sent. The original file is kept, unchanged, at "))
        // Saved with what could be read, so reading it again finds nothing new to keep.
        #expect(!home.readQueuedMessages().isDamaged)
        #expect(kept(beside: file).count == 1)
    }

    /// A relaunch (`recoverQueue`) with a line it can't read in each of the queue's files (#77's
    /// `taken.jsonl` too): both originals are kept, the readable pending message is recovered, the
    /// message the CLI took goes back into the transcript without being sent again, and the
    /// conversation notes what was left out. Home and a task.
    @Test(arguments: [false, true]) func recoveryKeepsUnreadableQueueEntries(inTask: Bool) throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let task: UUID? = inTask ? UUID() : nil
        func savedTranscript() -> [ChatMessage] { task.map { home.loadThread(task: $0) } ?? home.loadThread() }
        let start = ChatMessage(role: .user, text: "Fix the build", date: date)
        let steer = ChatMessage(role: .user, text: "Also run the tests", date: date)
        let later = ChatMessage(role: .user, text: "Then update the README", date: date)
        if let task { try home.saveThread([start], task: task) } else { try home.saveThread([start]) }
        // BotChu stopped after writing the taken message and before the pending ones: it is in both.
        try home.saveQueue(MessageQueue(saved: [steer, later]), task: task)
        let queued = home.queueURL(task: task), taken = queued.deletingLastPathComponent().appendingPathComponent("taken.jsonl")
        let originalQueue = Data((try line(steer) + "\nnot json\n" + line(later) + "\n").utf8)
        let originalTaken = Data((try line(steer) + "\n{\"id\": 1}\n").utf8)
        try originalQueue.write(to: queued)
        try originalTaken.write(to: taken)

        var transcript = savedTranscript()
        let recovered = home.recoverQueue(transcript: &transcript, task: task)
        #expect(recovered.failures.isEmpty)
        #expect(recovered.queue.messages.map(\.id) == [later.id])
        #expect(recovered.queue.next == later)
        #expect(recovered.queue.taken.isEmpty)
        #expect(transcript.map(\.role) == [.user, .user, .note, .note, .note])
        #expect(transcript.prefix(2).map(\.id) == [start.id, steer.id])
        #expect(transcript[3].text.hasPrefix("1 message the bot took couldn't be read (1 of a kind this version of BotChu doesn't know), so it isn't shown. The original file is kept, unchanged, at "))
        #expect(transcript[4].text.hasPrefix("1 pending message couldn't be read (1 not valid JSON), so it isn't sent. The original file is kept, unchanged, at "))
        #expect(savedTranscript().map(\.id) == transcript.map(\.id))
        for (file, original) in [(queued, originalQueue), (taken, originalTaken)] {
            #expect(try kept(beside: file).map { try Data(contentsOf: $0) } == [original])
        }
        #expect(!FileManager.default.fileExists(atPath: taken.path))
        #expect(home.loadQueuedMessages(task: task).map(\.id) == [later.id])

        // The next launch finds nothing new to keep or note, and still sends only the pending message.
        transcript = savedTranscript()
        let again = home.recoverQueue(transcript: &transcript, task: task)
        #expect(again.queue.messages.map(\.id) == [later.id])
        #expect(transcript.map(\.id) == savedTranscript().map(\.id))
        #expect(transcript.count == 5)
        #expect(kept(beside: queued).count == 1 && kept(beside: taken).count == 1)
    }
}
