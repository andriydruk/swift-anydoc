import Testing

@testable import AnyDoc

/// Cleaning a page's rectangles before any strategy sees them.
@Suite struct PdfRectPipelineTests {
    private typealias Rect = (x: Float, y: Float, width: Float, height: Float)

    private func cells(rows: Int, columns: Int) -> [Rect] {
        var out: [Rect] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x: Float = 100 + Float(column) * 60
                let y: Float = 700 - Float(row) * 20
                out.append((x: x, y: y, width: 60, height: 20))
            }
        }
        return out
    }

    /// A transform can flip either axis, giving negative extents.
    @Test func negativeExtentsAreNormalised() {
        let flipped: [Rect] = [(x: 300, y: 700, width: -100, height: -20)]
        let prepared = pdfPreparePageRects(flipped)
        #expect(prepared.count == 1)
        #expect(prepared[0].x == 200)
        #expect(prepared[0].y == 680)
        #expect(prepared[0].width == 100)
        #expect(prepared[0].height == 20)
    }

    @Test func decorationIsDropped() {
        let decoration: [Rect] = [
            (x: 100, y: 600, width: 3, height: 20),
            (x: 100, y: 500, width: 60, height: 3),
            (x: 100, y: 400, width: 60, height: 20),
        ]
        #expect(pdfPreparePageRects(decoration).count == 1)
    }

    /// A page-spanning fill would contribute spurious column edges. The
    /// gate is ten times the median width and is **inclusive**, so a fill
    /// exactly at the limit survives — nine 60pt cells give a median of 60
    /// and a threshold of 600, which a 600pt fill passes.
    @Test func oversizedFillsAreDroppedAboveTenTimesTheMedian() {
        let atTheLimit = cells(rows: 3, columns: 3) + [(x: 0, y: 0, width: 600, height: 780)]
        #expect(pdfPreparePageRects(atTheLimit).count == 10, "600 <= 600 is kept")

        let over = cells(rows: 3, columns: 3) + [(x: 0, y: 0, width: 601, height: 780)]
        let prepared = pdfPreparePageRects(over)
        #expect(prepared.count == 9)
        #expect(!prepared.contains { $0.width > 600 })
    }

    /// The oversized filter keys on median *width*, not area — so a
    /// row-stripe table, where every rectangle is full width, keeps them all.
    @Test func rowStripesSurviveTheOversizedFilter() {
        var stripes: [Rect] = []
        for row in 0..<8 {
            stripes.append((x: 100, y: 700 - Float(row) * 20, width: 400, height: 18))
        }
        #expect(pdfPreparePageRects(stripes).count == 8)
    }

    /// Shading inside a cell would add y-edges and split one visual row.
    @Test func cellInternalShadingIsDeduplicated() {
        let shaded = cells(rows: 3, columns: 3) + [(x: 102, y: 702, width: 56, height: 16)]
        #expect(pdfPreparePageRects(shaded).count == 9)
    }

    /// A container that dwarfs the inner rectangle is a background, not
    /// shading, so the inner one survives.
    @Test func aDwarfingContainerDoesNotCount() {
        var rects = cells(rows: 3, columns: 3)
        // Tall frame around the first column, and a normal cell inside it.
        rects.append((x: 98, y: 640, width: 64, height: 82))
        let prepared = pdfPreparePageRects(rects)
        #expect(prepared.contains { $0.width == 60 && $0.height == 20 })
    }

    /// Too few rectangles for a median to mean anything: only the size
    /// filter runs.
    @Test func smallInputsSkipTheMedianFilters() {
        let few: [Rect] = [
            (x: 0, y: 0, width: 600, height: 780),
            (x: 100, y: 700, width: 60, height: 20),
        ]
        #expect(pdfPreparePageRects(few).count == 2)
    }

    /// The direct chain tries a grid, then stripes, then stacked boxes —
    /// the order of decreasing geometric evidence.
    @Test func theDirectChainPrefersAGrid() {
        let grid = cells(rows: 3, columns: 3)
        var items: [PdfLayoutItem] = []
        for row in 0..<3 {
            for column in 0..<3 {
                items.append(
                    PdfLayoutItem(
                        text: "v\(row)\(column)", x: 110 + Float(column) * 60,
                        y: 705 - Float(row) * 20, width: 30, fontSize: 10, fontName: "F1"))
            }
        }
        let table = try! #require(pdfDetectDirectRectTable(items: items, rects: grid))
        #expect(table.columns.count == 3)
    }
}
