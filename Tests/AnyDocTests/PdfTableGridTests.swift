import Testing

@testable import AnyDoc

/// Table-grid geometry. The differential probe covers 2,500 generated
/// shapes; these name the decisions and pin the branch each one takes.
@Suite struct PdfTableGridTests {
    private func item(
        _ text: String, x: Float, y: Float, size: Float = 10, width: Float = 40
    ) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: size, fontName: "F1")
    }

    private func table(columns: [Float], rows: [Float], size: Float = 10) -> [PdfLayoutItem] {
        rows.flatMap { y in columns.map { x in item("c", x: x, y: y, size: size) } }
    }

    @Test func evenlySpacedColumnsAreFound() {
        let items = table(columns: [100, 200, 300], rows: [700, 685, 670])
        #expect(pdfFindColumnBoundaries(items) == [100, 200, 300])
    }

    @Test func rowsClusterByBaseline() {
        let items = table(columns: [100, 200], rows: [700, 685, 670])
        #expect(pdfFindRowBoundaries(items) == [700, 685, 670])
    }

    /// Rows cluster at four fifths of the median font size, so lines closer
    /// than that are one row.
    @Test func closeBaselinesAreOneRow() {
        let items = [
            item("a", x: 100, y: 700), item("b", x: 200, y: 700),
            item("c", x: 100, y: 695), item("d", x: 200, y: 695),
        ]
        #expect(pdfFindRowBoundaries(items).count == 1)
    }

    /// Prose piles up at the left margin. The body-font pass rejects a
    /// column holding more than three fifths of everything; the small-font
    /// pass does not.
    @Test func theBodyFontPassRejectsProse() {
        let items = (0..<12).map { line in
            item("line", x: 72, y: 700 - Float(line) * 14, width: 300)
        }
        #expect(pdfFindColumnBoundaries(items, mode: .bodyFont).isEmpty)
        #expect(!pdfFindColumnBoundaries(items, mode: .smallFont).isEmpty)
    }

    /// A column needs more than a stray item behind it.
    @Test func sparseColumnsAreDropped() {
        var items = table(columns: [100, 200, 300], rows: [700, 685, 670, 655])
        items.append(item("stray", x: 500, y: 640))
        #expect(!pdfFindColumnBoundaries(items).contains(500))
    }

    // MARK: cell assignment

    @Test func anXPositionFindsItsColumn() {
        let columns: [Float] = [100, 200, 300]
        #expect(pdfFindColumnIndex(columns, 102) == 0)
        #expect(pdfFindColumnIndex(columns, 198) == 1)
        // Half the tightest gap, floored at 25pt, so a position out in the
        // margin belongs to nothing.
        #expect(pdfFindColumnIndex(columns, 500) == nil)
    }

    @Test func aYPositionFindsItsRow() {
        let rows: [Float] = [700, 685, 670]
        #expect(pdfFindRowIndex(rows, 699) == 0)
        #expect(pdfFindRowIndex(rows, 671) == 2)
        #expect(pdfFindRowIndex(rows, 600) == nil)
    }

    // MARK: joining

    @Test func cellFragmentsJoinWithSpaces() {
        let items = [item("Total", x: 100, y: 700), item("cost", x: 140, y: 700)]
        #expect(pdfJoinCellItems(items) == "Total cost")
    }

    /// A hyphen binds what it joins, and a bracket binds what it encloses.
    @Test func punctuationBindsWithoutASpace() {
        #expect(
            pdfJoinCellItems([item("co-", x: 100, y: 700), item("operate", x: 120, y: 700)])
                == "co-operate")
        #expect(
            pdfJoinCellItems([
                item("(", x: 100, y: 700), item("note", x: 110, y: 700),
                item(")", x: 130, y: 700),
            ]) == "(note)")
    }

    /// A script binds to its token, in and out: smaller by more than fifteen
    /// percent together with a baseline shift.
    @Test func scriptsBindToTheirToken() {
        let items = [
            item("H", x: 100, y: 700), item("2", x: 110, y: 697, size: 6),
            item("O", x: 115, y: 700),
        ]
        #expect(pdfJoinCellItems(items) == "H2O")
    }

    @Test func numericTextIsRecognised() {
        for text in ["12", "3.50", "1,234.00", "-5", "+5%", "100"] {
            #expect(pdfIsNumericText(text), "\(text) should read as numeric")
        }
        for text in ["BIO", "Core Courses", "---", "", "a1"] {
            #expect(!pdfIsNumericText(text), "\(text) should not read as numeric")
        }
    }
}

/// The table path's own fragment merger, which is deliberately simpler than
/// the text path's.
@Suite struct PdfMergeAdjacentItemsTests {
    private func item(
        _ text: String, x: Float, y: Float = 700, size: Float = 10, width: Float
    ) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: size, fontName: "F1")
    }

    @Test func touchingFragmentsJoinAndRecordTheirSources() {
        let (merged, map) = pdfMergeAdjacentItems([
            item("Hel", x: 100, width: 15), item("lo", x: 115, width: 10),
        ])
        #expect(merged.map(\.text) == ["Hello"])
        #expect(map == [[0, 1]])
        #expect(merged[0].width == 25)
    }

    /// A visible gap is a word boundary; a column-sized one ends the run.
    @Test func gapsDecideSpacesAndBreaks() {
        let spaced = pdfMergeAdjacentItems([
            item("one", x: 100, width: 15), item("two", x: 117, width: 15),
        ])
        #expect(spaced.merged.map(\.text) == ["one two"])

        let split = pdfMergeAdjacentItems([
            item("left", x: 100, width: 15), item("right", x: 130, width: 15),
        ])
        #expect(split.merged.count == 2)
    }

    @Test func aSizeChangeEndsTheRun() {
        let (merged, _) = pdfMergeAdjacentItems([
            item("big", x: 100, width: 15), item("small", x: 115, size: 6, width: 10),
        ])
        #expect(merged.count == 2)
    }

    /// Unlike the text path, a style boundary does *not* break the run: a
    /// cell's styling is nothing to the grid.
    @Test func styleBoundariesDoNotBreakTheRun() {
        var bold = item("bold", x: 115, width: 10)
        bold.isBold = true
        let (merged, _) = pdfMergeAdjacentItems([item("plain", x: 100, width: 15), bold])
        #expect(merged.count == 1)
    }

    @Test func linesComeBackTopToBottom() {
        let (merged, _) = pdfMergeAdjacentItems([
            item("lower", x: 100, y: 600, width: 20),
            item("upper", x: 100, y: 700, width: 20),
        ])
        #expect(merged.map(\.text) == ["upper", "lower"])
    }
}

/// Where on the page a table might be. The two finders answer differently
/// because they are given different candidates.
@Suite struct PdfTableRegionTests {
    private func item(_ x: Float, _ y: Float) -> PdfLayoutItem {
        PdfLayoutItem(text: "x", x: x, y: y, width: 20, fontSize: 10, fontName: "F1")
    }

    /// The small-font finder is pure density: four or more baselines with no
    /// gap wider than 30pt, padded by 5.
    @Test func denseRunsBecomeRegions() {
        let items = (0..<5).map { item(100, 700 - Float($0) * 12) }
        let regions = pdfFindTableRegions(items)
        #expect(regions.count == 1)
        #expect(regions[0].yMin == 700 - 4 * 12 - 5)
        #expect(regions[0].yMax == 705)
    }

    @Test func aWideGapSplitsRegions() {
        var items = (0..<5).map { item(100, 700 - Float($0) * 12) }
        items += (0..<5).map { item(100, 500 - Float($0) * 12) }
        #expect(pdfFindTableRegions(items).count == 2)
    }

    @Test func tooFewBaselinesIsNoRegion() {
        #expect(pdfFindTableRegions((0..<3).map { item(100, 700 - Float($0) * 12) }).isEmpty)
    }

    /// The body-font finder needs structure: rows of two or more x clusters
    /// whose columns line up across rows.
    @Test func alignedColumnsBecomeStrictRegions() {
        let items = (0..<5).flatMap { row in
            [100, 250, 400].map { item(Float($0), 700 - Float(row) * 14) }
        }
        let regions = pdfFindTableRegionsStrict(items)
        #expect(regions.count == 1)
        #expect(regions[0].xMin == 85)
    }

    /// Paragraph text has one cluster per line, so no row qualifies.
    @Test func proseYieldsNoStrictRegion() {
        let items = (0..<8).map { item(72, 700 - Float($0) * 14) }
        #expect(pdfFindTableRegionsStrict(items).isEmpty)
    }

    /// Rows whose columns wander line to line are prose, not a table, even
    /// when each row has several clusters.
    @Test func misalignedColumnsAreRejected() {
        let offsets: [[Float]] = [
            [100, 260, 430], [140, 300, 470], [180, 340, 510],
            [220, 380, 550], [260, 420, 590],
        ]
        let items = offsets.enumerated().flatMap { row, xs in
            xs.map { item($0, 700 - Float(row) * 14) }
        }
        #expect(pdfFindTableRegionsStrict(items).isEmpty)
    }
}
