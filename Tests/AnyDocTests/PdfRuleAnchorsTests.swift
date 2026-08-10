import Testing

@testable import AnyDoc

/// The anchor primitives, pinned without the oracle.
@Suite struct PdfRuleAnchorsTests {
    private func item(_ text: String, _ x: Float, _ y: Float, width: Float = 40)
        -> PdfLayoutItem
    {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: 10, fontName: "F1")
    }

    private func entries(_ items: [PdfLayoutItem]) -> [(index: Int, item: PdfLayoutItem)] {
        items.enumerated().map { (index: $0.offset, item: $0.element) }
    }

    private let band = [
        PdfHorizontalRule(y: 700, xMin: 100, xMax: 400),
        PdfHorizontalRule(y: 600, xMin: 100, xMax: 400),
    ]

    // MARK: gathering rows

    @Test func textInsideTheBandIsGroupedIntoRows() {
        let items = [
            item("a", 100, 680), item("b", 200, 680),
            item("c", 100, 650), item("d", 200, 650),
        ]
        let rows = pdfCollectAnchoredRows(items: items, rules: band)
        #expect(rows.count == 2)
        #expect(rows.first?.y == 680)
        #expect(rows.first?.items.map(\.item.text) == ["a", "b"])
        #expect(rows.last?.items.map(\.item.text) == ["c", "d"])
    }

    @Test func rowsAreOrderedDownThePageAndLeftToRight() {
        let items = [item("right", 300, 650), item("low", 200, 620), item("left", 100, 650)]
        let rows = pdfCollectAnchoredRows(items: items, rules: band)
        #expect(rows.map(\.y) == [650, 620])
        #expect(rows.first?.items.map(\.item.text) == ["left", "right"])
    }

    @Test func driftingBaselinesDoNotChainIntoOneRow() {
        // Each item is compared against the row's *first* baseline, not its
        // last, so five lines drifting 2pt at a time against a 2.5pt
        // tolerance make three rows rather than one. Comparing against the
        // last would swallow a whole slanted column.
        let items = (0..<5).map { item("t\($0)", 100 + Float($0) * 60, 690 - Float($0) * 2) }
        let rows = pdfCollectAnchoredRows(items: items, rules: band)
        #expect(rows.count == 3)
        #expect(rows.map(\.y) == [690, 686, 682])
    }

    @Test func blankItemsAreDroppedBeforeRowsForm() {
        let items = [item("  ", 100, 680), item("real", 200, 680)]
        let rows = pdfCollectAnchoredRows(items: items, rules: band)
        #expect(rows.first?.items.count == 1)
        #expect(rows.first?.items.first?.index == 1)
    }

    @Test func textOutsideTheBandIsExcluded() {
        // The x bound is loosened by the join gap, so 95 is in and 90 is out.
        let items = [
            item("in", 95, 680, width: 10), item("out", 60, 680, width: 10),
            item("below", 200, 560),
        ]
        let rows = pdfCollectAnchoredRows(items: items, rules: band)
        #expect(rows.count == 1)
        #expect(rows.first?.items.map(\.item.text) == ["in"])
    }

    @Test func noRulesSelectsNothing() {
        // With no rules the folded bounds come out inverted — bottom at +∞,
        // top at -∞ — so no item can satisfy both and the band is empty.
        let items = [item("a", 100, 680), item("b", 200, 650)]
        #expect(pdfCollectAnchoredRows(items: items, rules: []).isEmpty)
    }

    // MARK: anchors

    @Test func touchingSpansShareOneAnchor() {
        // A 4pt gap is under the 6pt join, so "Net" and "revenue" are one
        // logical cell; the 60pt gap after them opens a second.
        let items = [
            item("Net", 100, 680, width: 30), item("revenue", 134, 680, width: 40),
            item("12.5", 250, 680, width: 30),
        ]
        #expect(pdfLogicalRowAnchors(entries(items)) == [100, 250])
    }

    @Test func aGapWiderThanTheJoinOpensAnAnchor() {
        let items = [item("a", 100, 680, width: 30), item("b", 137, 680, width: 30)]
        #expect(pdfLogicalRowAnchors(entries(items)) == [100, 137])
    }

    @Test func negativeWidthsAreClampedBeforeSweeping() {
        // A reversed span reaches no further than its own start, so the next
        // item 10pt along is past the 6pt join and opens its own anchor —
        // where an unclamped -40 would have made the sweep run backwards.
        let items = [item("neg", 100, 680, width: -40), item("next", 110, 680, width: 20)]
        #expect(pdfLogicalRowAnchors(entries(items)) == [100, 110])
        // Within the join gap it still merges.
        let close = [item("neg", 100, 680, width: -40), item("next", 105, 680, width: 20)]
        #expect(pdfLogicalRowAnchors(entries(close)) == [100])
    }

    @Test func itemsGoToTheNearestAnchorByStart() {
        let anchors: [Float] = [100, 300]
        #expect(pdfNearestAnchorColumn(item("x", 140, 680), anchors: anchors) == 0)
        #expect(pdfNearestAnchorColumn(item("x", 260, 680), anchors: anchors) == 1)
        // Exactly between: the first of equal distances wins.
        #expect(pdfNearestAnchorColumn(item("x", 200, 680), anchors: anchors) == 0)
        #expect(pdfNearestAnchorColumn(item("x", 200, 680), anchors: []) == nil)
    }

    @Test func matchedColumnsCountDistinctAnchorsOnly() {
        let anchors: [Float] = [100, 300, 500]
        let items = [item("a", 100, 680), item("b", 110, 680), item("c", 500, 680)]
        // Two items land on the first anchor; the count is two, not three.
        #expect(pdfMatchedAnchorColumnCount(entries(items), anchors: anchors) == 2)
    }

    // MARK: combining

    @Test func secondaryTablesClaimingNoItemsAreKept() {
        let primary = PdfTable(columns: [1], rows: [700], cells: [["a"]], itemIndices: [0, 1])
        let fresh = PdfTable(columns: [1], rows: [500], cells: [["b"]], itemIndices: [2, 3])
        let overlapping = PdfTable(columns: [1], rows: [600], cells: [["c"]], itemIndices: [1, 9])
        let combined = pdfCombineNonOverlappingTables([primary], [fresh, overlapping])
        #expect(combined.count == 2)
        #expect(combined.map(\.rows.first) == [700, 500])
    }

    @Test func combinedTablesAreOrderedDownThePage() {
        let low = PdfTable(columns: [1], rows: [200], cells: [["low"]], itemIndices: [0])
        let high = PdfTable(columns: [1], rows: [700], cells: [["high"]], itemIndices: [1])
        #expect(
            pdfCombineNonOverlappingTables([low], [high]).map(\.cells.first?.first)
                == ["high", "low"])
    }

    @Test func aRowlessTableSortsAsThoughItStartedAtZero() {
        let empty = PdfTable(columns: [], rows: [], cells: [], itemIndices: [5])
        let real = PdfTable(columns: [1], rows: [100], cells: [["x"]], itemIndices: [0])
        #expect(
            pdfCombineNonOverlappingTables([empty], [real]).map(\.rows.first) == [100, nil])
    }
}
