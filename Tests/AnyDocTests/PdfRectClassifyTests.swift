import Testing

@testable import AnyDoc

/// Saying what a rectangle cluster is, before any table is built from it.
@Suite struct PdfRectClassifyTests {
    private typealias Rect = (x: Float, y: Float, width: Float, height: Float)

    private func item(_ text: String, x: Float, y: Float) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: 20, fontSize: 8, fontName: "F1")
    }

    /// Alternating row shading gives rectangles that share an x position and
    /// width, so a grid detector sees two x-edges and one column. Spotting
    /// the pattern is what lets the columns come from the text instead.
    @Test func fullWidthBandsAreRowStripes() {
        var stripes: [Rect] = []
        for row in 0..<6 {
            stripes.append((x: 100, y: 700 - Float(row) * 20, width: 400, height: 18))
        }
        #expect(pdfIsRowStripePattern(stripes))
    }

    /// The bands must be page-spanning and near-identical in width.
    @Test func narrowOrRaggedBandsAreNotStripes() {
        var narrow: [Rect] = []
        for row in 0..<6 {
            narrow.append((x: 100, y: 700 - Float(row) * 20, width: 150, height: 18))
        }
        #expect(!pdfIsRowStripePattern(narrow), "under 200pt is a cell, not a stripe")

        var ragged: [Rect] = []
        for row in 0..<6 {
            let w: Float = 400 - Float(row) * 60
            ragged.append((x: 100, y: 700 - Float(row) * 20, width: w, height: 18))
        }
        #expect(!pdfIsRowStripePattern(ragged))
    }

    /// A background is only dropped when the producer stamps *many* of them.
    /// One full-page backdrop is harmless and stays.
    @Test func pageBackgroundsGoOnlyWhenRepeated() {
        let cell: Rect = (x: 100, y: 700, width: 60, height: 20)
        let background: Rect = (x: 0, y: 0, width: 600, height: 780)

        let many = [Rect](repeating: background, count: 9) + [cell]
        #expect(pdfWithoutDominantPageBackgrounds(many).count == 1)

        let few = [Rect](repeating: background, count: 3) + [cell]
        #expect(pdfWithoutDominantPageBackgrounds(few).count == 4)
    }

    /// Bars drawn as filled rectangles look exactly like cell backgrounds;
    /// without this test a chart's axis labels get gridded into a table.
    @Test func aVerticalBarChartIsRecognised() {
        var bars: [Rect] = []
        var labels: [PdfLayoutItem] = []
        for i in 0..<6 {
            let x: Float = 100 + Float(i) * 60
            let height: Float = 40 + Float(i) * 35
            bars.append((x: x, y: 400, width: 30, height: height))
            labels.append(item(String(10 * i), x: x + 5, y: 395))
        }
        #expect(pdfIsChartBarCluster(items: labels, groupRects: bars))
    }

    /// Words inside the rectangles mean table cells, whatever the geometry.
    @Test func wordLabelsMakeItATableNotAChart() {
        var bars: [Rect] = []
        var labels: [PdfLayoutItem] = []
        for i in 0..<6 {
            let x: Float = 100 + Float(i) * 60
            let height: Float = 40 + Float(i) * 35
            bars.append((x: x, y: 400, width: 30, height: height))
            labels.append(item("category", x: x + 5, y: 405))
        }
        #expect(!pdfIsChartBarCluster(items: labels, groupRects: bars))
    }

    /// The test runs again with the axes swapped, which is what catches a
    /// horizontal chart.
    @Test func horizontalBarsAreCaughtByTheMirroredTest() {
        var bars: [Rect] = []
        for i in 0..<6 {
            let y: Float = 400 + Float(i) * 40
            let width: Float = 60 + Float(i) * 45
            bars.append((x: 100, y: y, width: width, height: 20))
        }
        #expect(pdfIsChartBarCluster(items: [], groupRects: bars))
    }

    /// Uniform rectangles are a grid, not data: bars vary in length because
    /// the length *is* the datum.
    @Test func uniformRectanglesAreNotBars() {
        var cells: [Rect] = []
        for row in 0..<4 {
            for column in 0..<4 {
                let x: Float = 100 + Float(column) * 60
                let y: Float = 700 - Float(row) * 20
                cells.append((x: x, y: y, width: 30, height: 20))
            }
        }
        #expect(!pdfIsChartBarCluster(items: [], groupRects: cells))
    }
}
