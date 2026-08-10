import Testing

@testable import AnyDoc

/// Routing through the rectangle table orchestrator: which strategy claims a
/// page, and which fallback picks up what the one before it dropped.
@Suite struct PdfRectTablesTests {
    private typealias Rect = (x: Float, y: Float, width: Float, height: Float)

    private func item(_ text: String, _ x: Float, _ y: Float) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: 40, fontSize: 10, fontName: "F1")
    }

    /// A `rows` × `columns` grid of touching cells.
    private func grid(rows: Int, columns: Int, x0: Float = 100, y0: Float = 700) -> [Rect] {
        var rects: [Rect] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x: Float = x0 + Float(column) * 60
                let y: Float = y0 - Float(row) * 20
                rects.append((x: x, y: y, width: 60, height: 20))
            }
        }
        return rects
    }

    private func gridItems(rows: Int, columns: Int, x0: Float = 100, y0: Float = 700, tag: String)
        -> [PdfLayoutItem]
    {
        var items: [PdfLayoutItem] = []
        for row in 0..<rows {
            for column in 0..<columns {
                items.append(
                    item("\(tag)\(row)\(column)", x0 + Float(column) * 60 + 10,
                        y0 - Float(row) * 20 + 5))
            }
        }
        return items
    }

    @Test func aPageWithTooFewRectanglesYieldsNothing() {
        // Five cells is below the bar the whole loop is gated on.
        #expect(
            pdfDetectTablesFromRects(
                items: gridItems(rows: 1, columns: 5, tag: "v"),
                rects: grid(rows: 1, columns: 5)
            ).isEmpty)
    }

    @Test func twoSeparateGridsBecomeTwoTables() {
        let rects = grid(rows: 3, columns: 3) + grid(rows: 3, columns: 3, y0: 500)
        let items =
            gridItems(rows: 3, columns: 3, tag: "a")
            + gridItems(rows: 3, columns: 3, y0: 500, tag: "b")
        let tables = pdfDetectTablesFromRects(items: items, rects: rects)
        #expect(tables.count == 2)
        #expect(tables.first?.cells.first == ["a00", "a01", "a02"])
        #expect(tables.last?.cells.first == ["b00", "b01", "b02"])
    }

    @Test func narrowPerClusterTablesAreReplacedByTheMergedOne() {
        // Three two-column groups: each detects on its own, and all three
        // being narrow is the signal that one table was split across
        // clusters — so the merge replaces them rather than adding to them.
        var rects: [Rect] = []
        var items: [PdfLayoutItem] = []
        for group in 0..<3 {
            for row in 0..<15 {
                for column in 0..<2 {
                    let x: Float = Float(group) * 180 + Float(column) * 70 + 50
                    rects.append((x: x, y: 700 - Float(row) * 20, width: 70, height: 20))
                    items.append(item("g\(group)c\(column)r\(row)", x + 5, 705 - Float(row) * 20))
                }
            }
        }
        let tables = pdfDetectTablesFromRects(items: items, rects: rects)
        #expect(tables.count == 1)
        #expect((tables.first?.columns.count ?? 0) > 3)
    }

    @Test func rowStripesThatNeverClusterAreTriedAsAWholePage() {
        // Bands separated by more than the clustering tolerance produce no
        // clusters at all, so the page itself is the only candidate left.
        var rects: [Rect] = []
        var items: [PdfLayoutItem] = []
        for row in 0..<16 {
            rects.append((x: 100, y: 700 - Float(row) * 30, width: 400, height: 15))
            for column in 0..<3 {
                items.append(
                    item("s\(row)\(column)", 110 + Float(column) * 130, 705 - Float(row) * 30))
            }
        }
        let tables = pdfDetectTablesFromRects(items: items, rects: rects)
        #expect(tables.count == 1)
        #expect((tables.first?.rows.count ?? 0) >= 10)
    }

    @Test func tooFewStripesForTheWholePageFallback() {
        // The same shape cut to twelve bands: under the fifteen-rectangle bar
        // that keeps decorative fills out.
        var rects: [Rect] = []
        var items: [PdfLayoutItem] = []
        for row in 0..<12 {
            rects.append((x: 100, y: 700 - Float(row) * 30, width: 400, height: 15))
            for column in 0..<3 {
                items.append(
                    item("s\(row)\(column)", 110 + Float(column) * 130, 705 - Float(row) * 30))
            }
        }
        #expect(pdfDetectTablesFromRects(items: items, rects: rects).isEmpty)
    }

    @Test func aBarChartIsDroppedRatherThanGridded() {
        // Bars stand apart, so an axis rule is what clusters them at all.
        // Gridding the axis labels would scramble the page, so the whole
        // cluster is skipped — it never reaches a detector or a fallback.
        var rects: [Rect] = [(x: 100, y: 294, width: 220, height: 6)]
        var items: [PdfLayoutItem] = []
        for bar in 0..<6 {
            rects.append(
                (x: 100 + Float(bar) * 40, y: 300, width: 25, height: 60 + Float(bar) * 35))
            items.append(item("\(bar * 12)", 105 + Float(bar) * 40, 295))
        }
        #expect(pdfIsChartBarCluster(items: items, groupRects: rects))
        #expect(pdfDetectTablesFromRects(items: items, rects: rects).isEmpty)
    }

    @Test func cellBackgroundsFallThroughToTheCellRectStrategy() {
        // A grid whose columns are too irregular to build directly, but whose
        // rows the rectangles still describe.
        var rects: [Rect] = [(x: 100, y: 720, width: 460, height: 20)]
        rects += grid(rows: 3, columns: 3, x0: 100)
        rects += grid(rows: 3, columns: 3, x0: 380)
        var items: [PdfLayoutItem] = [item("header", 110, 725)]
        items += gridItems(rows: 3, columns: 3, x0: 100, tag: "a")
        items += gridItems(rows: 3, columns: 3, x0: 380, tag: "b")
        let tables = pdfDetectTablesFromRects(items: items, rects: rects)
        #expect(tables.count == 1)
        #expect((tables.first?.rows.count ?? 0) >= 3)
    }
}
