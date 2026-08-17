import Testing

@testable import AnyDoc

/// The line assembler's geometry, now delegated.
///
/// `pdfNeedsSpace` used to inline a copy of `pdfShouldJoinItems` — the port
/// of the function the reference's own assembler calls. Wave 127's orphan
/// sweep found the copy; wave 129 removed it, and these tests are what made
/// that safe to do.
///
/// They were written against the two implementations to establish that they
/// agreed, and they now pin the delegation instead: the same five cases, plus
/// the one place `pdfNeedsSpace` still decides for itself. Keeping them is
/// the point — a future edit that re-inlines the geometry, or drops the width
/// guard, fails here rather than silently on some page nobody has.
///
/// **The copy had gone stale**, which is why this mattered beyond tidiness:
/// it hardcoded the 0.10 word-gap bar and so had no letter-spaced branch at
/// all, where `pdfShouldJoinItems` compares against character width.
@Suite struct PdfJoinDuplicationTests {
    private func item(_ text: String, x: Float, width: Float, size: Float = 10)
        -> PdfLayoutItem
    {
        PdfLayoutItem(text: text, x: x, y: 700, width: width, fontSize: size, fontName: "F1")
    }

    /// `pdfNeedsSpace` asks whether a space belongs; `pdfShouldJoinItems`
    /// asks whether the two are one word. Past the textual rules they are
    /// exact opposites, which is what delegation means here.
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

    /// The one decision `pdfNeedsSpace` still makes alone: with no measured
    /// width there is no gap to reason about, so it joins, while
    /// `pdfShouldJoinItems` would reach a conclusion from the text. The guard
    /// is kept deliberately and this test is what says so.
    @Test func theyDivergeWhenTheWidthIsUnmeasured() {
        let previous = item("word", x: 72, width: 0)
        let current = item("next", x: 200, width: 24)
        #expect(!pdfNeedsSpace(previous, current, "prev"))
        #expect(!agree(previous, current))
    }
}
