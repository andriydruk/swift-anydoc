import Testing

@testable import AnyDoc

/// What the XY cut and the newspaper test each decide.
@Suite struct PdfXyCutTests {

    private func item(_ x: Float, _ y: Float, _ width: Float, _ text: String = "w")
        -> PdfLayoutItem
    {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: 12, fontName: "F1")
    }

    /// Two blocks of text either side of a gap.
    private func sides(
        leftCount: Int = 12, rightCount: Int = 12, leftX: Float = 20, leftWidth: Float = 200,
        rightX: Float = 340, rightWidth: Float = 200, rightTop: Float = 700
    ) -> [PdfLayoutItem] {
        var items = (0..<leftCount).map { item(leftX, 700 - Float($0) * 14, leftWidth, "l") }
        items += (0..<rightCount).map { item(rightX, rightTop - Float($0) * 14, rightWidth, "r") }
        return items
    }

    private func cut(
        _ items: [PdfLayoutItem], xMin: Float = 0, xMax: Float = 612
    ) -> [PdfColumnRegion]? {
        pdfTryXyCutSplit(items, pageXMin: xMin, pageXMax: xMax)
    }

    // MARK: - try_xy_cut_split

    @Test func aCleanGapSplitsThePageAtItsMiddle() {
        let split = cut(sides())
        #expect(split?.count == 2)
        // The left block ends at 220 and the right starts at 340, so the cut
        // is at 280 — the middle of the gap, not of the page.
        #expect(split?.first?.xMax == 280)
        #expect(split?.first?.xMin == 0)
        #expect(split?.last?.xMax == 612)
    }

    @Test func aNarrowPageIsNeverSplit() {
        // Items sized to fit inside the narrow page, so the width floor is
        // what decides rather than the margin rule.
        var items = (0..<12).map { item(0, 700 - Float($0) * 14, 60, "l") }
        items += (0..<12).map { item(120, 700 - Float($0) * 14, 60, "r") }
        #expect(cut(items, xMax: 199) == nil)
        #expect(cut(items, xMax: 201) != nil)
    }

    @Test func aGapUnderFifteenPointsIsWordSpacing() {
        // The left block ends at 220, so the right block's start sets the gap.
        #expect(cut(sides(rightX: 234)) == nil)
        #expect(cut(sides(rightX: 236)) != nil)
    }

    @Test func aFullWidthBannerSuppressesTheCut() {
        // This is what the running maximum is for. The banner reaches past
        // the gap, so by the time the sweep arrives at the right-hand block
        // there is nothing left to cut — without tracking the furthest right
        // edge seen so far, a false gap would appear behind the banner.
        #expect(cut(sides()) != nil)
        #expect(cut([item(20, 760, 560, "banner")] + sides()) == nil)
    }

    @Test func overlappingItemsNeverProduceASplit() {
        // Their gap is negative and the running best starts at zero, so no
        // candidate can win.
        var items = (0..<12).map { item(20, 700 - Float($0) * 14, 400, "a") }
        items += (0..<12).map { item(200, 700 - Float($0) * 14, 400, "b") }
        #expect(cut(items) == nil)
    }

    @Test func aCutInThePageMarginIsRejected() {
        // The cut lands midway *between the two blocks*, so reaching a margin
        // means the blocks sit close together near one edge — not far apart.
        // A tenth of a 612pt page is 61.2pt.
        func nearLeft(_ rightX: Float) -> [PdfLayoutItem] {
            var items = (0..<12).map { item(0, 700 - Float($0) * 14, 10, "l") }
            items += (0..<12).map { item(rightX, 700 - Float($0) * 14, 300, "r") }
            return items
        }
        #expect(cut(nearLeft(100)) == nil)  // cut at 55
        #expect(cut(nearLeft(130)) != nil)  // cut at 70

        func nearRight(_ leftWidth: Float) -> [PdfLayoutItem] {
            var items = (0..<12).map { item(0, 700 - Float($0) * 14, leftWidth, "l") }
            items += (0..<12).map { item(600, 700 - Float($0) * 14, 10, "r") }
            return items
        }
        #expect(cut(nearRight(520)) == nil)  // cut at 560
        #expect(cut(nearRight(480)) != nil)  // cut at 540
    }

    @Test func theBusySideNeedsTenItemsAndTheQuietOneThree() {
        // Checked with the two blocks overlapping enough vertically that the
        // count is what decides.
        #expect(cut(sides(leftCount: 3, rightCount: 9)) == nil)
        #expect(cut(sides(leftCount: 3, rightCount: 10)) != nil)
    }

    @Test func bothSidesMustRunAlongsideEachOther() {
        // Two items' worth of shared height out of a much taller page is not
        // two columns. Twelve rows against three gives 28pt of overlap in a
        // 154pt range — 0.18, just under the 0.20 bar.
        #expect(cut(sides(leftCount: 3, rightCount: 12)) == nil)
        #expect(cut(sides(leftCount: 3, rightCount: 10)) != nil)
    }

    @Test func aSingleItemHasNoGapToFind() {
        // The loop does not run, so the zero gap fails the minimum. No guard
        // needed for this — unlike the empty list, which the reference
        // panics on and this port refuses deliberately.
        #expect(cut([item(20, 700, 100, "only")]) == nil)
        #expect(cut([]) == nil)
    }

    // MARK: - is_newspaper_layout

    private func run(_ count: Int, from: Float = 700, step: Float = 14) -> [PdfTextLine] {
        (0..<count).map { index in
            let y = from - Float(index) * step
            return PdfTextLine(items: [item(0, y, 8)], y: y)
        }
    }

    private let evenColumns = [
        PdfColumnRegion(xMin: 0, xMax: 300), PdfColumnRegion(xMin: 300, xMax: 612),
    ]
    private let sidebarColumns = [
        PdfColumnRegion(xMin: 0, xMax: 400), PdfColumnRegion(xMin: 400, xMax: 580),
    ]

    @Test func oneColumnIsNotNewspaper() {
        #expect(!pdfIsNewspaperLayout([run(30)], evenColumns))
        #expect(!pdfIsNewspaperLayout([], evenColumns))
    }

    @Test func aColumnUnderFiveLinesEndsIt() {
        #expect(!pdfIsNewspaperLayout([run(4), run(30)], evenColumns))
        #expect(pdfIsNewspaperLayout([run(20), run(30)], evenColumns))
    }

    @Test func denseColumnsOfSimilarLengthAreNewspaper() {
        // Table items are gone by this point, so what remains is prose.
        #expect(pdfIsNewspaperLayout([run(25), run(30)], evenColumns))
        #expect(pdfIsNewspaperLayout([run(30), run(30)], evenColumns))
    }

    @Test func aSparseNarrowSidebarIsNewspaperToo() {
        // Every guard has to hold at once: two columns, one much narrower,
        // far fewer lines, a body of at least twenty, a sidebar at least
        // 160pt wide, and its lines spread at least 2.5× as thinly.
        let sparse = run(8, step: 40)
        #expect(pdfIsNewspaperLayout([run(30), sparse], sidebarColumns))
    }

    @Test func aSidebarSetAsDenselyAsTheBodyIsNot() {
        // Same shape, same counts — only the spacing differs, and that alone
        // decides it.
        #expect(!pdfIsNewspaperLayout([run(30), run(8, step: 14)], sidebarColumns))
    }

    @Test func theNarrowerColumnMustAlsoBeTheEmptierOne() {
        // A narrow column packed with lines is a dense reference table, not
        // a sidebar. Here the *wide* column is the sparse one.
        #expect(!pdfIsNewspaperLayout([run(8, step: 40), run(30)], sidebarColumns))
    }

    @Test func aSidebarNarrowerThanOneSixtyPointsIsAMarginNote() {
        let sparse = run(8, step: 40)
        let wide = [PdfColumnRegion(xMin: 0, xMax: 400), PdfColumnRegion(xMin: 420, xMax: 580)]
        let narrow = [PdfColumnRegion(xMin: 0, xMax: 400), PdfColumnRegion(xMin: 425, xMax: 580)]
        #expect(pdfIsNewspaperLayout([run(30), sparse], wide))
        #expect(!pdfIsNewspaperLayout([run(30), sparse], narrow))
    }

    @Test func unbalancedColumnsFallBackToBaselineCollisions() {
        // The shortest column's lines either sit beside another column's or
        // follow them. More than half colliding means side by side.
        let long = run(30)
        func short(aligned: Int) -> [PdfTextLine] {
            (0..<16).map { index in
                let y = index < aligned ? 700 - Float(index) * 14 : 100 - Float(index) * 14
                return PdfTextLine(items: [item(0, y, 8)], y: y)
            }
        }
        #expect(!pdfIsNewspaperLayout([short(aligned: 7), long], evenColumns))
        #expect(pdfIsNewspaperLayout([short(aligned: 9), long], evenColumns))
    }
}
