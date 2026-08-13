import Testing

@testable import AnyDoc

/// What the spanning-line mask and the straggler split are each for.
///
/// Boundaries here were read off the reference rather than derived — the
/// straggler threshold in particular sits where the 30pt floor puts it, not
/// where three times the median would.
@Suite struct PdfSpanningLinesTests {

    private func item(_ x: Float, _ y: Float, _ width: Float, _ text: String = "w")
        -> PdfLayoutItem
    {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: 12, fontName: "F1")
    }

    /// Ten rows of two-column body text.
    private var body: [PdfLayoutItem] {
        var items: [PdfLayoutItem] = []
        for row in 0..<10 {
            let y = 700 - Float(row) * 14
            items.append(item(20, y, 260, "left"))
            items.append(item(320, y, 260, "right"))
        }
        return items
    }

    private let columns = [PdfColumnRegion(xMin: 0, xMax: 300), PdfColumnRegion(xMin: 300, xMax: 612)]

    // MARK: - identify_spanning_lines

    @Test func twoColumnsOfBodyTextSpanNothing() {
        // Each row reaches from 20 to 580, far past the 1.3× bar — but its
        // gap sits on the gutter, which is exactly what says "two columns"
        // rather than "one wide line".
        #expect(pdfIdentifySpanningLines(body, columns).allSatisfy { !$0 })
    }

    @Test func aTitleWhoseGapAvoidsTheGutterSpans() {
        let items = body + [item(20, 760, 120, "A"), item(160, 760, 420, "title")]
        let mask = pdfIdentifySpanningLines(items, columns)
        #expect(mask.suffix(2).allSatisfy { $0 })
        #expect(mask.dropLast(2).allSatisfy { !$0 })
    }

    @Test func aSingleWideItemIsNeverMarked() {
        // A line needs two items to have a gap to judge, so a title written
        // as one run is skipped however wide it is. Surprising, and the
        // reason the generated cases needed rebalancing.
        let items = body + [item(20, 760, 560, "solo")]
        #expect(pdfIdentifySpanningLines(items, columns).allSatisfy { !$0 })
    }

    @Test func oneGutterGapDisqualifiesTheWholeLine() {
        // Three pieces, the last gap landing on the gutter. The line is not
        // marked even though its first gap is nowhere near one.
        let items = body + [
            item(20, 760, 120, "a"), item(160, 760, 130, "b"), item(320, 760, 260, "c"),
        ]
        #expect(pdfIdentifySpanningLines(items, columns).allSatisfy { !$0 })
    }

    @Test func theSpanBarIsOneAndAThirdOfTheWidestColumn() {
        // The wider column is 312pt, so the bar is 405.6 — a line reaching
        // 400 is not marked and one reaching 406 is.
        func title(_ width: Int) -> [PdfLayoutItem] {
            let half = Float(width / 2)
            return body + [item(20, 760, half - 5, "a"), item(20 + half, 760, half, "b")]
        }
        #expect(pdfIdentifySpanningLines(title(400), columns).allSatisfy { !$0 })
        #expect(pdfIdentifySpanningLines(title(406), columns).suffix(2).allSatisfy { $0 })
    }

    @Test func gapsUnderFivePointsAreWordSpacing() {
        // Below 5pt the gap is not examined at all, so a gutter sitting
        // inside it does not disqualify the line.
        let tight = body + [item(20, 760, 278, "a"), item(300, 760, 280, "b")]
        #expect(pdfIdentifySpanningLines(tight, columns).suffix(2).allSatisfy { $0 })
        // Widen the same gap past 5pt and the gutter is seen.
        let loose = body + [item(20, 760, 270, "a"), item(300, 760, 280, "b")]
        #expect(pdfIdentifySpanningLines(loose, columns).allSatisfy { !$0 })
    }

    @Test func aPageWithoutColumnsHasNothingToSpan() {
        #expect(pdfIdentifySpanningLines(body, []).allSatisfy { !$0 })
        #expect(pdfIdentifySpanningLines(body, [columns[0]]).allSatisfy { !$0 })
    }

    @Test func fewerThanThreeItemsIsNotConsidered() {
        let two = [item(20, 700, 500, "a"), item(30, 690, 500, "b")]
        #expect(pdfIdentifySpanningLines(two, columns) == [false, false])
    }

    // MARK: - split_column_stragglers

    private func lines(_ baselines: [Float]) -> [PdfTextLine] {
        baselines.map { PdfTextLine(items: [item(0, $0, 8)], y: $0) }
    }

    private func evenly(_ count: Int, spacing: Float = 14, from: Float = 700) -> [Float] {
        (0..<count).map { from - Float($0) * spacing }
    }

    @Test func evenlySpacedLinesAreAllCore() {
        let split = pdfSplitColumnStragglers(lines(evenly(8)))
        #expect(split.core.count == 8)
        #expect(split.stragglers.isEmpty)
    }

    @Test func fewerThanThreeLinesIsLeftAlone() {
        for count in [0, 1, 2] {
            let split = pdfSplitColumnStragglers(lines(evenly(count)))
            #expect(split.core.count == count)
            #expect(split.stragglers.isEmpty)
        }
    }

    @Test func aHeaderRemnantFarAboveTheBodyIsAStraggler() {
        let split = pdfSplitColumnStragglers(lines([780] + evenly(10)))
        #expect(split.core.count == 10)
        #expect(split.stragglers.map(\.y) == [780])
    }

    @Test func aFooterFarBelowIsAStragglerToo() {
        let split = pdfSplitColumnStragglers(lines(evenly(10) + [80]))
        #expect(split.core.count == 10)
        #expect(split.stragglers.map(\.y) == [80])
    }

    @Test func theCoreIsTheLargestRunWhereverItSits() {
        // Three clusters of 3, 8 and 3 lines, with the big one moved through
        // each position.
        for big in 0..<3 {
            var baselines: [Float] = []
            var y: Float = 900
            for segment in 0..<3 {
                for _ in 0..<(segment == big ? 8 : 3) {
                    baselines.append(y)
                    y -= 14
                }
                y -= 200
            }
            let split = pdfSplitColumnStragglers(lines(baselines))
            #expect(split.core.count == 8, "largest segment at \(big)")
            #expect(split.stragglers.count == 6, "largest segment at \(big)")
        }
    }

    @Test func equalSegmentsKeepTheLowerOneAsCore() {
        // Rust's `max_by_key` returns the *last* maximum where Swift's
        // `max(by:)` returns the first, so this is the divergence the port
        // has to reproduce deliberately.
        for half in [2, 3, 4] {
            var baselines = evenly(half)
            let base = (baselines.last ?? 0) - 200
            baselines += evenly(half, from: base)
            let split = pdfSplitColumnStragglers(lines(baselines))
            #expect(split.core.count == half, "half \(half)")
            // The core is the *second* cluster, so the stragglers are the
            // higher baselines.
            #expect(split.core.first?.y == base, "half \(half)")
            #expect(split.stragglers.first?.y == 700, "half \(half)")
        }
    }

    @Test func theBreakThresholdHasAThirtyPointFloor() {
        // Four-point line spacing puts three times the median at 12, well
        // under the floor — so nothing splits until the gap passes 30, and
        // the comparison is strict.
        func tight(_ gap: Float) -> [PdfTextLine] {
            var baselines = evenly(6, spacing: 4)
            let base = (baselines.last ?? 0) - gap
            baselines += evenly(6, spacing: 4, from: base)
            return lines(baselines)
        }
        #expect(pdfSplitColumnStragglers(tight(29)).stragglers.isEmpty)
        #expect(pdfSplitColumnStragglers(tight(30)).stragglers.isEmpty)
        #expect(pdfSplitColumnStragglers(tight(31)).stragglers.count == 6)
    }

    @Test func uniformlyWideSpacingIsNotABreak() {
        // The threshold is three times the column's *own* median, so a
        // column whose every gap is 200pt has a 600pt bar and nothing
        // unusual in it. Only a gap that stands out from its neighbours
        // splits the column — which is the point of measuring relatively.
        let split = pdfSplitColumnStragglers(lines((0..<5).map { 900 - Float($0) * 200 }))
        #expect(split.core.count == 5)
        #expect(split.stragglers.isEmpty)
    }

    @Test func oneOutsizedGapAmongNormalOnesSplits() {
        // The same five lines with a single gap widened: now the median is
        // 14 and the bar is 42, so the odd one out is a break.
        var baselines = evenly(4)
        baselines += [(baselines.last ?? 0) - 200]
        let split = pdfSplitColumnStragglers(lines(baselines))
        #expect(split.core.count == 4)
        #expect(split.stragglers.map(\.y) == [(baselines.last ?? 0)])
    }
}
