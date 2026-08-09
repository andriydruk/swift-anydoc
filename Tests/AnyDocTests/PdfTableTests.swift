import Testing

@testable import AnyDoc

/// The table model and its rendering. The differential probe covers 2,500
/// generated grids; these name the decisions.
@Suite struct PdfTableTests {
    private func table(_ cells: [[String]], kind: PdfTableKind = .data) -> PdfTable {
        var made = PdfTable()
        made.cells = cells
        made.kind = kind
        return made
    }

    @Test func aDataTableRendersCompactly() {
        let markdown = pdfTableToMarkdown(
            table([["Item", "Qty"], ["Widget", "12"], ["Gadget", "7"]]))
        #expect(markdown == "|Item|Qty|\n|---|---|\n|Widget|12|\n|Gadget|7|\n")
    }

    @Test func anEmptyTableRendersToNothing() {
        #expect(pdfTableToMarkdown(table([])).isEmpty)
        #expect(pdfTableToMarkdown(table([[]])).isEmpty)
    }

    /// A wrapped cell arrives as a row with the first column empty, and folds
    /// back into the row above.
    @Test func continuationRowsMergeUpward() {
        let (cleaned, _) = pdfCleanTableCells([
            ["Item", "Qty", "Price"], ["Widget", "12", "3.50"], ["", "overflow", ""],
        ])
        #expect(cleaned.count == 2)
        #expect(cleaned[1] == ["Widget", "12 overflow", "3.50"])
    }

    /// One short value beside an empty first column is a sub-header, not
    /// overflow, so it keeps its own row.
    @Test func shortSubheadersAreNotContinuations() {
        let (cleaned, _) = pdfCleanTableCells([
            ["Month", "Val", "Pct"], ["Jan", "1", "2"], ["", "FEB", ""],
        ])
        #expect(cleaned.count == 3)
    }

    /// Several short numeric values are a data row with a spanned first
    /// column, not overflow.
    @Test func spannedFirstColumnRowsSurvive() {
        let (cleaned, _) = pdfCleanTableCells([
            ["A", "B", "C", "D"], ["x", "1", "2", "3"], ["", "4", "5", "6"],
        ])
        #expect(cleaned.count == 3)
    }

    @Test func footnoteRowsAreLiftedOut() {
        let (cleaned, footnotes) = pdfCleanTableCells([
            ["A", "B"], ["x", "1"], ["(1) a footnote", ""],
        ])
        #expect(cleaned.count == 2)
        #expect(footnotes == ["(1) a footnote"])
    }

    @Test func footnoteFormsAreRecognised() {
        for text in ["(1) note", "2) note", "Note: x", "Notes: x"] {
            #expect(pdfIsFootnoteRow(text), "\(text) should open a footnote row")
        }
        #expect(!pdfIsFootnoteRow("Widget"))
    }

    @Test func footnotesRenderBelowTheTable() {
        let markdown = pdfTableToMarkdown(table([["A", "B"], ["x", "1"], ["(1) see below", ""]]))
        #expect(markdown.hasSuffix("\n(1) see below\n"))
    }

    // MARK: contents listings

    /// A contents listing renders as flat lines, the page number separated by
    /// a tab so it stays beside its title.
    @Test func contentsListingsRenderAsLines() {
        let markdown = pdfTableToMarkdown(
            table(
                [["Introduction", "....", "3"], ["Methods", "....", "vii"]],
                kind: .tableOfContents))
        #expect(markdown == "Introduction\t3\nMethods\tvii\n")
    }

    @Test func pageNumberCellsAreRecognised() {
        for cell in ["3", "42", "vii", "ix", "5-21", "A-1", "TC-2", "86 86"] {
            #expect(pdfIsPageNumberCell(cell), "\(cell) should read as a page number")
        }
        for cell in ["12345", "Introduction", "", "iiii"] {
            #expect(!pdfIsPageNumberCell(cell), "\(cell) should not read as a page number")
        }
    }

    /// Roman numerals have to be canonical, so a value that does not round
    /// trip is rejected.
    @Test func romanNumeralsMustBeCanonical() {
        #expect(pdfCanonicalRomanValue("vii") == 7)
        #expect(pdfCanonicalRomanValue("ix") == 9)
        #expect(pdfCanonicalRomanValue("iiii") == nil)
        #expect(pdfCanonicalRomanValue("") == nil)
    }

    @Test func leaderDotsAreDroppedFromTitles() {
        #expect(pdfIsDotsOnly("...."))
        #expect(pdfIsDotsOnly(" . . . "))
        #expect(!pdfIsDotsOnly(".."))
        #expect(!pdfIsDotsOnly("a..."))
    }
}
