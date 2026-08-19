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
/// the case that once diverged and no longer does. Keeping them is the
/// point — a future edit that re-inlines the geometry fails here rather
/// than silently on some page nobody has.
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

    /// **They agree here too, and this test used to say the opposite.**
    ///
    /// `pdfNeedsSpace` carried a `guard previous.width > 0 else { return
    /// false }` — join, no space, whenever the previous item had no measured
    /// width — described in its own comment as a deliberate difference, and
    /// pinned here as one. It was a bug. The reference's line assembler calls
    /// `should_join_items` unconditionally, and that function has its own
    /// zero-width path: estimate a width from the character count and reason
    /// about the gap as usual. The guard skipped all of it, so these two
    /// items **110 points apart** were joined into one word.
    ///
    /// Wave 166 found it through a bulleted line: a zero-width bullet glued
    /// to its text reads `\u{2022}the quick brown fox`, which is a heading
    /// rather than a list item, because `is_list_item` wants `\u{2022} ` with
    /// the space.
    ///
    /// A test asserting a divergence is only as good as the reason recorded
    /// with it, and this one's reason was wrong.
    @Test func theyAgreeWhenTheWidthIsUnmeasured() {
        let previous = item("word", x: 72, width: 0)
        let current = item("next", x: 200, width: 24)
        #expect(pdfNeedsSpace(previous, current, "prev"))
        #expect(agree(previous, current))
    }

    /// The zero-width case that matters in practice: a bullet, whose glyph
    /// often measures nothing, followed by the text it introduces.
    @Test func aZeroWidthBulletKeepsItsSpace() {
        #expect(
            pdfNeedsSpace(
                item("\u{2022}", x: 72, width: 0, size: 12),
                item("the quick brown fox", x: 86, width: 114, size: 12), "\u{2022}"))
    }
}
