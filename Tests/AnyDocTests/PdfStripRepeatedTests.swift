import Testing

@testable import AnyDoc

/// Running headers and footers removed by frequency.
@Suite struct PdfStripRepeatedTests {
    private let header = "Annual Report of the Commission"
    private let footer = "Confidential Working Draft"

    private func line(_ text: String, page: Int, y: Float) -> PdfTextLine {
        PdfTextLine(
            items: [
                PdfLayoutItem(text: text, x: 20, y: y, width: 40, fontSize: 10, fontName: "F1")
            ], y: y, page: page)
    }

    /// A document of `pages` pages, each with a header, a footer, and body
    /// rows well clear of the margins.
    private func document(
        pages: Int, bodyRows: Int = 12, header: String? = nil, footer: String? = nil,
        headerY: Float = 800, headerOnPages: Range<Int>? = nil, headerDrift: Float = 0,
        pageOrder: [Int]? = nil
    ) -> [PdfTextLine] {
        var lines: [PdfTextLine] = []
        for page in pageOrder ?? Array(1...pages) {
            if let header, headerOnPages.map({ $0.contains(page) }) ?? true {
                lines.append(
                    line(header, page: page, y: headerY + (page % 2 == 0 ? headerDrift : 0)))
            }
            for row in 0..<bodyRows {
                lines.append(
                    line(
                        "body line \(row) on page \(page) with plenty of text", page: page,
                        y: 700 - Float(row) * 40))
            }
            if let footer { lines.append(line(footer, page: page, y: 40)) }
        }
        return lines
    }

    /// How many lines carrying `text` survive.
    private func survivors(_ lines: [PdfTextLine], _ text: String, pageCount: Int? = nil) -> Int {
        let pages = pageCount ?? Set(lines.map(\.page)).count
        return pdfStripRepeatedLines(lines, pageCount: pages)
            .filter { pdfLineText($0) == text }.count
    }

    @Test func nothingIsStrippedUnderThreePages() {
        // Two pages cannot establish a repeat.
        #expect(survivors(document(pages: 2, header: header), header) == 2)
        #expect(survivors(document(pages: 3, header: header), header) == 1)
    }

    @Test func theFrequencyBarIsThirtyPercentByIntegerDivision() {
        // Ten pages need three occurrences; twenty need six. The bar steps
        // rather than sliding, since the arithmetic is integer.
        #expect(survivors(document(pages: 10, header: header, headerOnPages: 1..<4), header) == 1)
        #expect(survivors(document(pages: 10, header: header, headerOnPages: 1..<3), header) == 2)
        #expect(survivors(document(pages: 20, header: header, headerOnPages: 1..<7), header) == 1)
        #expect(survivors(document(pages: 20, header: header, headerOnPages: 1..<6), header) == 5)
    }

    @Test func theFirstOccurrenceIsKept() {
        // A document title that also runs as a header still appears once.
        let stripped = pdfStripRepeatedLines(document(pages: 6, header: header), pageCount: 6)
        let kept = stripped.filter { pdfLineText($0) == header }
        #expect(kept.count == 1)
        #expect(kept.first?.page == 1)
    }

    @Test func aDriftingHeaderIsNotAHeader() {
        // Consistent placement is what separates a footer from a table cell
        // near the bottom margin. Small drift survives the variance test.
        #expect(survivors(document(pages: 6, header: header, headerDrift: 20), header) == 1)
        #expect(survivors(document(pages: 6, header: header, headerDrift: 100), header) == 6)
    }

    @Test func shortAndDecorativeTextsAreNeverCandidates() {
        // Under ten bytes once normalised, or a run of one character.
        for text in ["Page 1", "---------------", "aaaaaaaaaaaaaaa"] {
            #expect(survivors(document(pages: 6, header: text), text) == 6, "\(text)")
        }
        // The floor is measured *after* normalisation, so a line long enough
        // as written can still fall under it: `Report 2024` becomes `Report`,
        // six bytes, and survives.
        #expect(pdfNormalizeForComparison("Report 2024") == "Report")
        #expect(survivors(document(pages: 6, header: "Report 2024"), "Report 2024") == 6)
    }

    @Test func structuralLinesAreExempt() {
        // A heading or bullet is content, however often it repeats.
        for text in ["# Annual Report Heading", "- Annual Report Bullet"] {
            #expect(survivors(document(pages: 6, header: text), text) == 6, "\(text)")
        }
    }

    @Test func aNumberedHeadingLosesItsStructuralExemption() {
        // The exemption is tested against the *normalised* text, and
        // normalisation strips leading digits — so `1. Annual Report Section`
        // arrives as `. Annual Report Section`, which no longer looks
        // structural, and a repeated numbered heading is stripped where a
        // `#` or bullet one is not. The reference's bug, reproduced.
        #expect(pdfIsStructuralLine("1. Annual Report Section"))
        #expect(!pdfIsStructuralLine(pdfNormalizeForComparison("1. Annual Report Section")))
        let text = "1. Annual Report Section"
        #expect(survivors(document(pages: 6, header: text), text) == 1)
    }

    @Test func onlyLinesNearAPageEdgeAreConsidered() {
        // Mid-page on a full page, the repeat is body text and survives.
        #expect(survivors(document(pages: 6, header: header, headerY: 500), header) == 6)
    }

    @Test func aSparsePageIsEntirelyMargin() {
        // With ten or fewer distinct baselines every line counts as an edge,
        // so the same mid-page repeat is stripped after all.
        let sparse = document(pages: 6, bodyRows: 4, header: header, headerY: 500)
        #expect(survivors(sparse, header) == 1)
    }

    @Test func aSplitRowIsCaughtByItsCombinedText() {
        // Neither fragment is ten bytes on its own; the row is.
        var lines: [PdfTextLine] = []
        for page in 1...6 {
            lines.append(line("Column One", page: page, y: 800))
            lines.append(line("Column Two", page: page, y: 800))
            for row in 0..<12 {
                lines.append(
                    line(
                        "body line \(row) on page \(page) with plenty of text", page: page,
                        y: 700 - Float(row) * 40))
            }
        }
        #expect(survivors(lines, "Column One") == 1)
        #expect(survivors(lines, "Column Two") == 1)
    }

    @Test func removingOneBandMemberRemovesItsSiblings() {
        // The long fragment qualifies alone; the short one rides along
        // because it shares the baseline.
        var lines: [PdfTextLine] = []
        for page in 1...6 {
            lines.append(line("A Very Long Column Header Indeed", page: page, y: 800))
            lines.append(line("x", page: page, y: 800))
            for row in 0..<12 {
                lines.append(
                    line(
                        "body line \(row) on page \(page) with plenty of text", page: page,
                        y: 700 - Float(row) * 40))
            }
        }
        #expect(survivors(lines, "x") == 1)
    }

    @Test func theStripperDependsOnLinesArrivingInPageOrder() {
        // "Keep the first occurrence" means first in *array* order. The
        // reference records the page of whichever line it reaches first and
        // never revises it, so a document fed out of page order keeps every
        // copy on an earlier page as well...
        let shuffled = document(
            pages: 6, header: header, pageOrder: [3, 1, 2, 4, 5, 6])
        #expect(survivors(shuffled, header) == 3)
        // ...and one fed backwards strips nothing at all, because no page
        // ever exceeds the first one seen. Reproduced deliberately; the
        // layout stage emits pages in order, so this does not bite in the
        // pipeline.
        let reversed = document(pages: 6, header: header, pageOrder: [6, 5, 4, 3, 2, 1])
        #expect(survivors(reversed, header) == 6)
    }

    @Test func aDocumentWithNoRepeatsIsReturnedUnchanged() {
        let lines = document(pages: 6)
        #expect(pdfStripRepeatedLines(lines, pageCount: 6).count == lines.count)
        #expect(pdfStripRepeatedLines([], pageCount: 6).isEmpty)
    }
}
