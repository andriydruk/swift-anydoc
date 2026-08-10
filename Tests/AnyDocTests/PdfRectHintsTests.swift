import Testing

@testable import AnyDoc

/// Hint and chart regions: what the rectangles say when they cannot build a
/// table.
@Suite struct PdfRectHintsTests {
    private typealias Rect = (x: Float, y: Float, width: Float, height: Float)

    private func hint(_ top: Float, _ bottom: Float, _ left: Float, _ right: Float)
        -> PdfRectHintRegion
    {
        PdfRectHintRegion(yTop: top, yBottom: bottom, xLeft: left, xRight: right)
    }

    private func item(_ text: String, _ x: Float, _ y: Float) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: 40, fontSize: 10, fontName: "F1")
    }

    // MARK: merging

    @Test func neighbouringHintsOnTheSameRowsMerge() {
        // A 20pt gutter and a combined width of 300 — one table split into
        // column groups.
        let merged = pdfMergeOverlappingHints([
            hint(700, 500, 100, 200), hint(700, 500, 220, 400),
        ])
        #expect(merged.count == 1)
        #expect(merged.first?.xLeft == 100)
        #expect(merged.first?.xRight == 400)
    }

    @Test func hintsThatWouldMergeTooWideStayApart() {
        // Merging these would span 450pt, past the 400pt cap that stops a
        // chain of hints from creeping across the page.
        let merged = pdfMergeOverlappingHints([
            hint(700, 500, 100, 300), hint(700, 500, 340, 550),
        ])
        #expect(merged.count == 2)
    }

    @Test func hintsOnDifferentRowsStayApart() {
        // They share no vertical span, so they are two regions whatever their
        // horizontal distance.
        let merged = pdfMergeOverlappingHints([
            hint(700, 600, 100, 200), hint(500, 400, 210, 300),
        ])
        #expect(merged.count == 2)
    }

    @Test func mergingRepeatsUntilNothingMoreJoins() {
        // A chains to B and B to C, but A and C are 240pt apart — only a
        // second pass folds all three together.
        let merged = pdfMergeOverlappingHints([
            hint(700, 500, 100, 180), hint(700, 500, 200, 280), hint(700, 500, 300, 380),
        ])
        #expect(merged.count == 1)
        #expect(merged.first?.xRight == 380)
    }

    // MARK: small-cluster extraction

    @Test func aFewRowBordersBecomeARegion() {
        let rects: [Rect] = [
            (x: 100, y: 700, width: 300, height: 6),
            (x: 100, y: 660, width: 300, height: 6),
            (x: 100, y: 620, width: 300, height: 6),
        ]
        let region = pdfExtractHintRegion(rects)
        #expect(region?.yTop == 706)
        #expect(region?.yBottom == 620)
        #expect(region?.xLeft == 100)
        // Unlike the loop's own hints, this one carries no rectangles.
        #expect(region?.clusterRects.isEmpty == true)
    }

    @Test func anEnclosingBoxIsDroppedBeforeTheBoundsAreTaken() {
        // The tall frame is over four times the median height, so the region
        // covers the row borders rather than the box around them.
        let rects: [Rect] = [
            (x: 90, y: 600, width: 320, height: 200),
            (x: 100, y: 700, width: 300, height: 6),
            (x: 100, y: 660, width: 300, height: 6),
        ]
        #expect(pdfExtractHintRegion(rects)?.yBottom == 660)
    }

    @Test func aLargeClusterYieldsNoSmallHint() {
        // Nine rectangles is past the eight this is willing to trust.
        let rects: [Rect] = (0..<9).map {
            (x: 100, y: 700 - Float($0) * 20, width: 300, height: 6)
        }
        #expect(pdfExtractHintRegion(rects) == nil)
    }

    @Test func aRegionTooShortToHoldRowsIsRefused() {
        let rects: [Rect] = [
            (x: 100, y: 700, width: 300, height: 6),
            (x: 100, y: 702, width: 300, height: 6),
        ]
        #expect(pdfExtractHintRegion(rects) == nil)
    }

    // MARK: the page-level pass

    @Test func aSingleDecorativeClusterIsNotWorthScopingTo() {
        // One calendar-shaped cluster with no text: a hint is built and then
        // dropped, because scoping the heuristic detector to it would hide
        // the rest of the page.
        var rects: [Rect] = []
        for row in 0..<6 {
            for column in 0..<6 {
                rects.append(
                    (x: 100 + Float(column) * 60, y: 700 - Float(row) * 20, width: 60, height: 20))
            }
        }
        let result = pdfDetectTablesFromRects(items: [], rects: rects)
        #expect(result.tables.isEmpty)
        #expect(result.hints.isEmpty)
    }

    @Test func twoDecorativeClustersSurviveAsHints() {
        var rects: [Rect] = []
        for group in 0..<2 {
            for row in 0..<6 {
                for column in 0..<6 {
                    rects.append(
                        (
                            x: 100 + Float(column) * 60,
                            y: 700 - Float(group) * 200 - Float(row) * 20,
                            width: 60, height: 20
                        ))
                }
            }
        }
        #expect(pdfDetectTablesFromRects(items: [], rects: rects).hints.count == 2)
    }

    @Test func hintsAreNotProducedWhenATableWasFound() {
        // The heuristic detector does not run at all in that case, so there
        // is nothing for a hint to scope.
        var rects: [Rect] = []
        var items: [PdfLayoutItem] = []
        for row in 0..<3 {
            for column in 0..<3 {
                let x: Float = 100 + Float(column) * 60
                rects.append((x: x, y: 700 - Float(row) * 20, width: 60, height: 20))
                items.append(item("v\(row)\(column)", x + 10, 705 - Float(row) * 20))
            }
        }
        let result = pdfDetectTablesFromRects(items: items, rects: rects)
        #expect(result.tables.count == 1)
        #expect(result.hints.isEmpty)
    }

    // MARK: chart regions

    @Test func aBarChartYieldsItsBoundingBox() {
        var rects: [Rect] = [(x: 100, y: 294, width: 220, height: 6)]
        var items: [PdfLayoutItem] = []
        for bar in 0..<6 {
            rects.append(
                (x: 100 + Float(bar) * 40, y: 300, width: 25, height: 60 + Float(bar) * 35))
            items.append(item("\(bar * 12)", 105 + Float(bar) * 40, 295))
        }
        let regions = pdfDetectChartRegions(items: items, rects: rects)
        #expect(regions.count == 1)
        // Corners, not an extent.
        #expect(regions.first?.left == 100)
        #expect(regions.first?.bottom == 294)
        #expect(regions.first?.right == 325)
    }

    @Test func anOriginAnchoredBackgroundIsNotChartGeometry() {
        // Letting one bridge into a bar cluster would inflate the region to
        // the whole page, so it is dropped outright here — not merely held
        // out of clustering as the table loop does.
        var rects: [Rect] = [(x: 0, y: 0, width: 612, height: 792), (x: 100, y: 294, width: 220, height: 6)]
        var items: [PdfLayoutItem] = []
        for bar in 0..<6 {
            rects.append(
                (x: 100 + Float(bar) * 40, y: 300, width: 25, height: 60 + Float(bar) * 35))
            items.append(item("\(bar * 12)", 105 + Float(bar) * 40, 295))
        }
        let regions = pdfDetectChartRegions(items: items, rects: rects)
        #expect(regions.count == 1)
        #expect(regions.first?.right == 325)
    }

    @Test func aPlainGridIsNoChart() {
        var rects: [Rect] = []
        for row in 0..<3 {
            for column in 0..<3 {
                rects.append(
                    (x: 100 + Float(column) * 60, y: 700 - Float(row) * 20, width: 60, height: 20))
            }
        }
        #expect(pdfDetectChartRegions(items: [], rects: rects).isEmpty)
    }
}
