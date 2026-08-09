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

/// Telling a contents listing from a data table. The probe covers 3,145
/// generated grids with all four classifier branches firing; these name the
/// signals and the cases each one has to reject.
@Suite struct PdfTableOfContentsTests {
    private let titles = [
        "Introduction To The Subject", "Materials And Methods", "Results",
        "Discussion Of Findings", "Conclusions", "Appendix A", "References",
        "Acknowledgements",
    ]

    /// Entries skip pages, so their range exceeds the entry count. That span
    /// is the strongest signal there is.
    @Test func aTitleAndPageColumnIsAListing() {
        let cells = (0..<8).map { [titles[$0 % titles.count], String(3 + $0 * 7)] }
        #expect(pdfIsPageNumberToc(cells))
        #expect(pdfIsTableOfContents(cells))
    }

    /// A perfectly dense consecutive run is a rank column, not page numbers —
    /// accepted only when the titles read like headings.
    @Test func denseRunsNeedHeadingLikeTitles() {
        let headings = (0..<8).map { [titles[$0 % titles.count], String(10 + $0)] }
        #expect(pdfIsPageNumberToc(headings))
        let ranks = (0..<8).map { ["Rank\($0)", String(10 + $0)] }
        #expect(!pdfIsPageNumberToc(ranks))
    }

    /// A two-column numeric grid with a header row is a data table: contents
    /// have no header, so their first row's last cell is already a page.
    @Test func aDataTableIsNotAListing() {
        var cells: [[String]] = [["Mineral", "CEC"]]
        cells += (0..<8).map { ["Mineral\($0)", String(100 + $0 * 3)] }
        #expect(!pdfIsPageNumberToc(cells))
    }

    @Test func frontMatterRomanNumeralsCount() {
        let cells = zip(titles, ["i", "ii", "iv", "vii", "ix", "xii"]).map { [$0, $1] }
        #expect(pdfIsPageNumberToc(cells))
    }

    @Test func explicitDotLeadersAreEnough() {
        let cells = (0..<5).map { ["Chapter \($0)", "........", String(3 + $0 * 4)] }
        #expect(pdfIsDotLeaderToc(cells))
    }

    /// A leader glued to its title also counts, but only after a space and a
    /// word — `etc...` and a `1973 ... ` data label must not.
    @Test func trailingLeadersNeedASpaceAndAWord() {
        #expect(pdfCellHasTrailingLeader("Introduction ..."))
        #expect(!pdfCellHasTrailingLeader("etc..."))
        #expect(!pdfCellHasTrailingLeader("1973 ..."))
    }

    /// Dotted section numbers with page numbers last, no leaders at all.
    @Test func dottedSectionNumbersMakeATabularListing() {
        let cells = (0..<9).map { ["\(1 + $0 / 3).\(1 + $0 % 3) Section", String(4 + $0 * 5)] }
        #expect(pdfIsTabularToc(cells))
        // With a non-numeric last column it is not one.
        let unnumbered = (0..<9).map { ["\(1 + $0 / 3).\(1 + $0 % 3) Section", "n/a"] }
        #expect(!pdfIsTabularToc(unnumbered))
    }

    @Test func sectionNumbersNeedAtLeastOneDot() {
        #expect(pdfStartsWithSectionNumber("1.2 Scope"))
        #expect(pdfStartsWithSectionNumber("4.3.1.2 Detail"))
        // A bare number is too ambiguous.
        #expect(!pdfStartsWithSectionNumber("1 Scope"))
    }

    /// A page list uses comma-*space*, which is what distinguishes it from a
    /// thousands separator.
    @Test func pageListsAreCommaSpaceSeparated() {
        #expect(pdfRowCellIsPageNumber("18, 36, 107"))
        #expect(!pdfRowCellIsPageNumber("189,164"))
        #expect(pdfRowCellIsPageNumber("A-1"))
    }

    /// A wide index whose cells each hold a whole entry renders badly either
    /// way, so it is flagged separately.
    @Test func inlineLeaderIndexesAreRecognised() {
        let cells = [
            ["alpha ... 12", "beta ... 34"],
            ["gamma ... 56", "delta ... 78"],
        ]
        #expect(pdfIsInlineLeaderIndex(cells))
        #expect(pdfCellIsInlineLeader("alpha ... 12"))
        #expect(pdfCellIsInlineLeader("... 12"))
        #expect(!pdfCellIsInlineLeader("etc... more words"))
    }

    /// The model classifies on construction, so rendering follows.
    @Test func theModelClassifiesItself() {
        let listing = PdfTable(cells: (0..<8).map { [titles[$0 % titles.count], String(3 + $0 * 7)] })
        #expect(listing.kind == .tableOfContents)
        #expect(pdfTableToMarkdown(listing).contains("\t"))

        let data = PdfTable(cells: [["A", "B"], ["x", "1"], ["y", "2"]])
        #expect(data.kind == .data)
        #expect(pdfTableToMarkdown(data).hasPrefix("|A|B|"))
    }
}
