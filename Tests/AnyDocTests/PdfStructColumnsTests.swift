import Testing

@testable import AnyDoc

/// Column inference and the DP alignment, pinned without the oracle.
@Suite struct PdfStructColumnsTests {
    private func infer(_ rows: [[Float?]], fallback: [Float] = [], columns: Int) -> [Float] {
        pdfInferColumnPositions(rowPositions: rows, fallback: fallback, columnCount: columns)
    }

    // MARK: inference

    @Test func theWidestRowSuppliesTheAnchors() {
        // A ragged row cannot define the columns; the row exposing the most
        // positions is the one least likely to be missing any.
        #expect(infer([[100, nil, 300], [100, 200, 300]], columns: 3) == [100, 200, 300])
    }

    @Test func aTieGoesToTheLaterRow() {
        #expect(infer([[100, 200], [150, 250]], columns: 2) == [150, 250])
    }

    @Test func extraAnchorsAreTruncated() {
        #expect(infer([[100, 200, 300, 400]], columns: 2) == [100, 200])
    }

    @Test func missingColumnsAreFilledFromOtherRowsThenTheFallback() {
        // Ascending order, so filling proceeds left to right across the page.
        #expect(infer([[100, nil, nil], [nil, 200, nil]], fallback: [400], columns: 4)
            == [100, 200, 400, 400])
    }

    @Test func positionsWithinTheToleranceDoNotAddAColumn() {
        // Every row is one wide, so the *last* supplies the anchor: 119. Of
        // the remaining positions only 100 is more than 18pt from it, so a
        // second column appears there and the third is padding.
        #expect(infer([[100], [110], [117], [119]], columns: 3) == [100, 119, 119])
    }

    @Test func theLastAnchorIsRepeatedToFill() {
        // Padding lets the caller index by column without bounds-checking, at
        // the cost of several columns claiming the same x.
        #expect(infer([[100, 200]], columns: 5) == [100, 200, 200, 200, 200])
    }

    @Test func theFallbackFillsBeforeTheEmptinessCheck() {
        // The fallback is consulted *before* the "no anchors at all" exit, so
        // a single fallback position becomes an anchor and is then padded out
        // like any other — it does not short-circuit.
        #expect(infer([], fallback: [100, 200, 300], columns: 3) == [100, 200, 300])
        #expect(infer([], fallback: [100], columns: 4) == [100, 100, 100, 100])
        #expect(infer([], fallback: [], columns: 3).isEmpty)
    }

    @Test func askingForNoColumnsReturnsTheFallbackUntouched() {
        // The only way to reach the early return with a non-empty fallback:
        // the fill loop breaks immediately, so nothing is ever taken from it.
        #expect(infer([], fallback: [100, 200, 300], columns: 0) == [100, 200, 300])
    }

    // MARK: alignment

    private func align(_ cells: [Float], _ columns: [Float]) -> [Int] {
        pdfAlignPositionsToColumns(cellXs: cells, columns: columns)
    }

    @Test func enoughCellsMakeTheAlignmentTheIdentity() {
        #expect(align([100, 200, 300], [100, 200]) == [0, 1])
        #expect(align([100, 200], [100, 200]) == [0, 1])
    }

    @Test func aShortRowIsPlacedUnderTheColumnsItMatches() {
        // This is the point of the whole function: two cells against four
        // columns land under the headings they belong to, not packed left.
        #expect(align([100, 300], [100, 200, 300, 400]) == [0, 2])
        #expect(align([210, 310], [100, 200, 300, 400]) == [1, 2])
        #expect(align([405], [100, 200, 300, 400]) == [3])
    }

    @Test func equidistantCellsBiasRight() {
        // Ties take the column rather than skipping it — and the tie is
        // resolved at the *larger* column index, because the table is filled
        // left to right and the last equal cost wins. A cell exactly between
        // two columns therefore lands in the right-hand one.
        #expect(align([150], [100, 200]) == [1])
        // Off-centre either way behaves as expected.
        #expect(align([149], [100, 200]) == [0])
        #expect(align([151], [100, 200]) == [1])
    }

    @Test func emptyInputsGiveAnEmptyAlignment() {
        #expect(align([], [100, 200]).isEmpty)
        #expect(align([100], []).isEmpty)
    }

    @Test func alignmentPreservesCellOrder() {
        let result = align([120, 260, 380], [100, 200, 300, 400, 500])
        #expect(result == result.sorted())
        #expect(result.count == 3)
    }
}
