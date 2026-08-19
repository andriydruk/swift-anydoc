// Right-to-left lines are ordered before the merge, not after.
//
// `pdfSortLineItems` already ordered a *line's* items by direction, and that
// was not enough: `pdfMergeTextItems` runs first and concatenates a line's
// runs into one item. Merged left-to-right, an Arabic line drawn as two `Tj`
// operators comes out with its halves swapped, and no later sort can undo it
// because the seam is gone.
import Testing

@testable import AnyDoc

@Suite struct PdfRtlMergeTests {
    private func item(_ text: String, x: Float) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: 700, width: Float(text.count) * 10, fontSize: 12,
                      fontName: "F1")
    }

    /// Whether the runs also fuse into one item depends on the gap, and is
    /// not what is under test — the **order** is, because that is what the
    /// merge fixes and no later pass can.
    private func order(_ items: [PdfLayoutItem]) -> String {
        pdfMergeTextItems(items).map(\.text).joined()
    }

    /// Two Arabic runs on one line are taken from the right.
    @Test func rightToLeftRunsAreOrderedFromTheHighestX() {
        #expect(
            order([item("\u{0633}\u{0627}\u{0644}", x: 72), item("\u{0644}\u{0628}", x: 126)])
                == "\u{0644}\u{0628}\u{0633}\u{0627}\u{0644}")
    }

    /// Latin runs are unaffected, which is the half that must not change.
    @Test func leftToRightRunsAreOrderedFromTheLowestX() {
        #expect(order([item("Hello", x: 72), item("World", x: 126)]) == "Hello World")
        // And the input order does not matter — position decides.
        #expect(order([item("World", x: 126), item("Hello", x: 72)]) == "Hello World")
    }

    /// The direction is decided by counting the whole line, so a Latin word
    /// inside Arabic does not flip it back.
    @Test func aLatinWordInsideArabicDoesNotFlipTheLine() {
        #expect(
            order([
                item("\u{0644}\u{0628}", x: 72), item("AB", x: 110),
                item("\u{0633}\u{0627}", x: 150),
            ]) == "\u{0633}\u{0627}AB\u{0644}\u{0628}")
    }
}
