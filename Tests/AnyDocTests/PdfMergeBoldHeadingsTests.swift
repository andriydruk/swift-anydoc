import Testing

@testable import AnyDoc

/// Short bold runs merged into one heading, and the column count of a
/// rendered table.
@Suite struct PdfMergeBoldHeadingsTests {
    private func bold(
        _ text: String, y: Float, x: Float = 20, size: Float = 10, page: Int = 1,
        isBold: Bool = true
    ) -> PdfTextLine {
        var item = PdfLayoutItem(
            text: text, x: x, y: y, width: 40, fontSize: size, fontName: "F1")
        item.isBold = isBold
        return PdfTextLine(items: [item], y: y, page: page)
    }

    private func run(
        _ count: Int, text: String = "A Short Bold Heading", size: Float = 10,
        isBold: Bool = true, gap: Float = 14, y0: Float = 700
    ) -> [PdfTextLine] {
        (0..<count).map {
            bold(text, y: y0 - Float($0) * gap, size: size, isBold: isBold)
        }
    }

    private func merged(_ lines: [PdfTextLine], base: Float = 10, threshold: Float = 20)
        -> [PdfTextLine]
    {
        pdfMergeWrappedBoldHeadingGroups(lines, baseSize: base, paraThreshold: threshold)
    }

    @Test func onlyRunsOfTwoOrThreeMerge() {
        // One line is not a wrap and four is a paragraph; both pass through
        // untouched.
        #expect(merged(run(1)).count == 1)
        #expect(merged(run(2)).count == 1)
        #expect(merged(run(3)).count == 1)
        #expect(merged(run(4)).count == 4)
    }

    @Test func theWordBudgetIsFifteen() {
        let seven = "one two three four five six seven"
        let eight = "one two three four five six seven eight"
        // Two lines of seven words is fourteen and merges; two of eight is
        // sixteen and does not.
        #expect(merged(run(2, text: seven)).count == 1)
        #expect(merged(run(2, text: eight)).count == 2)
    }

    @Test func aNeighbourInsideTheGapBlocksTheMergeInclusively() {
        // The group occupies 700 and 686. A line exactly `threshold` away
        // from either end blocks; one point further does not.
        for (y, expected) in [(Float(720), 3), (721, 2), (666, 3), (665, 2)] {
            let lines = run(2) + [bold("plain neighbour", y: y, isBold: false)]
            #expect(merged(lines).count == expected, "neighbour at \(y)")
        }
    }

    @Test func aNeighbourOnlyBlocksWhereItOverlapsHorizontally() {
        // The group spans x 20…60. Overlap is strict at both edges, so a
        // neighbour starting exactly at 60 is clear of it.
        for (x, expected) in [(Float(0), 3), (55, 3), (60, 2), (61, 2)] {
            let lines = run(2) + [bold("plain", y: 714, x: x, isBold: false)]
            #expect(merged(lines).count == expected, "neighbour at x \(x)")
        }
    }

    @Test func aNeighbourOnAnotherPageNeverBlocks() {
        let lines = run(2) + [bold("plain", y: 714, page: 2, isBold: false)]
        #expect(merged(lines).count == 2)
    }

    @Test func aSectionNumberOverridesIsolationButNotLength() {
        let blocked = [bold("plain neighbour", y: 714, isBold: false)]
        // Isolation fails, but a two-component section number carries it.
        #expect(merged(run(2, text: "9.5. Numbered Heading") + blocked).count == 2)
        // `1.` is an ordered list item to the `convert.rs` spelling of the
        // check, so it does not.
        #expect(merged(run(2, text: "1. Numbered Heading") + blocked).count == 3)
        // And a number cannot rescue a four-line run.
        #expect(merged(run(4, text: "9.5. Numbered Heading")).count == 4)
    }

    @Test func linesThatAreNotBodySizeBoldPassThrough() {
        #expect(merged(run(2, isBold: false)).count == 2)
        #expect(merged(run(2, size: 14)).count == 2)
    }

    @Test func theMergedLineKeepsTheFirstBaselineAndItemOrder() {
        let lines = run(3)
        let result = merged(lines)
        #expect(result.count == 1)
        #expect(result[0].y == 700)
        #expect(result[0].page == 1)
        // Items are concatenated in line order, not re-sorted.
        #expect(result[0].items.count == 3)
        #expect(result[0].items.map(\.y) == [700, 686, 672])
    }

    @Test func groupsAndOrdinaryLinesInterleaveCorrectly() {
        let lines =
            [bold("plain top", y: 800, isBold: false)] + run(2, y0: 700)
            + [bold("plain middle", y: 500, isBold: false)] + run(2, y0: 400)
        let result = merged(lines)
        #expect(result.map(\.y) == [800, 700, 500, 400])
        #expect(result.map(\.items.count) == [1, 2, 1, 2])
    }

    // MARK: - count_table_columns

    @Test func theColumnCountComesFromTheSeparatorRow() {
        #expect(pdfCountTableColumns("| a | b |\n| --- | --- |\n| 1 | 2 |") == 2)
        #expect(pdfCountTableColumns("| a |\n| --- |") == 1)
        // The header is never consulted, so a table whose rows disagree
        // reports whatever the separator claims.
        #expect(pdfCountTableColumns("| a | b |\n| --- | --- | --- |") == 3)
    }

    @Test func aSecondRowWithoutDashesIsNotATable() {
        #expect(pdfCountTableColumns("| a | b |\n| x | y |") == 0)
        #expect(pdfCountTableColumns("| a | b |") == 0)
        #expect(pdfCountTableColumns("") == 0)
    }

    @Test func fewerThanTwoPipesCountsAsNoColumns() {
        // `---` alone contains the dashes but carries no pipes at all.
        #expect(pdfCountTableColumns("| a | b |\n---") == 0)
        #expect(pdfCountTableColumns("| a | b |\n ---  ") == 0)
        // An empty header row is fine: only the second line is read.
        #expect(pdfCountTableColumns("\n| --- | --- |") == 2)
    }
}
