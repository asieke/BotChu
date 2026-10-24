import Foundation

/// An array kept in chunks of 128, for collections that grow at their end while an earlier copy is
/// still in use: changing an element or adding one copies only its chunk and the list of chunks,
/// not every element, as `Array` does once it is shared. A chat's items and an exploration's calls
/// are shared this way with the views that showed them last, so a new call costs the same in a
/// group of 5,000 as in one of 5.
public struct ChunkedArray<Element>: RandomAccessCollection {
    static var shift: Int { 7 }
    static var mask: Int { 127 }

    private var chunks: [[Element]] = []
    public private(set) var count = 0

    public init() {}

    public init<S: Sequence>(_ elements: S) where S.Element == Element {
        for element in elements { append(element) }
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { count }

    public subscript(position: Int) -> Element {
        get {
            precondition(position >= 0 && position < count, "Index out of range")
            return chunks[position >> Self.shift][position & Self.mask]
        }
        set {
            precondition(position >= 0 && position < count, "Index out of range")
            chunks[position >> Self.shift][position & Self.mask] = newValue
        }
    }

    public mutating func append(_ element: Element) {
        if count & Self.mask == 0 {
            chunks.append([element])
        } else {
            chunks[chunks.count - 1].append(element)
        }
        count += 1
    }

    @discardableResult
    public mutating func removeLast() -> Element {
        precondition(count > 0, "Can't remove the last element of an empty collection")
        count -= 1
        let element = chunks[chunks.count - 1].removeLast()
        if chunks[chunks.count - 1].isEmpty { chunks.removeLast() }
        return element
    }

    /// Keeps the first `count` elements.
    public mutating func removeSuffix(from index: Int) {
        precondition(index >= 0 && index <= count, "Index out of range")
        guard index < count else { return }
        let whole = (index + Self.mask) >> Self.shift
        chunks.removeSubrange(whole...)
        if index & Self.mask != 0 { chunks[chunks.count - 1].removeSubrange((index & Self.mask)...) }
        count = index
    }

    public mutating func removeAll() {
        chunks = []
        count = 0
    }
}

extension ChunkedArray: Equatable where Element: Equatable {
    public static func == (a: Self, b: Self) -> Bool { a.chunks == b.chunks }
}

extension ChunkedArray: Sendable where Element: Sendable {}

extension ChunkedArray: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Element...) { self.init(elements) }
}
