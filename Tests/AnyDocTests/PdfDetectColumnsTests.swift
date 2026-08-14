import Testing

@testable import AnyDoc

/// What column detection concludes, and which of its three routes gets there.
@Suite struct PdfDetectColumnsTests {

    private func item(_ x: Float, _ y: Float, _ width: Float, _ text: String = "word")
        -> PdfLayoutItem
    {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: 12, fontName: "F1")
    }

    /// `rows` lines of text, one item per x position given.
    private func page(
        rows: Int, at columns: [Float], width: Float = 200, step: Float = 14, top: Float = 700,
        text: String = "word"
    ) -> [PdfLayoutItem] {
        var items: [PdfLayoutItem] = []
        for row in 0..<rows {
            let y = top - Float(row) * step
            for x in columns { items.append(item(x, y, width, text)) }
        }
        return items
    }

    private func detect(_ items: [PdfLayoutItem], table: Bool = false) -> [PdfColumnRegion] {
        pdfDetectColumns(items, pageHasTable: table)
    }

    // MARK: - the shape of the answer

    @Test func anEmptyPageHasNoColumns() {
        // The only case that returns nothing at all. Everything else gets at
        // least one region, so callers never have to handle a failure.
        #expect(detect([]).isEmpty)
    }

    @Test func theRegionsSpanTheTextNotThePage() {
        // Measured from the items' own extent, so the margins — which hold
        // nothing to measure — are outside the first and last column.
        let columns = detect(page(rows: 30, at: [20], width: 560))
        #expect(columns.count == 1)
        #expect(columns.first?.xMin == 20)
        #expect(columns.first?.xMax == 580)
    }

    @Test func aCleanGutterGivesTwoColumns() {
        let columns = detect(page(rows: 15, at: [20, 340]))
        #expect(columns.count == 2)
        // The boundary is the gutter's centre: text ends at 220 and resumes
        // at 340, so the cut is at 280.
        #expect(columns.first?.xMax == 280)
    }

    @Test func threeAndFourColumnPagesAreFound() {
        #expect(detect(page(rows: 15, at: [10, 170, 330], width: 140)).count == 3)
        #expect(detect(page(rows: 15, at: [10, 160, 310, 460], width: 130)).count == 4)
    }

    // MARK: - the guards before any detection happens

    @Test func aNarrowPageIsOneColumn() {
        // Under 200pt of text there is nothing to divide.
        #expect(detect(page(rows: 20, at: [0, 60], width: 40)).count == 1)
        #expect(detect(page(rows: 20, at: [0, 300], width: 40)).count == 2)
    }

    @Test func tooLittleTextToProject() {
        // Twenty items is the floor. Below it the histogram is noise, and
        // this bound is also what makes the reference's empty-list crash in
        // the XY cut unreachable.
        #expect(detect(page(rows: 9, at: [20, 340])).count == 1)
        #expect(detect(page(rows: 10, at: [20, 340])).count == 2)
    }

    // MARK: - what the histogram is allowed to see

    @Test func aFullWidthTitleDoesNotFillTheGutter() {
        // Items over 60% of the page width are left out of the projection.
        // Without that, a title would bridge the gutter and hide it — which
        // is what stops a two-column abstract being found under a heading.
        let body = page(rows: 15, at: [20, 340])
        #expect(detect(body + [item(20, 780, 560, "title")]).count == 2)
        // Just under the bar the title is counted and the gutter disappears.
        #expect(detect(body + [item(20, 780, 300, "title")]).count == 2)
    }

    @Test func aGutterNarrowerThanEightPointsIsLetterSpacing() {
        #expect(detect(page(rows: 15, at: [20, 226])).count == 1)
        #expect(detect(page(rows: 15, at: [20, 232])).count == 2)
    }

    @Test func aFewStrayItemsDoNotFillAGutter() {
        // A bin at or below 15% of the busiest counts as empty. With twenty
        // rows the threshold is three, so up to three strays in the gutter
        // are tolerated and the two columns survive.
        let body = page(rows: 20, at: [20, 340])
        func withStrays(_ count: Int) -> [PdfLayoutItem] {
            body + (0..<count).map { item(250, 700 - Float($0) * 14, 40, "x") }
        }
        #expect(detect(withStrays(1)).count == 2)
        #expect(detect(withStrays(3)).count == 2)
    }

    @Test func enoughItemsInAGutterBecomeTheirOwnColumn() {
        // Past the noise threshold they are not noise. They do not fill the
        // gutter — they divide it, leaving a narrow middle column.
        let body = page(rows: 20, at: [20, 340])
        let items = body + (0..<10).map { item(250, 700 - Float($0) * 14, 40, "x") }
        let columns = detect(items)
        #expect(columns.count == 3)
        #expect(columns[1].xMin == 235 && columns[1].xMax == 315)
    }

    @Test func itemsBridgingTheGutterCloseIt() {
        // The other shape: items reaching across rather than sitting inside.
        // A few are still noise; enough of them and there is no gutter left.
        let body = page(rows: 20, at: [20, 340])
        func withBridges(_ count: Int) -> [PdfLayoutItem] {
            body + (0..<count).map { item(215, 700 - Float($0) * 14, 130, "x") }
        }
        #expect(detect(withBridges(3)).count == 2)
        #expect(detect(withBridges(10)).count == 1)
    }

    // MARK: - the routes

    /// Two columns whose text reaches the gutter on both sides, so no bin is
    /// ever empty and only the relative search can find the dip.
    private func justified(rows: Int, jitter: Float = 30) -> [PdfLayoutItem] {
        var items: [PdfLayoutItem] = []
        for row in 0..<rows {
            let y = 700 - Float(row) * 12
            let shrink = Float(row % 5) * (jitter / 5)
            items.append(item(20, y, 290 - shrink, "a line of running prose text"))
            items.append(item(310, y, 280 - shrink, "a line of running prose text"))
        }
        return items
    }

    @Test func justifiedTextNeedsTheRelativeRoute() {
        // Dense enough to be allowed to try — a hundred items — and the two
        // sides read as prose, so the split is committed to.
        #expect(detect(justified(rows: 55)).count == 2)
    }

    @Test func theRelativeRouteIsOnlyForDensePages() {
        // The same shape with too few items is left as one column: a sparse
        // page's shallow dips are not evidence of anything.
        #expect(detect(justified(rows: 30)).count == 1)
    }

    @Test func aTablePageIsNeverSplitByTheRelativeRoute() {
        // A table's column gaps look identical to gutters, and the table
        // pipeline already orders them — so the flag blocks both fallbacks.
        #expect(detect(justified(rows: 55)).count == 2)
        #expect(detect(justified(rows: 55), table: true).count == 1)
    }

    @Test func aRelativeSplitMustAlsoReadAsProse() {
        // Short scattered cells produce the same shallow dip, and are
        // refused: the columns carry too many items per line to be prose.
        var items: [PdfLayoutItem] = []
        for row in 0..<55 {
            let y = 700 - Float(row) * 11
            for cell in 0..<5 { items.append(item(20 + Float(cell) * 56, y, 56, "cell")) }
            for cell in 0..<5 { items.append(item(320 + Float(cell) * 56, y, 56, "cell")) }
            if row % 4 == 0 { items.append(item(300, y, 20, "x")) }
        }
        #expect(detect(items).count == 1)
    }

    @Test func aPageWithNoGutterAnywhereIsOneColumn() {
        let full = (0..<30).map { item(20, 700 - Float($0) * 14, 560, "full width paragraph") }
        #expect(detect(full).count == 1)
    }

    @Test func columnsMustRunAlongsideEachOther() {
        // Text above a figure and text beside it are told apart by vertical
        // overlap, as in wave 62 — a large enough offset stops being columns.
        var stacked = (0..<15).map { item(20, 700 - Float($0) * 14, 200, "l") }
        stacked += (0..<15).map { item(340, 400 - Float($0) * 14, 200, "r") }
        #expect(detect(stacked).count == 1)
        #expect(detect(page(rows: 15, at: [20, 340])).count == 2)
    }

    @Test func unmeasuredWidthsStillProject() {
        // The estimate from text length drives the histogram when the
        // extractor recorded no width.
        var items = (0..<15).map { item(20, 700 - Float($0) * 14, 0, "left column text") }
        items += (0..<15).map { item(340, 700 - Float($0) * 14, 0, "right column text") }
        #expect(detect(items).count == 2)
    }
}
