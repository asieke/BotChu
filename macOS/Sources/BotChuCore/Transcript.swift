import Foundation

/// What reading a conversation's JSON Lines file found (a Home's or task's `thread.jsonl`, a
/// sub-agent's, `queued.jsonl` or `taken.jsonl`), so nothing in it is lost when it is next saved.
/// A missing or empty file is an empty conversation. A line that isn't JSON, or is JSON but not a
/// message this version knows (such as one with a role it doesn't have), is left out, and a file
/// that can't be read at all reads as empty; either way the original is kept first, byte for
/// byte, beside it as `<name>.unreadable-<time>.<extension>`, before anything rewrites the file,
/// and `note(for:)` tells the conversation what was left out and where the original is.
public struct TranscriptRead: Equatable, Sendable {
    public enum Kind: Sendable {
        case conversation
        /// Unsent follow-ups (`queued.jsonl`).
        case queue
        /// Follow-ups the CLI took before a saved transcript held them (`taken.jsonl`).
        case taken
    }

    /// The messages that could be read, in order.
    public var messages: [ChatMessage] = []
    /// Lines that aren't JSON.
    public var malformed = 0
    /// Lines that are JSON but not a message this version knows.
    public var unsupported = 0
    /// Why the file couldn't be read at all, when it couldn't.
    public var failure: String?
    /// Where the original file is kept, when something in it couldn't be read.
    public var kept: URL?
    /// Why the original couldn't be kept, when it couldn't.
    public var keepFailure: String?

    public init() {}

    public var isDamaged: Bool { malformed + unsupported > 0 || failure != nil }

    /// Reads `url`, keeping its original first when anything in it can't be read.
    public static func read(_ url: URL, now: Date = Date()) -> TranscriptRead {
        var read = TranscriptRead()
        guard FileManager.default.fileExists(atPath: url.path) else { return read }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            read.failure = error.localizedDescription
            read.keep(url, now: now)
            return read
        }
        let blank: Set<UInt8> = [0x20, 0x09, 0x0D]
        for line in data.split(separator: 0x0A) where !line.allSatisfy(blank.contains) {
            let line = Data(line)
            if let message = try? Store.decoder.decode(ChatMessage.self, from: line) {
                read.messages.append(message)
            } else if (try? JSONSerialization.jsonObject(with: line, options: .fragmentsAllowed)) != nil {
                read.unsupported += 1
            } else {
                read.malformed += 1
            }
        }
        if read.isDamaged { read.keep(url, now: now) }
        return read
    }

    /// A line from BotChu for the conversation, saying what couldn't be read and where the
    /// original is kept; nil when everything was read.
    public func note(for kind: Kind, date: Date = Date()) -> ChatMessage? {
        guard isDamaged else { return nil }
        var text: String
        if let failure {
            text = switch kind {
            case .conversation: "This conversation's file couldn't be read (\(failure)), so it starts again here."
            case .queue: "The file of pending messages couldn't be read (\(failure)), so none of them will be sent."
            case .taken: "The file of messages the bot took before BotChu could save the conversation couldn't be read (\(failure)), so they aren't shown."
            }
        } else {
            let count = malformed + unsupported
            let what = switch kind {
            case .conversation: count == 1 ? "1 entry in this conversation" : "\(count) entries in this conversation"
            case .queue: count == 1 ? "1 pending message" : "\(count) pending messages"
            case .taken: count == 1 ? "1 message the bot took" : "\(count) messages the bot took"
            }
            let why = [malformed > 0 ? "\(malformed) not valid JSON" : nil,
                       unsupported > 0 ? "\(unsupported) of a kind this version of BotChu doesn't know" : nil]
            text = "\(what) couldn't be read (\(why.compactMap { $0 }.joined(separator: ", "))), so "
                + (count == 1 ? "it isn't" : "they aren't") + (kind == .queue ? " sent." : " shown.")
        }
        if let kept {
            text += " The original file is kept, unchanged, at \((kept.path as NSString).abbreviatingWithTildeInPath)."
        } else if let keepFailure {
            text += " BotChu couldn't keep a copy of the original file (\(keepFailure))."
        }
        return ChatMessage(role: .note, text: text, date: date)
    }

    /// Keeps the original beside it: a copy (a clone, on APFS), or the file itself, moved, when it
    /// can't be read or copied. When neither works, the file or its folder can't be changed, so
    /// the save that would replace it can't either.
    private mutating func keep(_ url: URL, now: Date) {
        let files = FileManager.default
        let stem = "\(url.deletingPathExtension().lastPathComponent).unreadable-\(Self.stamp.string(from: now))"
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        var target = url.deletingLastPathComponent().appendingPathComponent(stem + suffix)
        var number = 1
        while files.fileExists(atPath: target.path) {
            number += 1
            target = url.deletingLastPathComponent().appendingPathComponent("\(stem)-\(number)\(suffix)")
        }
        do {
            if failure == nil {
                do { try files.copyItem(at: url, to: target) } catch { try files.moveItem(at: url, to: target) }
            } else {
                try files.moveItem(at: url, to: target)
            }
            kept = target
        } catch {
            keepFailure = error.localizedDescription
        }
    }

    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
