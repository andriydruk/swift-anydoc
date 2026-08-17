import Testing

@testable import AnyDoc

/// Stage 3, the rect-guided builder, pinned against the reference's **own**
/// unit tests — the eight in `tables/mod.rs` are ported here case for case,
/// including their geometry and their expectations.
///
/// That is worth doing where a probe cannot reach: the corpus does exercise
/// this stage (`rect-guided-calendar.pdf`, and dropping the stage costs that
/// file its byte-identical status), but one calendar cannot separate the
/// column floor from the fill floor from the tilde cleanup. The reference's
/// tests were each written for one of those, so they still discriminate.
@Suite struct PdfRectGuidedTableTests {
    /// The reference's `make_item`: width 10, height equal to the font size.
    private func item(_ text: String, _ x: Float, _ y: Float, _ fontSize: Float = 7)
        -> PdfLayoutItem
    {
        var built = PdfLayoutItem(
            text: text, x: x, y: y, width: 10, fontSize: fontSize, fontName: "F1")
        built.height = fontSize
        return built
    }

    /// Seven column positions 30pt apart, the reference's calendar geometry.
    private let columnXs: [Float] = (0..<7).map { 50 + Float($0) * 30 }

    private var clusterRects: [(x: Float, y: Float, width: Float, height: Float)] {
        columnXs.map { (x: $0, y: 100, width: 28, height: 15) }
    }

    @Test func sevenColumnsOfSingleDigitsBuildOneRow() {
        let items = (1...7).map { item("\($0)", columnXs[$0 - 1] + 2, 110) }
        let table = pdfBuildRectGuidedTable(items: items, clusterRects: clusterRects)
        #expect(table != nil)
        #expect(table?.columns.count == 7)
        #expect(table?.rows.count == 1)
        #expect(table?.cells[0] == ["1", "2", "3", "4", "5", "6", "7"])
    }

    @Test func aMergedRunIsSplitAcrossItsColumns() {
        var items = [
            item("1", columnXs[0] + 2, 110),
            item("2", columnXs[1] + 2, 110),
            item("3", columnXs[2] + 2, 110),
        ]
        var merged = item("4 5 6", columnXs[3], 110)
        merged.width = 3 * 30
        items.append(merged)

        let table = pdfBuildRectGuidedTable(items: items, clusterRects: clusterRects)
        #expect(table != nil)
        let row = table?.cells[0] ?? []
        #expect(row.contains("4"))
        #expect(row.contains("5"))
        #expect(row.contains("6"))
    }

    @Test func anAnnotationBelowTheDaysBecomesASecondRow() {
        var items = (1...7).map { item("\($0)", columnXs[$0 - 1] + 2, 115) }
        items.append(item("Holiday", columnXs[3] + 2, 105, 6))

        let table = pdfBuildRectGuidedTable(items: items, clusterRects: clusterRects)
        #expect(table?.rows.count == 2)
        #expect(table?.cells[1][3] == "Holiday")
    }

    @Test func fewerThanFiveColumnsIsRefused() {
        let rects: [(x: Float, y: Float, width: Float, height: Float)] = [
            (50, 100, 28, 15), (80, 100, 28, 15), (110, 100, 28, 15),
        ]
        let items = [item("A", 52, 110), item("B", 82, 110), item("C", 112, 110)]
        #expect(pdfBuildRectGuidedTable(items: items, clusterRects: rects) == nil)
    }

    @Test func aTildeLeaderTakesTheRestOfItsCell() {
        var items = (1...7).map { item("\($0)", columnXs[$0 - 1] + 2, 110) }
        items[6] = item("7 ~~~~~~~ Legend text here", columnXs[6] + 2, 110)

        let table = pdfBuildRectGuidedTable(items: items, clusterRects: clusterRects)
        #expect(table?.cells[0][6] == "7")
    }

    // ── split_merged_numbers ────────────────────────────────────────

    private let boundaries: [Float] = [50, 80, 110, 140, 170]

    @Test func aSingleTokenIsNotSplit() {
        let result = pdfSplitMergedNumbers(item("Holiday", 52, 110), columns: boundaries)
        #expect(result.count == 1)
        #expect(result.first?.text == "Holiday")
    }

    @Test func oneNumberAndAnAnnotationSplitInTwo() {
        var subject = item("11 Veterans Day", 110, 110)
        subject.width = 90
        let result = pdfSplitMergedNumbers(subject, columns: boundaries)
        #expect(result.count == 2)
        #expect(result.map(\.text) == ["11", "Veterans Day"])
    }

    @Test func twoNumbersAndAnAnnotationSplitInThree() {
        var subject = item("24 25 Memorial Day", columnXs[3], 110)
        subject.width = 4 * 30
        let result = pdfSplitMergedNumbers(subject, columns: columnXs)
        #expect(result.count == 3)
        #expect(result.map(\.text) == ["24", "25", "Memorial Day"])
    }

    @Test func wordsWithNoLeadingNumberAreLeftWhole() {
        let result = pdfSplitMergedNumbers(item("Memorial Day", 52, 110), columns: boundaries)
        #expect(result.count == 1)
        #expect(result.first?.text == "Memorial Day")
    }
}
