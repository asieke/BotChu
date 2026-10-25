import Testing
@testable import BotChuCore

/// When a chat keeps its reader at the newest content (#131): only the reader's own scrolling
/// unpins it; sending, opening and Jump to Latest pin it wherever they were.
struct ChatPinTests {
    @Test func aChatStartsPinnedAndStaysAtItsEndAsContentChanges() {
        let pin = ChatPin()
        #expect(pin.isPinned)
        // Content grew, the window resized, or the scroll view settled short of the end.
        #expect(pin.keepsEnd(below: 125, readerScrolling: false))
        #expect(pin.keepsEnd(below: 1, readerScrolling: false))
        // Already there.
        #expect(!pin.keepsEnd(below: 0.2, readerScrolling: false))
        #expect(!pin.keepsEnd(below: -30, readerScrolling: false))
        // Never against the reader's hand.
        #expect(!pin.keepsEnd(below: 125, readerScrolling: true))
    }

    @Test func scrollingTowardTheTopUnpinsAndNothingElseMovesTheReader() {
        var pin = ChatPin()
        pin.apply(.scrolled(delta: -10, below: 10))
        #expect(!pin.isPinned)
        #expect(!pin.keepsEnd(below: 400, readerScrolling: false))
        // Further up, and back down short of the end: still reading.
        pin.apply(.scrolled(delta: -800, below: 810))
        pin.apply(.scrolled(delta: 300, below: 510))
        #expect(!pin.isPinned)
        // A move that isn't a scroll changes nothing.
        pin.apply(.scrolled(delta: 0, below: 0))
        #expect(!pin.isPinned)
    }

    @Test func aBounceOrANudgeAtTheEndKeepsItPinned() {
        var pin = ChatPin()
        // Scrolled past the end, the scroll view springs back toward the top, to the end.
        pin.apply(.scrolled(delta: 30, below: -30))
        pin.apply(.scrolled(delta: -30, below: 0))
        #expect(pin.isPinned)
        pin.apply(.scrolled(delta: -ChatPin.slack, below: ChatPin.slack))
        #expect(pin.isPinned)
        pin.apply(.scrolled(delta: -3, below: ChatPin.slack + 1))
        #expect(!pin.isPinned)
    }

    @Test func scrollingBackToTheEndPinsAgain() {
        var pin = ChatPin(isPinned: false)
        pin.apply(.scrolled(delta: 200, below: ChatPin.nearEnd + 1))
        #expect(!pin.isPinned)
        pin.apply(.scrolled(delta: 20, below: ChatPin.nearEnd))
        #expect(pin.isPinned)
        // Near the end, but on the way up: still unpinned once it left.
        pin.apply(.scrolled(delta: -20, below: 30))
        #expect(!pin.isPinned)
        pin.apply(.scrolled(delta: -5, below: 35))
        #expect(!pin.isPinned)
        pin.apply(.scrolled(delta: 35, below: 0))
        #expect(pin.isPinned)
    }

    @Test func sendingOpeningAndJumpingPinWhereverTheReaderWas() {
        for event in [ChatPin.Event.sent, .opened, .jumped] {
            var pin = ChatPin()
            pin.apply(.scrolled(delta: -2_000, below: 2_000))
            var toEnd = pin.apply(event)
            #expect(toEnd)
            #expect(pin.isPinned)
            #expect(pin.keepsEnd(below: 2_000, readerScrolling: false))
            // Pinned already, it still goes to the end: the reader may have stopped short of it.
            toEnd = pin.apply(event)
            #expect(toEnd)
        }
    }

    @Test func aCardOpenedByAClickUnpinsSoItGrowsWhereItWasClicked() {
        var pin = ChatPin()
        let toEnd = pin.apply(.openedCard)
        #expect(!toEnd)
        #expect(!pin.isPinned)
        #expect(!pin.keepsEnd(below: 300, readerScrolling: false))
    }
}
