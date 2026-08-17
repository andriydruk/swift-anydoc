import Testing

@testable import AnyDoc

/// The chooser that decides which of a page's three rectangle lists the
/// detectors actually see, ported from the substitution at the end of the
/// reference's `content_stream.rs`.
///
/// It was wired into the pipeline in wave 116 and its necessity went
/// unproven for two waves: three corpus documents in a row matched the
/// reference whether it ran or not. `path-drawn-table.pdf` finally
/// discriminates, and these pin the branches a single document cannot.
@Suite struct PdfSelectedRectanglesTests {
    private func rect(_ x: Float) -> PdfRect {
        PdfRect(x: x, y: 100, width: 20, height: 10)
    }

    private func graphics(re: Int = 0, filled: Int = 0, clip: Int = 0) -> PdfPageGraphics {
        var built = PdfPageGraphics()
        // Distinct x per rectangle: the clip list is deduplicated before it
        // is counted, so identical ones would collapse and change the branch.
        built.rectangles = (0..<re).map { rect(Float($0) * 30) }
        built.filledRectangles = (0..<filled).map { rect(Float($0) * 30) }
        built.clipRectangles = (0..<clip).map { rect(Float($0) * 30) }
        return built
    }

    @Test func reRectanglesWinOutright() {
        // Even one `re` beats any number of fills or clips: a page that used
        // the operator meant those to be its structure.
        let chosen = pdfSelectedRectangles(graphics(re: 1, filled: 50, clip: 50))
        #expect(chosen.count == 1)
    }

    @Test func fillsWinWhenTheyOutnumberClipsThreeToOne() {
        // Then the clips are section wrappers and the fills are the cells.
        #expect(pdfSelectedRectangles(graphics(filled: 20, clip: 4)).count == 20)
        // Exactly 3× still counts — the comparison is `>=`, not `>`.
        #expect(pdfSelectedRectangles(graphics(filled: 12, clip: 4)).count == 12)
        // And one short of it does not: the clips take it on the next rule.
        #expect(pdfSelectedRectangles(graphics(filled: 11, clip: 4)).count == 4)
    }

    @Test func clipsWinWhenThereAreEnoughOfThem() {
        // Below the 3× ratio, four or more clips are believed over the fills.
        #expect(pdfSelectedRectangles(graphics(filled: 2, clip: 6)).count == 6)
    }

    @Test func tooFewClipsFallBackToTheFills() {
        // Three clips cannot describe a grid, so whatever fills exist are
        // better evidence than they are.
        #expect(pdfSelectedRectangles(graphics(filled: 2, clip: 3)).count == 2)
    }

    @Test func clipsAreTheLastResort() {
        #expect(pdfSelectedRectangles(graphics(clip: 3)).count == 3)
    }

    @Test func aPageWithNoRectanglesAtAllChoosesNothing() {
        #expect(pdfSelectedRectangles(graphics()).isEmpty)
    }

    /// The clip list is deduplicated *before* being counted, which decides
    /// branches: six clips that are really one repeated must not out-vote two
    /// genuine fills.
    @Test func duplicateClipsAreCountedOnce() {
        var built = PdfPageGraphics()
        built.filledRectangles = [rect(0), rect(30)]
        built.clipRectangles = Array(repeating: rect(0), count: 6)
        // After dedup there is one clip, so the fills take it at 2 >= 1 * 3.
        #expect(pdfSelectedRectangles(built).count == 2)
    }
}
