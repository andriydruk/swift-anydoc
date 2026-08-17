import Testing

@testable import AnyDoc

/// Two implementations of one decision, compared.
///
/// `pdfShouldJoinItems` is the port of `should_join_items`, which the
/// reference calls from its line assembler. This port's line assembler,
/// `pdfNeedsSpace`, instead **reimplements the geometry inline** — the same
/// gap thresholds, the same digit rule, the same single-character rule.
/// Wave 127 found the duplication by the orphan sweep: `pdfShouldJoinItems`
/// has had no caller since it was ported.
///
/// Switching `pdfNeedsSpace` to call it would need a letter-spacing
/// threshold threaded through the line assembler, which does not currently
/// take one. That is a wave of its own. What these tests do is establish
/// whether the two **agree**, so that switch is a refactor rather than a
/// behaviour change — and they find one case where it would not be.
@Suite struct PdfJoinDuplicationTests {
    private func item(_ text: String, x: Float, width: Float, size: Float = 10)
        -> PdfLayoutItem
    {
        PdfLayoutItem(text: text, x: x, y: 700, width: width, fontSize: size, fontName: "F1")
    }

    /// `pdfNeedsSpace` asks whether a space belongs; `pdfShouldJoinItems`
    /// asks whether the two are one word. On plain text they should be
    /// exact opposites.
    private func agree(_ previous: PdfLayoutItem, _ current: PdfLayoutItem) -> Bool {
        pdfNeedsSpace(previous, current, "prev")
            == !pdfShouldJoinItems(
                previous: previous, current: current, singleCharacterThreshold: 0.10)
    }

    @Test func theyAgreeOnAnObviousWordGap() {
        // A full space at 10pt: both should call it a word boundary.
        #expect(agree(item("word", x: 72, width: 24), item("next", x: 101, width: 24)))
    }

    @Test func theyAgreeOnGlyphsInsideAWord() {
        // Touching runs: both should join.
        #expect(agree(item("wo", x: 72, width: 12), item("rd", x: 84, width: 12)))
    }

    @Test func theyAgreeOnAColumnScaleGap() {
        #expect(agree(item("left", x: 72, width: 24), item("right", x: 320, width: 30)))
    }

    @Test func theyAgreeOnDigitsSharingANumber() {
        #expect(agree(item("1", x: 72, width: 6), item("234", x: 78.5, width: 18)))
    }

    @Test func theyAgreeOnASplitWordFragment() {
        // "b" + "illion": a single character beside a longer run.
        #expect(agree(item("b", x: 72, width: 6), item("illion", x: 78.4, width: 30)))
    }

    /// The one divergence, and it is `pdfNeedsSpace`'s own rule rather than
    /// a porting error: it returns `false` — join — when the previous run
    /// has no measured width, because there is no gap to reason about.
    /// `pdfShouldJoinItems` reaches its own conclusion from the text.
    /// Recorded so the future switch is made knowingly.
    @Test func theyDivergeWhenTheWidthIsUnmeasured() {
        let previous = item("word", x: 72, width: 0)
        let current = item("next", x: 200, width: 24)
        #expect(!pdfNeedsSpace(previous, current, "prev"))
        #expect(!agree(previous, current))
    }
}
