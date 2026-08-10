import Testing

@testable import AnyDoc

/// Building a table from shaded row bands.
@Suite struct PdfRowStripeTests {
    private typealias Rect = (x: Float, y: Float, width: Float, height: Float)

    private func item(_ text: String, x: Float, y: Float, width: Float = 40) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: 10, fontName: "F1")
    }

    private func stripes(_ count: Int) -> [Rect] {
        var out: [Rect] = []
        for row in 0..<count {
            out.append((x: 100, y: 700 - Float(row) * 20, width: 400, height: 18))
        }
        return out
    }

    /// Rows come from the bands; columns from where the text starts.
    @Test func stripesGiveRowsAndTextGivesColumns() {
        var items: [PdfLayoutItem] = []
        for row in 0..<5 {
            let y: Float = 705 - Float(row) * 20
            items.append(item("name\(row)", x: 110, y: y))
            items.append(item("\(row)", x: 260, y: y, width: 20))
            items.append(item("9.9", x: 400, y: y, width: 25))
        }
        let table = try! #require(pdfDetectRowStripeTable(items: items, groupRects: stripes(5)))
        #expect(table.columns.count == 3)
        #expect(table.cells[0][0].hasPrefix("name"))
    }

    /// Without the stripe shape there is nothing to take rows from.
    @Test func nonStripeClustersAreRejected() {
        var narrow: [Rect] = []
        for row in 0..<5 {
            narrow.append((x: 100, y: 700 - Float(row) * 20, width: 120, height: 18))
        }
        #expect(pdfDetectRowStripeTable(items: [item("a", x: 110, y: 705)], groupRects: narrow)
            == nil)
    }

    /// Columns come from where text *starts*, and a run that hugs the
    /// previous one is a style split, not a new column.
    @Test func continuationRunsDoNotOpenColumns() {
        // Two runs touching at x=140 on one line, plus a real second column.
        let items = [
            item("bold", x: 100, y: 700, width: 40),
            item("plain", x: 140, y: 700, width: 40),
            item("value", x: 300, y: 700, width: 40),
            item("bold", x: 100, y: 680, width: 40),
            item("plain", x: 140, y: 680, width: 40),
            item("value", x: 300, y: 680, width: 40),
        ]
        #expect(pdfClusterXPositions(items, minimumThreshold: 15).count == 2)
    }

    /// A chart's rectangles can pass the shape test; the giveaway is one cell
    /// holding a paragraph and most of the table's words.
    @Test func aDominantProseCellIsRejected() {
        let paragraph = (0..<80).map { "word\($0)" }.joined(separator: " ")
        #expect(pdfHasDominantProseCell([[paragraph, "x"], ["y", "z"]]))
        // Spread across cells, the same words are a real table.
        let spread = (0..<8).map { row in
            (0..<3).map { column in "cell \(row) \(column) some words here" }
        }
        #expect(!pdfHasDominantProseCell(spread))
    }

    /// A sparse label column beside a dense column of sentences is a prose
    /// outline — a heading sidebar over body text — not a table.
    @Test func sparseProseOutlinesAreRejected() {
        var cells: [[String]] = [["Heading", "the first sentence of the body text here"]]
        for _ in 0..<5 {
            cells.append(["", "another long sentence of body text continues here"])
        }
        #expect(pdfRowStripeIsSparseProseOutline(cells))
    }

    /// A real two-column table fills both columns, so it is not an outline.
    @Test func filledTwoColumnTablesAreNotOutlines() {
        let cells = (0..<6).map { ["label\($0)", "\($0)"] }
        #expect(!pdfRowStripeIsSparseProseOutline(cells))
    }
}
