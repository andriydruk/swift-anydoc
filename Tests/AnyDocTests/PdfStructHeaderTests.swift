import Testing

@testable import AnyDoc

/// Unclaimed-header recovery, pinned without the oracle.
@Suite struct PdfStructHeaderTests {
    private func item(_ text: String, _ x: Float, _ y: Float) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: 20, fontSize: 10, fontName: "F1")
    }

    /// A three-column table whose two body rows are already claimed.
    private func table(columns: Int = 3) -> PdfTable {
        PdfTable(
            columns: (0..<columns).map { 100 + Float($0) * 100 },
            rows: [700, 680],
            cells: [
                (0..<columns).map { _ in "x" }, (0..<columns).map { _ in "y" },
            ],
            itemIndices: Array(0..<(columns * 2)))
    }

    private func bodyItems(columns: Int = 3) -> [PdfLayoutItem] {
        (0..<columns).map { item("x", 100 + Float($0) * 100, 700) }
            + (0..<columns).map { item("y", 100 + Float($0) * 100, 680) }
    }

    private func headerLine(_ y: Float, columns: Int = 3, prefix: String = "H")
        -> [PdfLayoutItem]
    {
        (0..<columns).map { item("\(prefix)\($0)", 100 + Float($0) * 100, y) }
    }

    private func recover(
        _ items: [PdfLayoutItem], columns: Int = 3, ragged: Bool = true
    ) -> PdfTable {
        var result = table(columns: columns)
        pdfRecoverUnclaimedHeaderRow(&result, items: items, hasRaggedRows: ragged)
        return result
    }

    @Test func aHeaderAboveARaggedTableIsRecovered() {
        let result = recover(bodyItems() + headerLine(715))
        #expect(result.cells.count == 3)
        #expect(result.cells.first == ["H0", "H1", "H2"])
        #expect(result.rows.first == 715)
    }

    @Test func aCleanTableIsLeftAlone() {
        // Text above a well-formed table is a caption, not a header, and
        // stealing it would be worse than leaving the header absent.
        #expect(recover(bodyItems() + headerLine(715), ragged: false).cells.count == 2)
    }

    @Test func aTableWithFewerThanThreeColumnsIsNotEligible() {
        var narrow = PdfTable(
            columns: [100, 200], rows: [700, 680], cells: [["a", "b"], ["c", "d"]],
            itemIndices: [0, 1, 2, 3])
        pdfRecoverUnclaimedHeaderRow(
            &narrow,
            items: [
                item("a", 100, 700), item("b", 200, 700), item("c", 100, 680),
                item("d", 200, 680), item("H0", 100, 715), item("H1", 200, 715),
            ], hasRaggedRows: true)
        #expect(narrow.cells.count == 2)
    }

    @Test func textTooFarAboveTheTableIsNotAHeader() {
        // The nearest line must be within 35pt to count as attached.
        #expect(recover(bodyItems() + headerLine(734)).cells.count == 3)
        #expect(recover(bodyItems() + headerLine(736)).cells.count == 2)
    }

    @Test func twoHeaderLinesAreJoinedTopDown() {
        // The lines are gathered upwards from the table, then reversed, so a
        // two-line header reads in the right order.
        let result = recover(bodyItems() + headerLine(715) + headerLine(730, prefix: "T"))
        #expect(result.cells.first == ["T0 H0", "T1 H1", "T2 H2"])
        // The inserted row takes the topmost line's baseline.
        #expect(result.rows.first == 730)
    }

    @Test func linesTooFarApartDoNotJoin() {
        // 25pt is the most two header lines may be apart.
        #expect(
            recover(bodyItems() + headerLine(715) + headerLine(739, prefix: "T"))
                .cells.first == ["T0 H0", "T1 H1", "T2 H2"])
        #expect(
            recover(bodyItems() + headerLine(715) + headerLine(741, prefix: "T"))
                .cells.first == ["H0", "H1", "H2"])
    }

    @Test func atMostThreeLinesAreTaken() {
        let items =
            bodyItems() + headerLine(715) + headerLine(730, prefix: "P")
            + headerLine(745, prefix: "Q") + headerLine(760, prefix: "R")
        let result = recover(items)
        // The fourth line is left where it was.
        #expect(result.cells.first == ["Q0 P0 H0", "Q1 P1 H1", "Q2 P2 H2"])
    }

    @Test func theNearestLineMustPopulateTwoColumns() {
        #expect(recover(bodyItems() + [item("H0", 100, 715)]).cells.count == 2)
    }

    @Test func aNarrowTableMustBeFullyLabelled() {
        // Three columns, only two labelled: there is too little evidence to
        // accept a partial header.
        #expect(
            recover(bodyItems() + [item("H0", 100, 715), item("H1", 200, 715)])
                .cells.count == 2)
    }

    @Test func aWideTableToleratesOneUnlabelledColumn() {
        // Five columns with four labelled — the unlabelled one is usually a
        // row-header stub.
        let items = bodyItems(columns: 5) + headerLine(715, columns: 4)
        #expect(recover(items, columns: 5).cells.count == 3)
    }

    @Test func moreItemsThanColumnsAbandonsTheWholeRecovery() {
        let items = bodyItems() + [
            item("H0", 100, 715), item("H1", 150, 715), item("H2", 200, 715),
            item("H3", 300, 715),
        ]
        #expect(recover(items).cells.count == 2)
    }

    @Test func alreadyClaimedItemsAreIgnored() {
        var result = table()
        result.itemIndices += [6, 7, 8]
        pdfRecoverUnclaimedHeaderRow(
            &result, items: bodyItems() + headerLine(715), hasRaggedRows: true)
        #expect(result.cells.count == 2)
    }

    @Test func theSearchWindowIsWiderOnTheRight() {
        // A header label may overhang the last column far more than the first,
        // so the window is −25pt on the left and +120pt on the right.
        #expect(
            recover(
                bodyItems()
                    + [item("H0", 76, 715), item("H1", 200, 715), item("H2", 300, 715)]
            ).cells.count == 3)
        #expect(
            recover(
                bodyItems()
                    + [item("H0", 74, 715), item("H1", 200, 715), item("H2", 300, 715)]
            ).cells.count == 2)
    }

    @Test func blankTextAboveTheTableIsSkipped() {
        let items = bodyItems() + [
            item("   ", 100, 715), item("H1", 200, 715), item("H2", 300, 715),
        ]
        // Only two columns end up populated, which a three-column table
        // refuses.
        #expect(recover(items).cells.count == 2)
    }

    @Test func recoveredItemsAreClaimedAndDeduplicated() {
        let result = recover(bodyItems() + headerLine(715))
        #expect(result.itemIndices == Array(0..<9))
    }
}
