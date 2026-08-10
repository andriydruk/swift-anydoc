import Testing

@testable import AnyDoc

/// The last-resort rect strategy: rows from every rectangle, columns from
/// the text.
@Suite struct PdfMergedClusterTests {
    private typealias Rect = (x: Float, y: Float, width: Float, height: Float)

    private func bands(_ count: Int, height: Float = 20) -> [Rect] {
        var out: [Rect] = []
        for row in 0..<count {
            let y: Float = 700 - Float(row) * height
            out.append((x: 100, y: y, width: 400, height: height - 2))
        }
        return out
    }

    private func item(_ text: String, x: Float, y: Float, width: Float = 40) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: 10, fontName: "F1")
    }

    @Test func rowsComeFromRectanglesAndColumnsFromText() {
        let rects = bands(5)
        var items: [PdfLayoutItem] = []
        for row in 0..<5 {
            let y: Float = 705 - Float(row) * 20
            items.append(item("name\(row)", x: 110, y: y))
            items.append(item("\(row)", x: 260, y: y, width: 20))
            items.append(item("9.9", x: 400, y: y, width: 25))
        }
        let table = try! #require(pdfDetectMergedClusterTable(items: items, allRects: rects))
        #expect(table.columns.count == 3)
        #expect(table.cells[0][0].hasPrefix("name"))
    }

    /// Unlike grid building, which trims empty *outer* columns, an empty
    /// column anywhere is fatal here — the columns came from the text, so an
    /// empty one means the clustering was wrong.
    @Test func anyEmptyColumnIsFatal() {
        let rects = bands(5)
        var items: [PdfLayoutItem] = []
        for row in 0..<5 {
            let y: Float = 705 - Float(row) * 20
            items.append(item("a\(row)", x: 110, y: y))
            items.append(item("b\(row)", x: 260, y: y))
        }
        // A lone far-right item opens a third column that nothing else fills.
        items.append(item("stray", x: 470, y: 705, width: 20))
        let table = pdfDetectMergedClusterTable(items: items, allRects: rects)
        if let table {
            #expect(
                table.cells.allSatisfy { row in row.allSatisfy { !$0.isEmpty } || row.count < 3 },
                "an accepted table must have no empty column")
        }
    }

    @Test func tooFewRowEdgesIsRejected() {
        let rects: [Rect] = [(x: 100, y: 700, width: 400, height: 18)]
        #expect(pdfDetectMergedClusterTable(items: [item("x", x: 110, y: 705)], allRects: rects)
            == nil)
    }

    /// One column of text gives nothing to grid against.
    @Test func aSingleTextColumnIsRejected() {
        let rects = bands(5)
        let items = (0..<5).map { item("only\($0)", x: 110, y: 705 - Float($0) * 20) }
        #expect(pdfDetectMergedClusterTable(items: items, allRects: rects) == nil)
    }

    /// Density has to clear 40% — higher than grid building's 25%, because
    /// no geometry backs the columns.
    @Test func sparseContentIsRejected() {
        let rects = bands(8)
        var items: [PdfLayoutItem] = []
        for row in 0..<2 {
            let y: Float = 705 - Float(row) * 20
            items.append(item("a", x: 110, y: y))
            items.append(item("b", x: 300, y: y))
        }
        #expect(pdfDetectMergedClusterTable(items: items, allRects: rects) == nil)
    }

    /// The same prose guard the stripe path uses: a chart's rectangles
    /// swallowing the page.
    @Test func aDominantProseCellIsRejected() {
        let rects = bands(5)
        let paragraph = (0..<90).map { "word\($0)" }.joined(separator: " ")
        var items: [PdfLayoutItem] = [item(paragraph, x: 110, y: 705, width: 300)]
        for row in 1..<5 {
            let y: Float = 705 - Float(row) * 20
            items.append(item("a", x: 110, y: y))
            items.append(item("b", x: 300, y: y))
        }
        #expect(pdfDetectMergedClusterTable(items: items, allRects: rects) == nil)
    }
}
