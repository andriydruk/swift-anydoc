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
