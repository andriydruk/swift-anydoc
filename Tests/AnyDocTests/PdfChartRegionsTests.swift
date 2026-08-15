import Testing

@testable import AnyDoc

/// Which text belongs to a chart rather than to the prose around it.
@Suite struct PdfChartRegionsTests {

    /// A chart occupying x 100–400, y 400–600.
    private let chart = PdfImageRegion(x0: 100, y0: 400, x1: 400, y1: 600)

    private func item(
        _ x: Float, _ y: Float, width: Float = 60, height: Float = 10, size: Float = 10,
        _ text: String = "Label"
    ) -> PdfLayoutItem {
        var made = PdfLayoutItem(
            text: text, x: x, y: y, width: width, fontSize: size, fontName: "F1")
        made.height = height
        return made
    }

    private func label(_ item: PdfLayoutItem) -> Bool {
        pdfIsChartAdjacentLabel(item, chart)
    }

    // MARK: - is_chart_adjacent_label

    @Test func aCompactRunNearTheChartIsALabel() {
        #expect(label(item(150, 615, width: 100)))
    }

    @Test func theTwentyPointBandIsTheOuterLimit() {
        // Beyond it nothing qualifies, however label-like.
        #expect(label(item(150, 620, width: 100)))
        #expect(!label(item(150, 621, width: 100)))
        // Inside the chart's own box the gap is zero.
        #expect(label(item(150, 500, width: 100)))
    }

    @Test func aCompactRunQualifiesOnItsOwn() {
        // Up to 18.5 ems wide — 185pt at 10pt type. Isolated at a 19pt gap,
        // which is outside the 18.5pt category band, so the compact route is
        // the only one left.
        #expect(label(item(150, 619, width: 185)))
        #expect(!label(item(150, 619, width: 186)))
    }

    @Test func aCaptionQualifiesHoweverWide() {
        // Width and position aside, a caption beside a chart is its caption.
        #expect(label(item(150, 615, width: 400, "Figure 1: A caption")))
        #expect(!label(item(150, 615, width: 400, "Plain words")))
    }

    @Test func aWideRunNeedsToLookLikeACategoryAxis() {
        // Wider than the compact bar, so only the category route remains: it
        // must be at most three quarters of the chart's own width, which is
        // 225pt here.
        let text = "a much longer run of label text"
        #expect(label(item(150, 615, width: 225, text)))
        #expect(!label(item(150, 615, width: 226, text)))
    }

    @Test func aWideRunMustSitMostlyWithinTheChartsWidth() {
        // Four fifths of it. A compact run would pass regardless, so this
        // needs one wide enough to depend on the overlap.
        let text = "a much longer run of label text"
        #expect(label(item(60, 615, width: 200, text)))
        #expect(!label(item(40, 615, width: 200, text)))
    }

    @Test func bulletsAndListItemsAreNeverLabels() {
        for text in ["•", "●", "-", "*", "1. item", "• item"] {
            #expect(!label(item(150, 605, text)), "\(text) should not be a label")
        }
    }

    @Test func theTypeSizeSetsTheCompactBar() {
        // 18.5 ems, so a 150pt run is compact at 10pt type and not at 8pt.
        // Measured at a 19pt gap so the category route cannot rescue it.
        #expect(label(item(150, 619, width: 150, height: 0, size: 10)))
        #expect(!label(item(150, 619, width: 150, height: 0, size: 8)))
        // A recorded height above the font size takes over.
        #expect(label(item(150, 619, width: 150, height: 10, size: 6)))
        #expect(!label(item(150, 619, width: 150, height: 0, size: 6)))
    }

    // MARK: - item_is_in_chart_region

    @Test func membershipIsDecidedByTheRunsCentre() {
        // The centre must fall within the padded box: 80 to 420 here.
        #expect(!pdfItemIsInChartRegion(item(60, 500, width: 20), [chart]))
        #expect(pdfItemIsInChartRegion(item(80, 500, width: 20), [chart]))
        #expect(pdfItemIsInChartRegion(item(400, 500, width: 20), [chart]))
        #expect(!pdfItemIsInChartRegion(item(420, 500, width: 20), [chart]))
    }

    @Test func insideTheBoxNeedsNoFurtherArgument() {
        // A run that would fail the label test still belongs if it sits
        // within the chart's own bounds.
        let wide = item(110, 500, width: 280, "a much longer run of prose text here")
        #expect(!label(wide))
        #expect(pdfItemIsInChartRegion(wide, [chart]))
    }

    @Test func outsideTheBoxTheLabelTestDecides() {
        let wide = item(110, 615, width: 280, "a much longer run of prose text here")
        #expect(!pdfItemIsInChartRegion(wide, [chart]))
        #expect(pdfItemIsInChartRegion(item(110, 615, width: 100), [chart]))
    }

    @Test func anyRegionCanClaimARun() {
        let second = PdfImageRegion(x0: 450, y0: 100, x1: 700, y1: 300)
        #expect(pdfItemIsInChartRegion(item(500, 200, width: 40), [chart, second]))
        #expect(!pdfItemIsInChartRegion(item(500, 200, width: 40), [chart]))
        #expect(!pdfItemIsInChartRegion(item(500, 200, width: 40), []))
    }

    // MARK: - items_outside_chart_regions

    @Test func theFilterKeepsWhatTheChartsDoNotClaim() {
        let items = [
            item(150, 500, width: 40, "inside"),
            item(800, 700, width: 40, "far away"),
        ]
        let kept = pdfItemsOutsideChartRegions(items, [chart])
        #expect(kept.count == 1)
        #expect(kept.first?.text == "far away")
        // With no regions everything survives.
        #expect(pdfItemsOutsideChartRegions(items, []).count == 2)
        #expect(pdfItemsOutsideChartRegions([], [chart]).isEmpty)
    }
}
