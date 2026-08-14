import Testing

@testable import AnyDoc

/// What the layout assembly produces, and which ordering it chose.
///
/// The value here is composition: every one of these exercises the whole
/// stack from column detection down to line grouping, so a divergence
/// anywhere beneath shows up as a wrong ordering.
@Suite struct PdfGroupLinesTests {

    private let prose = "a sentence of genuine running prose text"

    private func item(_ x: Float, _ y: Float, _ width: Float, _ text: String? = nil)
        -> PdfLayoutItem
    {
        PdfLayoutItem(
            text: text ?? prose, x: x, y: y, width: width, fontSize: 12, fontName: "F1")
    }

    /// Two columns of `rows` lines each.
    private func twoColumns(left: Int = 12, right: Int = 12) -> [PdfLayoutItem] {
        var out = (0..<left).map { item(20, 700 - Float($0) * 14, 200) }
        out += (0..<right).map { item(340, 700 - Float($0) * 14, 200) }
        return out
    }

    private func lines(
        _ items: [PdfLayoutItem], threshold: Float = 0.10, table: Bool = false,
        charts: [PdfImageRegion] = [], images: [PdfImageRegion] = [],
        filterPageNumbers: Bool = true
    ) -> [PdfTextLine] {
        pdfGroupPageIntoLines(
            items, adaptiveThreshold: threshold, hasTable: table, chartRegions: charts,
            imageRegions: images, filterPageNumbers: filterPageNumbers)
    }

    // MARK: - the simple shapes

    @Test func anEmptyPageHasNoLines() {
        #expect(lines([]).isEmpty)
    }

    @Test func aPageOfNothingButPageNumbersEmptiesOut() {
        // Markdown output drops them, so the page has nothing left. A
        // plain-text caller opting out keeps both.
        let numbers = [item(300, 60, 20, "7"), item(300, 780, 20, "3")]
        #expect(lines(numbers).isEmpty)
        #expect(lines(numbers, filterPageNumbers: false).count == 2)
    }

    @Test func aSingleColumnPageIsGroupedDirectly() {
        let page = (0..<12).map { item(20, 700 - Float($0) * 14, 560) }
        let grouped = lines(page)
        #expect(grouped.count == 12)
        #expect(grouped.allSatisfy { $0.items.count == 1 })
    }

    @Test func theAdaptiveThresholdIsCarriedOntoEveryLine() {
        // Not used by this function — it rides along for the word joiner.
        let grouped = lines(twoColumns(), threshold: 0.55)
        #expect(!grouped.isEmpty)
        #expect(grouped.allSatisfy { $0.adaptiveThreshold == 0.55 })
    }

    // MARK: - the two orderings

    @Test func aTabularPageInterleavesItsColumnsByBaseline() {
        // Rows at the same height in different columns are one logical line,
        // so twelve rows of two columns give twelve lines of two items.
        let grouped = lines(twoColumns())
        #expect(grouped.count == 12)
        #expect(grouped.allSatisfy { $0.items.count == 2 })
        // And each line runs left to right.
        #expect(grouped.first?.items.map(\.x) == [20, 340])
    }

    @Test func aNewspaperPageEmitsWholeColumnsInTurn() {
        // Dense balanced columns are independent flows: all of the first,
        // then all of the second, rather than interleaved.
        let grouped = lines(twoColumns(left: 30, right: 26))
        #expect(grouped.count == 56)
        // The first thirty lines are the left column, in descending order.
        #expect(grouped.prefix(30).allSatisfy { $0.items.first?.x == 20 })
        #expect(grouped.dropFirst(30).allSatisfy { $0.items.first?.x == 340 })
    }

    @Test func spanningMaterialLeadsAndTrailsANewspaperPage() {
        // A full-width heading goes out before either column and a footer
        // after both, whatever their own baselines would say.
        var page = [item(20, 780, 560, "a full width heading above the columns")]
        page += twoColumns(left: 30, right: 26)
        page += [item(20, 200, 560, "a full width footer below the columns")]
        let grouped = lines(page)
        #expect(grouped.first?.items.first?.y == 780)
        #expect(grouped.last?.items.first?.y == 200)
        // The columns are still whole and in order between them.
        #expect(grouped.dropFirst().prefix(30).allSatisfy { $0.items.first?.x == 20 })
    }

    @Test func aTitleWrittenAsTwoRunsIsStillOneSpanningLine() {
        // Split across column buckets it would corrupt both the ordering and
        // newspaper detection, so it is lifted out before bucketing — as long
        // as its own gap is nowhere near the gutter.
        var page = [
            item(20, 780, 120, "a full width heading"),
            item(160, 780, 400, "above the columns here"),
        ]
        page += twoColumns(left: 30, right: 26)
        let grouped = lines(page)
        #expect(grouped.first?.items.count == 2)
        #expect(grouped.first?.y == 780)
    }

    @Test func aTitleWhoseGapSitsAtTheGutterIsNotSpanning() {
        // The same title moved so its gap straddles the gutter is
        // indistinguishable from two columns' text sharing a baseline, and
        // is filed into the columns instead. This is the rule from
        // `identify_spanning_lines` showing through at the assembly level.
        var page = [
            item(20, 780, 250, "a full width heading"),
            item(300, 780, 260, "above the columns here"),
        ]
        page += twoColumns(left: 30, right: 26)
        let grouped = lines(page)
        #expect(grouped.first?.items.count == 1)
        #expect(grouped.prefix(2).map { $0.items.first?.x } == [20, 300])
    }

    // MARK: - the region and chart paths

    @Test func aHeroImageSendsThePageThroughTheRegionGraph() {
        // Ordering then comes from the band rather than from the histogram:
        // heading, left column, right column.
        var page = [item(55, 700, 430, "heading above the band")]
        for row in 0..<5 {
            let y = 380 - Float(row) * 14
            page.append(item(55, y, 210, "left column prose words"))
            page.append(item(280, y, 210, "right column prose words"))
        }
        let hero = [PdfImageRegion(x0: 55, y0: 450, x1: 490, y1: 880)]
        let withImage = lines(page, images: hero)
        let without = lines(page)
        #expect(withImage.first?.y == 700)
        // The left column comes out whole before the right one.
        #expect(withImage.dropFirst().prefix(5).allSatisfy { $0.items.first?.x == 55 })
        // Without the image the same page is ordered differently.
        #expect(withImage.map(\.items.count) != without.map(\.items.count))
    }

    @Test func chartsBlockTheRegionGraphEntirely() {
        // Charts have their own positioned-region ordering, so a page with
        // any takes the histogram path however good its hero image is.
        var page = [item(55, 700, 430, "heading above the band")]
        for row in 0..<5 {
            let y = 380 - Float(row) * 14
            page.append(item(55, y, 210, "left column prose words"))
            page.append(item(280, y, 210, "right column prose words"))
        }
        let hero = [PdfImageRegion(x0: 55, y0: 450, x1: 490, y1: 880)]
        let chart = [PdfImageRegion(x0: 240, y0: 400, x1: 400, y1: 700)]
        #expect(lines(page, images: hero) != lines(page, charts: chart, images: hero))
    }

    @Test func chartTextIsHiddenFromTheHistogramOnly() {
        // The columns are detected blind to chart-internal text, but the
        // text itself still appears in the output — it is only the column
        // *detection* that ignores it.
        var page = twoColumns()
        page += (0..<12).map { item(260 + Float($0 % 3) * 40, 690 - Float($0) * 20, 30, "12") }
        let chart = [PdfImageRegion(x0: 240, y0: 400, x1: 400, y1: 700)]
        let blinded = lines(page, charts: chart)
        let plain = lines(page)
        let blindedItems = blinded.reduce(0) { $0 + $1.items.count }
        let plainItems = plain.reduce(0) { $0 + $1.items.count }
        #expect(blindedItems == plainItems)
    }
}

extension PdfTextLine: Equatable {
    public static func == (left: PdfTextLine, right: PdfTextLine) -> Bool {
        left.y == right.y && left.items.count == right.items.count
            && zip(left.items, right.items).allSatisfy { $0.x == $1.x && $0.text == $1.text }
    }
}
