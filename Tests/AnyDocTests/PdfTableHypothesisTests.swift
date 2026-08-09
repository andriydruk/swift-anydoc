import Testing

@testable import AnyDoc

/// Scoring and choosing between competing table readings.
@Suite struct PdfTableHypothesisTests {
    private func table(_ cells: [[String]], items: [Int], y: Float = 700) -> PdfTable {
        PdfTable(
            columns: [Float](repeating: 0, count: cells.first?.count ?? 0),
            rows: [Float](repeating: y, count: max(cells.count, 1)),
            cells: cells, itemIndices: items)
    }

    /// Items consumed dominate the score — a reading that explains more of
    /// the page wins whatever produced it.
    @Test func explainingMoreItemsScoresHigher() {
        let small = table([["a", "b"], ["c", "d"]], items: [1, 2, 3])
        let large = table([["a", "b", "c"], ["d", "e", "f"]], items: [1, 2, 3, 4, 5])
        #expect(pdfTableEvidenceScore(large) > pdfTableEvidenceScore(small))
    }

    /// Empty cells are a small penalty: enough to prefer a tight grid over a
    /// sparse one covering the same items.
    @Test func sparseGridsScoreBelowTightOnes() {
        let sparse = table([["a", "", "", ""], ["", "", "", "b"]], items: [1, 2])
        let tight = table([["a", "b"]], items: [1, 2])
        #expect(pdfTableEvidenceScore(tight) > pdfTableEvidenceScore(sparse))
    }

    /// The score never goes negative, so a mostly-empty grid still sorts
    /// above a reading that found nothing.
    @Test func theScoreSaturatesAtZero() {
        let empty = table(Array(repeating: [String](repeating: "", count: 8), count: 8), items: [])
        #expect(pdfTableEvidenceScore(empty) >= 0)
    }

    /// Selection is greedy by evidence: the best wins, then the best of what
    /// does not overlap it.
    @Test func selectionIsGreedyAndNonOverlapping() {
        let weak = table([["a", "b"], ["c", "d"]], items: [1, 2, 3])
        let strong = table([["a", "b", "c"], ["d", "e", "f"]], items: [1, 2, 3, 4, 5])
        let elsewhere = table([["x", "y"], ["z", "w"]], items: [9, 10], y: 500)

        let selected = pdfSelectNonOverlappingHypotheses([weak, strong, elsewhere])
        #expect(selected.count == 2)
        #expect(selected.map(\.itemIndices) == [[1, 2, 3, 4, 5], [9, 10]])
    }

    /// Survivors come back down the page, which is reading order.
    @Test func survivorsAreOrderedDownThePage() {
        let lower = table([["a"]], items: [1], y: 300)
        let upper = table([["b"]], items: [2], y: 700)
        #expect(pdfSelectNonOverlappingHypotheses([lower, upper]).map(\.rows.first) == [700, 300])
    }

    /// With no alternatives the legacy reading passes through untouched —
    /// including any overlaps it already had.
    @Test func noAlternativesLeavesLegacyAlone() {
        let a = table([["a"]], items: [1, 2])
        let b = table([["b"]], items: [2, 3])
        let result = pdfSelectTableHypothesis(legacy: [a, b], alternatives: [])
        #expect(result.count == 2)
    }

    /// With both present neither is privileged: they are pooled and scored
    /// together, so a better alternative displaces the grid reading.
    @Test func neitherSideIsPrivileged() {
        let legacy = table([["a", "b"], ["c", "d"]], items: [1, 2, 3])
        let better = table([["a", "b", "c"], ["d", "e", "f"]], items: [1, 2, 3, 4, 5])
        let result = pdfSelectTableHypothesis(legacy: [legacy], alternatives: [better])
        #expect(result.map(\.itemIndices) == [[1, 2, 3, 4, 5]])
    }

    @Test func overlapIsDetectedAcrossTables() {
        let a = table([["a"]], items: [1, 2])
        let b = table([["b"]], items: [7, 8])
        let straddling = table([["x", "y"]], items: [2, 7])
        #expect(pdfTablesShareItems(a, straddling))
        #expect(pdfOverlapsMultipleTables(straddling, [a, b]))
        #expect(!pdfOverlapsMultipleTables(a, [a]))
    }
}
