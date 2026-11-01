import Foundation

/// A repository in Attach Project Area (#402): the catalog's entry, the bot whose area it is, and
/// why it can't be chosen now (nil when it can). Read once as the sheet opens (#438).
public struct AttachAreaRow: Identifiable, Hashable, Sendable {
    public var entry: ProjectCatalogEntry
    public var owner: UUID?
    public var problem: String?
    public var id: String { entry.repo }

    public init(entry: ProjectCatalogEntry, owner: UUID?, problem: String?) {
        self.entry = entry
        self.owner = owner
        self.problem = problem
    }

    /// The rows whose name or `owner/name` has every word of the search, in their order.
    public static func filter(_ rows: [AttachAreaRow], query: String) -> [AttachAreaRow] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return rows }
        return rows.filter { row in
            let text = (row.entry.name + " " + row.entry.repo).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
}

/// Attach Project Area's presentation in one window (#438): at most one form prepared ahead,
/// each used for one opening only, and at most one opening shown. Each opening has its own
/// request, so the dismissal of an earlier one can't close a later one.
public struct AttachAreaPresentation: Equatable, Sendable {
    /// The prepared form, not shown yet.
    public private(set) var prepared: UUID?
    /// The opening shown now, and its form.
    public private(set) var shown: (request: UUID, form: UUID)?

    public init() {}

    /// Whether a form should be prepared ahead: none is, and none is shown.
    public var needsPreparation: Bool { prepared == nil && shown == nil }

    /// Keeps `form` as the one the next opening uses.
    public mutating func prepared(_ form: UUID) {
        guard shown == nil else { return }
        prepared = form
    }

    /// Opens with the prepared form, or with `cold` (made now) when none is ready; nil while
    /// another opening is shown. The prepared form is used up either way.
    public mutating func open(cold: @autoclosure () -> UUID) -> (request: UUID, form: UUID, wasPrepared: Bool)? {
        guard shown == nil else { return nil }
        let form = prepared ?? cold()
        let opening = (request: UUID(), form: form, wasPrepared: prepared != nil)
        prepared = nil
        shown = (opening.request, opening.form)
        return opening
    }

    /// Ends the opening `request`; false when it isn't the one shown, as for a second Cancel or
    /// the late dismissal of an earlier opening.
    public mutating func close(_ request: UUID) -> Bool {
        guard shown?.request == request else { return false }
        shown = nil
        return true
    }

    /// Forgets everything, as when its window goes away.
    public mutating func reset() {
        prepared = nil
        shown = nil
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.prepared == b.prepared && a.shown?.request == b.shown?.request && a.shown?.form == b.shown?.form
    }
}
