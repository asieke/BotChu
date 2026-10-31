import Foundation
import Testing
@testable import BotChuCore

@Suite struct ImageAttachmentTests {
    @Test func imagesPersistWithQueuesAndOldMessagesStillDecode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.path)
        let bytes = Data([1, 2, 3, 4])
        let image = try home.saveImage(bytes, name: "a screenshot.png")
        #expect(try Data(contentsOf: home.imageURL(image)) == bytes)
        let message = ChatMessage(role: .user, images: [image])
        var queue = MessageQueue()
        queue.enqueue(message)
        #expect(queue.messages == [message])
        let task = UUID()
        try home.saveQueuedMessages(queue.messages, task: task)
        #expect(home.loadQueuedMessages(task: task).first?.images == [image])
        try home.saveThread([message], task: task)
        #expect(MessageQueue(saved: home.loadQueuedMessages(task: task), delivered: home.loadThread(task: task)).messages.isEmpty)
        let old = ChatMessage(role: .user, text: "Before images")
        let encoded = try JSONEncoder().encode(old)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("attachments"))
        #expect(try JSONDecoder().decode(ChatMessage.self, from: encoded).images.isEmpty)
        let moved = root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        #expect(try Data(contentsOf: BotHome(workspace: moved.path).imageURL(image)) == bytes)
    }

    @Test func everyProviderAttachesImagesOnNewAndResumedTurns() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("image with spaces-\(UUID()).png")
        let data = Data([0, 1, 2, 3])
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for kind in AgentKind.allCases {
            for session in [nil, "resumed-session"] as [String?] {
                let plain = CommandBuilder.invocation(kind: kind, prompt: "Look\nat this", model: nil, sessionID: session)
                #expect(try ImageDelivery.attaching([], to: plain, kind: kind, prompt: "Look\nat this") == plain)
                let attached = try ImageDelivery.attaching([file], to: plain, kind: kind, prompt: "Look\nat this")
                #expect(attached.sessionID == plain.sessionID)
                if kind == .claude {
                    #expect(attached.arguments.contains("--input-format"))
                    #expect(!attached.arguments.contains("Look\nat this"))
                    let payload = try #require(attached.standardInput)
                    let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
                    let message = try #require(object["message"] as? [String: Any])
                    let content = try #require(message["content"] as? [[String: Any]])
                    #expect(content.first?["text"] as? String == "Look\nat this")
                    let source = try #require(content.last?["source"] as? [String: String])
                    #expect(source["data"].flatMap { Data(base64Encoded: $0) } == data)
                    #expect(source["media_type"] == "image/png")
                } else if kind == .antigravity {
                    #expect(attached.arguments[1].contains(file.path))
                    #expect(attached.arguments[1].hasPrefix("Look\nat this"))
                    #expect(attached.standardInput == nil)
                } else {
                    #expect(attached.standardInput == nil)
                    #expect(attached.arguments.contains(kind == .pi ? "@" + file.path : file.path))
                    #expect(attached.arguments.last == "Look\nat this")
                    if kind != .pi { #expect(attached.arguments.contains("--image")) }
                }
            }
        }
    }

    @Test func stdinTransfersPayloadLargerThanAPipeBuffer() async throws {
        let payload = Data(repeating: 65, count: 300_000)
        let result = await Shell.run(["/usr/bin/wc", "-c"], in: NSTemporaryDirectory(), input: payload)
        #expect(result.ok)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "300000")
    }

    @Test func remoteImagesAndAgentStdinArriveIntact() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("image with spaces-\(UUID()).png")
        let data = Data(repeating: 65, count: 300_000)
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let machine = FakeSSH.machine
        let staged = try await machine.stageImages([source])
        defer { for url in staged { try? FileManager.default.removeItem(at: url) } }
        #expect(staged.count == 1)
        #expect(staged.first != source)
        #expect(try Data(contentsOf: #require(staged.first)) == data)
        let result = try await withCheckedThrowingContinuation { (done: CheckedContinuation<[String], any Error>) in
            DispatchQueue.main.async {
                let run = AgentRun(command: "/usr/bin/wc", invocation: Invocation(arguments: ["-c"], standardInput: data),
                                   on: machine, folder: NSTemporaryDirectory())
                var lines: [String] = []
                run.onLines = { lines += $0 }
                run.onExit = { status, stderr in
                    if status == 0 { done.resume(returning: lines) }
                    else { done.resume(throwing: ImageDelivery.Failure(stderr)) }
                }
                do { try run.start() } catch { done.resume(throwing: error) }
            }
        }
        #expect(result.joined().trimmingCharacters(in: .whitespacesAndNewlines) == "300000")
    }

    @Test func rejectsTooManyOrMissingInlineImages() throws {
        let plain = CommandBuilder.invocation(kind: .claude, prompt: "Look", model: nil, sessionID: nil)
        let missing = URL(fileURLWithPath: "/missing-\(UUID()).png")
        #expect(throws: (any Error).self) { try ImageDelivery.attaching([missing], to: plain, kind: .claude, prompt: "Look") }
        #expect(throws: (any Error).self) { try ImageDelivery.attaching(Array(repeating: missing, count: 9), to: plain, kind: .codex, prompt: "Look") }
    }

    /// #64: a paste gives the picture a screenshot or a browser's Copy Image offers, alone or ahead
    /// of any text; copied text that comes with a picture of itself (a spreadsheet's cells) pastes
    /// as text.
    @Test func aPictureOfCopiedTextPastesAsText() {
        let images: Set<String> = ["public.png", "public.tiff"]
        func image(_ types: [String]) -> String? { PasteboardOrder.image(in: types, isImage: images.contains) }
        let text = PasteboardOrder.plainText
        #expect(image(["public.png"]) == "public.png")
        #expect(image(["public.html", "public.png"]) == "public.png")
        #expect(image(["public.tiff", text]) == "public.tiff")
        #expect(image([text, "public.rtf", "public.tiff"]) == nil)
        #expect(image(["public.html"]) == nil)
        #expect(image([]) == nil)
    }
}
