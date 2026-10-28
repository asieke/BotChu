import Foundation
import Testing
@testable import BotChuCore

@Suite struct SensitiveInputTests {
    func folder() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func exactValueOnlyAtExclusivePrivateDestination() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("key").path
        let fixture = "synthetic-secret \nwith spaces"
        try SensitiveInputDestination.check(path)
        try SensitiveInputDestination.save(fixture, to: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == fixture)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(throws: SensitiveInputError.self) { try SensitiveInputDestination.save("replacement", to: path) }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == fixture)
        let receipt = try SubagentIPC.encode(SensitiveInputResult(id: UUID(), status: .saved))
        #expect(!String(decoding: receipt, as: UTF8.self).contains(fixture))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["key"])
    }

    @Test func destinationRejectsTraversalLinksExistingFilesAndInvalidValues() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        for path in ["relative", "/tmp/../key", "/tmp/./key", "/tmp//key", "/tmp/key\n", "/tmp/.git/key", "/tmp/.botchu/key", "/private/tmp/.Git/key", "/private/tmp/.BOTCHU/key", link.appendingPathComponent("key").path] {
            #expect(throws: SensitiveInputError.self) { try SensitiveInputDestination.save("fixture", to: path) }
        }
        let path = actual.appendingPathComponent("key").path
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: actual.appendingPathComponent("target").path)
        #expect(throws: SensitiveInputError.self) { try SensitiveInputDestination.save("fixture", to: path) }
        #expect(!FileManager.default.fileExists(atPath: actual.appendingPathComponent("target").path))
        for value in ["", String(repeating: "a", count: 65537)] {
            #expect(throws: SensitiveInputError.self) { try SensitiveInputDestination.save(value, to: root.appendingPathComponent("absent").path) }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("absent").path))
    }

    @Test func privateMailboxExclusionUsesComponentsAndIgnoresCase() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SensitiveInputDestination.isWithin(root.path + "/key", directory: root.path))
        #expect(SensitiveInputDestination.isWithin(root.path.uppercased() + "/key", directory: root.path))
        #expect(!SensitiveInputDestination.isWithin(root.path + "-other/key", directory: root.path))
        // The app's root may have been specified through macOS's /tmp alias.
        let alias = root.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")
        #expect(SensitiveInputDestination.isWithin(root.path + "/key", directory: alias))
    }

    @Test func validationBindsCallerAndExpiry() throws {
        let invocation = UUID(), bot = UUID(), task = UUID(), parent = UUID()
        let now = Date()
        let caller = SubagentCallerContext(invocationID: invocation, botID: bot, taskID: task,
            parentSubagentID: parent, depth: 1, workingDirectory: "/workspace", hostID: nil)
        var request = SensitiveInputRequest(invocationID: invocation, callerBotID: bot, callerTaskID: task,
            parentSubagentID: parent, label: "Test key", destination: "/private/tmp/new-key", createdAt: now)
        try request.validate(caller: caller, now: now)
        var remote = caller
        remote.hostID = UUID()
        #expect(throws: SensitiveInputError.self) { try request.validate(caller: remote, now: now) }
        #expect(throws: SensitiveInputError.self) { try request.validate(caller: caller, now: now.addingTimeInterval(300)) }
        #expect(throws: SensitiveInputError.self) { try request.validate(caller: caller, now: now.addingTimeInterval(-6)) }
        request.invocationID = UUID()
        #expect(throws: SensitiveInputError.self) { try request.validate(caller: caller, now: now) }
        request.invocationID = invocation
        request.callerTaskID = nil
        #expect(throws: SensitiveInputError.self) { try request.validate(caller: caller, now: now) }
        request.callerTaskID = task
        request.label = "Bad\nlabel"
        #expect(throws: SensitiveInputError.self) { try request.validate(caller: caller, now: now) }
    }
}
