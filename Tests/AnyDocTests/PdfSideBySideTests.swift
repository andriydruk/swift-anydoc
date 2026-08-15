import Testing

@testable import AnyDoc

/// Telling two tables set beside each other from one wide table.
///
/// Getting it wrong either way is bad: reading two as one interleaves their
/// rows, and reading one as two splits every row in half. So the test is
/// deliberately hard to satisfy.
@Suite struct PdfSideBySideTests {

    private func item(
        _ x: Float, _ y: Float, width: Float = 60, _ text: String = "Label text"
    ) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: 10, fontName: "F1")
    }

    /// Two two-column tables, the right one at `rightX`.
    private func twoTables(
        rows: Int = 12, rightX: Float = 340, rightText: String = "Other text",
        spanning: Int = 0, rightOffset: Float = 0
    ) -> [PdfLayoutItem] {
        var out: [PdfLayoutItem] = []
        for row in 0..<rows {
            let y = 700 - Float(row) * 14
            for column in 0..<2 {
                out.append(item(40 + Float(column) * 60, y))
                out.append(item(rightX + Float(column) * 60, y - rightOffset, rightText))
            }
        }
        for index in 0..<spanning {
            out.append(item(100, 720 + Float(index) * 14, width: 400, "a spanning header here"))
        }
        return out
    }

    @Test func twoTablesSideBySideSplitIntoTwoBands() {
        let bands = pdfSplitSideBySide(twoTables())
        #expect(bands.count == 2)
        #expect(bands.first?.low == 40)
        #expect(bands.first?.high == 220)
        #expect(bands.last?.high == 400)
    }

    @Test func aSparsePageIsNotJudged() {
        // Forty runs is the floor — nine rows of four is thirty-six.
        #expect(pdfSplitSideBySide(twoTables(rows: 9)).isEmpty)
        #expect(pdfSplitSideBySide(twoTables(rows: 10)).count == 2)
        #expect(pdfSplitSideBySide([]).isEmpty)
    }

    @Test func aFewSpanningHeadersAreTolerated() {
        // Up to a twentieth of the page may cross the split, floored at two.
        #expect(pdfSplitSideBySide(twoTables(spanning: 2)).count == 2)
        #expect(pdfSplitSideBySide(twoTables(spanning: 3)).isEmpty)
    }

    @Test func aRunReachingAcrossTheGapDefeatsIt() {
        // Bringing the right table close enough that the left table's own
        // runs cross the midpoint. The gap is still wide, but the crossings
        // are what decide.
        #expect(pdfSplitSideBySide(twoTables(rightX: 200)).isEmpty)
        #expect(pdfSplitSideBySide(twoTables(rightX: 340)).count == 2)
    }

    @Test func labelsBesideFiguresAreOneTable() {
        // All three signs must show: text on the left, numbers on the right,
        // and the two lining up row for row.
        #expect(pdfSplitSideBySide(twoTables(rightText: "1,234.56")).isEmpty)
        // Offset the figures past the 5pt baseline tolerance and it is two
        // regions again.
        #expect(pdfSplitSideBySide(twoTables(rightText: "1,234.56", rightOffset: 4)).isEmpty)
        #expect(pdfSplitSideBySide(twoTables(rightText: "1,234.56", rightOffset: 5)).count == 2)
    }

    @Test func numbersOnBothSidesAreNotTheLabelPattern() {
        // The rule needs the *left* to be mostly text; two numeric columns
        // are two regions.
        var out: [PdfLayoutItem] = []
        for row in 0..<12 {
            let y = 700 - Float(row) * 14
            for column in 0..<2 {
                out.append(item(40 + Float(column) * 60, y, "99.5"))
                out.append(item(340 + Float(column) * 60, y, "1,234.56"))
            }
        }
        #expect(pdfSplitSideBySide(out).count == 2)
    }

    @Test func threeEvenlySpacedColumnsAreOneWideTable() {
        // Several balanced candidates far apart mean a multi-column table
        // rather than two regions.
        var out: [PdfLayoutItem] = []
        for row in 0..<14 {
            let y = 700 - Float(row) * 14
            for x: Float in [40, 240, 440] { out.append(item(x, y)) }
        }
        #expect(pdfSplitSideBySide(out).isEmpty)
    }

    @Test func aPageWithEverythingOnOneSideHasNoBalancedSplit() {
        var out: [PdfLayoutItem] = []
        for row in 0..<24 {
            let y = 700 - Float(row) * 14
            out.append(item(40, y))
            out.append(item(100, y))
        }
        #expect(pdfSplitSideBySide(out).isEmpty)
    }
}
