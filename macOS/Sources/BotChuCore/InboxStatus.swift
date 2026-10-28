import Foundation

/// The Inbox's counts and unresolved questions, derived together when its deliveries or state
/// change. This includes every delivery, independent of which ones the Inbox list shows.
public struct InboxStatus: Equatable, Sendable {
    public struct Pending: Equatable, Sendable {
        public let id: UUID
        public let updatedAt: Date
    }

    public let unreadCount: Int
    public let unfinishedCount: Int
    /// The same ordering and eligibility as `InboxState.awaitingInput`, including UUID tie breaks.
    public let awaitingInput: [Delivery.Origin: [Pending]]

    public init(deliveries: [Delivery] = [], state: InboxState = InboxState()) {
        unreadCount = state.unreadCount(deliveries)
        unfinishedCount = state.unfinishedCount(deliveries)
        let dates = Dictionary(uniqueKeysWithValues: deliveries.map { ($0.id, $0.updatedAt) })
        awaitingInput = state.awaitingInput(deliveries).mapValues { ids in
            ids.map { Pending(id: $0, updatedAt: dates[$0]!) }
        }
    }
}
