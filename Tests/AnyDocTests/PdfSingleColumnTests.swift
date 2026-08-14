import Testing

@testable import AnyDoc

/// What the single-column grouper decides, and why each test exists.
@Suite struct PdfSingleColumnTests {

    private func item(
        _ x: Float, _ y: Float, _ width: Float, _ text: String = "run", bold: Bool = false,
        size: Float = 12
    ) -> PdfLayoutItem {
        var made = PdfLayoutItem(
            text: text, x: x, y: y, width: width, fontSize: size, fontName: "F1")
        made.isBold = bold
        return made
    }

    /// Enough alphabetic characters and words to pass the prose tests.
    private let prose = "a sentence of genuine running prose"
    /// The same, starting uppercase.
    private let upperProse = "A Sentence Of Genuine Running Prose"

    /// Filler lines below, so a case is never a single line on its own.
    private func filler(from row: Int = 1, count: Int = 5) -> [PdfLayoutItem] {
        (row..<(row + count)).map { item(20, 700 - Float($0) * 14, 50, "c") }
    }

    // MARK: - should_use_y_sorting

    @Test func orderlyStreamOrderIsTrusted() {
        // Stream order is usually already reading order, and sorting throws
        // away information when runs share a baseline — so it is kept.
        let items = (0..<10).map { item(20, 700 - Float($0) * 14, 200) }
        #expect(!pdfShouldUseYSorting(items))
    }

    @Test func chaoticStreamOrderIsSorted() {
        // A producer that jumps back up the page constantly cannot be
        // trusted. More than two in five large jumps going up is the bar.
        func stream(upward: Int) -> [PdfLayoutItem] {
            var items: [PdfLayoutItem] = []
            var y: Float = 700
            for step in 0..<8 {
                items.append(item(20, y, 200))
                y += step < upward ? 120 : -120
            }
            return items
        }
        #expect(!pdfShouldUseYSorting(stream(upward: 2)))
        #expect(pdfShouldUseYSorting(stream(upward: 4)))
    }

    @Test func tooLittleToJudgeIsNotChaos() {
        // Under five items the question is not asked at all.
        #expect(!pdfShouldUseYSorting((0..<4).map { item(20, 700 + Float($0) * 200, 50) }))
        // Nor with fewer than three *large* jumps, however they run.
        let gentle = (0..<8).map { item(20, 700 - Float($0) * 2, 50) }
        #expect(!pdfShouldUseYSorting(gentle))
    }

    // MARK: - grouping

    @Test func runsOnOneBaselineFormOneLine() {
        var items: [PdfLayoutItem] = []
        for row in 0..<4 {
            let y = 700 - Float(row) * 14
            items.append(item(20, y, 100, "left"))
            items.append(item(130, y, 100, "right"))
        }
        let lines = pdfGroupSingleColumn(items)
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { $0.items.count == 2 })
    }

    @Test func linesAreOrderedLeftToRightWhateverTheStreamSaid() {
        var items: [PdfLayoutItem] = []
        for row in 0..<4 {
            let y = 700 - Float(row) * 14
            items.append(item(130, y, 100, "right"))
            items.append(item(20, y, 100, "left"))
        }
        let lines = pdfGroupSingleColumn(items)
        #expect(lines.count == 4)
        #expect(lines.first?.items.map(\.x) == [20, 130])
    }

    @Test func onlyTheMostRecentLineIsEverExtended() {
        // The lookback is one line deep. A run returning to an earlier
        // baseline opens a new line rather than rejoining the old one —
        // which is why the merge tests have to be thorough.
        let items = [
            item(20, 700, 50, "a"), item(20, 660, 50, "b"), item(200, 700, 50, "c"),
        ]
        let lines = pdfGroupSingleColumn(items)
        #expect(lines.count == 3)
    }

    @Test func anEmptyColumnHasNoLines() {
        #expect(pdfGroupSingleColumn([]).isEmpty)
    }

    // MARK: - the three "is this really the same line" tests

    @Test func baselinesThreePointsApartAreDifferentLines() {
        // Measured against the line's *own* baseline, which is its first
        // run's and never moves — so drift accumulates against a fixed
        // point rather than against the previous run.
        func drifting(_ drift: Float) -> [PdfLayoutItem] {
            (0..<4).map { item(20 + Float($0) * 60, 700 - Float($0) * drift, 50) }
        }
        #expect(pdfGroupSingleColumn(drifting(0)).count == 1)
        #expect(pdfGroupSingleColumn(drifting(0.9)).count == 1)
        // A one-point drift is fine for two runs and breaks at the fourth,
        // where the total reaches three.
        #expect(pdfGroupSingleColumn(drifting(1)).count == 2)
        #expect(pdfGroupSingleColumn(drifting(3)).count == 4)
    }

    @Test func returningToTheLeftMarginStartsANewLine() {
        // Within the baseline tolerance but not identical, and back at the
        // line's own left margin: vertically stacked lines, not one line.
        let items = [item(20, 700, 50, "a"), item(21, 699, 50, "b")] + filler()
        #expect(pdfGroupSingleColumn(items).first?.items.count == 1)
        // Five points away is far enough to be an ordinary out-of-order run.
        let apart = [item(20, 700, 50, "a"), item(26, 699, 50, "b")] + filler()
        #expect(pdfGroupSingleColumn(apart).first?.items.count == 2)
    }

    @Test func startingLeftOfWhereTheLineReachedIsACarriageReturn() {
        // Ten points back from the last run's x, with a small baseline
        // change. Not the same as the margin test — the line may start well
        // to the right of this run.
        func back(_ amount: Float) -> [PdfLayoutItem] {
            [item(100, 700, 50, "a"), item(100 - amount, 699, 50, "b")] + filler()
        }
        #expect(pdfGroupSingleColumn(back(9)).first?.items.count == 2)
        #expect(pdfGroupSingleColumn(back(11)).first?.items.count == 1)
    }

    // MARK: - the wide-void prose split

    /// A line and an incoming run separated by `gap`, both reading as prose.
    private func void(
        gap: Float = 200, incoming: String? = nil, lineText: String? = nil,
        lineBold: Bool = false, itemBold: Bool = false, width: Float = 100, size: Float = 12
    ) -> [PdfLayoutItem] {
        [
            item(20, 700, width, lineText ?? prose, bold: lineBold, size: size),
            item(20 + width + gap, 700, 100, incoming ?? prose, bold: itemBold, size: size),
        ] + filler()
    }

    @Test func aWideVoidBetweenTwoRunsOfProseSplitsTheLine() {
        // The neighbouring column's body text sharing a baseline, in a
        // gutter too narrow for column detection to have found.
        #expect(pdfGroupSingleColumn(void(gap: 200)).first?.items.count == 1)
        #expect(pdfGroupSingleColumn(void(gap: 20)).first?.items.count == 2)
    }

    @Test func theVoidIsMeasuredAgainstFontSizeWithAThirtyPointFloor() {
        // Three times the larger font size, or 30pt, whichever is more — so
        // small type uses the floor and large type scales past it.
        #expect(pdfGroupSingleColumn(void(gap: 31, size: 6)).first?.items.count == 1)
        #expect(pdfGroupSingleColumn(void(gap: 29, size: 6)).first?.items.count == 2)
        #expect(pdfGroupSingleColumn(void(gap: 121, size: 40)).first?.items.count == 1)
        #expect(pdfGroupSingleColumn(void(gap: 119, size: 40)).first?.items.count == 2)
    }

    @Test func theIncomingRunMustStartWithALetter() {
        // This is what keeps a table of contents intact: its page numbers
        // and outline-numbered cells start with digits.
        #expect(pdfGroupSingleColumn(void(incoming: "42 is the answer here")).first?.items.count
            == 2)
        #expect(pdfGroupSingleColumn(void(incoming: prose)).first?.items.count == 1)
    }

    @Test func bothSidesMustReadAsProse() {
        // Three words *and* ten letters on the way in; two words and eight
        // on the line already. Word count alone is not enough — "abc def
        // ghi" is three words and nine letters, and stays joined.
        #expect(pdfGroupSingleColumn(void(incoming: "a b c")).first?.items.count == 2)
        #expect(pdfGroupSingleColumn(void(incoming: "abc def ghi")).first?.items.count == 2)
        #expect(pdfGroupSingleColumn(void(incoming: "abcd defg hij")).first?.items.count == 1)
        #expect(pdfGroupSingleColumn(void(lineText: "Name")).first?.items.count == 2)
        #expect(pdfGroupSingleColumn(void(lineText: "Name goes here")).first?.items.count == 1)
    }

    @Test func anUppercaseStartAlsoNeedsAStyleMismatch() {
        // A lowercase start is a mid-sentence continuation and splits on the
        // prose signals alone. An uppercase one might be a legend or a row
        // of labels, so it needs a bold heading beside regular text to
        // corroborate — otherwise same-styled rows would shatter.
        #expect(pdfGroupSingleColumn(void(incoming: upperProse)).first?.items.count == 2)
        let mismatched = void(incoming: upperProse, lineBold: true, itemBold: false)
        #expect(pdfGroupSingleColumn(mismatched).first?.items.count == 1)
        // Both bold is no mismatch.
        let matched = void(incoming: upperProse, lineBold: true, itemBold: true)
        #expect(pdfGroupSingleColumn(matched).first?.items.count == 2)
    }

    @Test func theWholeLineMustBeBoldNotJustItsLastRun() {
        // A bold-label-and-value row stays joined, because the line as a
        // whole is not a heading.
        var items = [
            item(20, 700, 40, "Label", bold: false),
            item(70, 700, 40, prose, bold: true),
            item(320, 700, 100, upperProse, bold: false),
        ]
        items += filler()
        #expect(pdfGroupSingleColumn(items).first?.items.count == 3)
    }

    @Test func anUnmeasuredWidthMakesTheVoidLookWider() {
        // The gap uses the raw width, not the estimate used elsewhere — so a
        // run with none is treated as a point and the void reads as wider.
        // Same geometry, opposite verdicts.
        #expect(pdfGroupSingleColumn(void(gap: 200, width: 0)).first?.items.count == 1)
        #expect(pdfGroupSingleColumn(void(gap: 0, width: 100)).first?.items.count == 2)
    }
}
