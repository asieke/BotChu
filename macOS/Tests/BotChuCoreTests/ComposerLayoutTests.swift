import Foundation
import Testing
@testable import BotChuCore

/// #80: the message box grows with its text, then scrolls, and its first line stays in view.
@Suite struct ComposerLayoutTests {
    /// The message box: 42 to 200 points, its text 4 points from its top and bottom; a line of the
    /// system font is 16 points.
    let box = ComposerLayout(minHeight: 42, maxHeight: 200)

    private func lines(_ count: Int) -> Double { Double(count) * 16 }

    @Test func growsWithItsTextFromItsMinimumToItsMaximum() {
        #expect(box.height(forText: lines(1)) == 42)
        #expect(box.height(forText: lines(2)) == 42)
        #expect(box.height(forText: lines(3)) == 56)
        #expect(box.height(forText: lines(12)) == 200)
        #expect(box.height(forText: lines(13)) == 200)
        #expect(box.height(forText: lines(40)) == 200)
        // Rounded up to a whole point, so the last line isn't cut by a fraction.
        #expect(box.contentHeight(forText: 47.2) == 56)
        #expect(box.height(forText: 47.2) == 56)
        // A sheet's taller box, and a maximum below the minimum, which is the minimum.
        #expect(ComposerLayout(minHeight: 90, maxHeight: 220).height(forText: lines(1)) == 90)
        #expect(ComposerLayout(minHeight: 90, maxHeight: 60).height(forText: lines(10)) == 90)
    }

    @Test func scrollsOnlyOnceItsTextIsTallerThanItCanGrow() {
        #expect(!box.scrolls(documentHeight: 42))
        #expect(!box.scrolls(documentHeight: 200))
        #expect(box.scrolls(documentHeight: 216))
    }

    /// Shift-Return on the second line: the text view is three lines tall at once, the box only after
    /// SwiftUI lays it out again. AppKit scrolled the new line into view meanwhile, by 14 points, and
    /// the first line's top went out of sight (the issue's screenshot).
    @Test func aNewLineDoesNotScrollWhileTheBoxCanStillGrow() {
        #expect(box.scrollOffset(14, documentHeight: 56, visibleHeight: 42) == 0)
        #expect(box.scrollOffset(16, documentHeight: 200, visibleHeight: 184) == 0)
        // Wrapping as it is typed, the same.
        #expect(box.scrollOffset(30, documentHeight: 72, visibleHeight: 42) == 0)
    }

    @Test func pastItsMaximumItScrollsToTheCaretAndNoFurther() {
        // The thirteenth line: the box grows to its maximum and its text scrolls by the rest.
        #expect(box.scrollOffset(32, documentHeight: 216, visibleHeight: 184) == 16)
        #expect(box.scrollOffset(16, documentHeight: 216, visibleHeight: 200) == 16)
        #expect(box.scrollOffset(40, documentHeight: 216, visibleHeight: 200) == 16)
        // Back up to the first line, and not above it.
        #expect(box.scrollOffset(0, documentHeight: 216, visibleHeight: 200) == 0)
        #expect(box.scrollOffset(-8, documentHeight: 216, visibleHeight: 200) == 0)
        #expect(box.scrollOffset(5, documentHeight: 216, visibleHeight: 200) == 5)
    }

    /// Deleting back to a shorter draft: a scroll left over from the longer one goes, and the first
    /// line shows again.
    @Test func aShorterDraftShowsItsFirstLineAgain() {
        #expect(box.scrollOffset(16, documentHeight: 200, visibleHeight: 200) == 0)
        #expect(box.scrollOffset(14, documentHeight: 42, visibleHeight: 42) == 0)
        #expect(box.scrollOffset(48, documentHeight: 56, visibleHeight: 200) == 0)
    }
}
