import Testing

@testable import AnyDoc

/// Bold paragraphs that are not headings.
@Suite struct PdfWrappedBoldTests {

    private func line(
        _ y: Float, _ text: String = "a bold paragraph line carrying quite a few words indeed",
        x: Float = 20, size: Float = 10, bold: Bool = true, page: Int = 1
    ) -> PdfTextLine {
        var item = PdfLayoutItem(
            text: text, x: x, y: y, width: 40, fontSize: size, fontName: "F1")
        item.isBold = bold
        return PdfTextLine(items: [item], y: y, page: page)
    }

    // MARK: - starts_with_section_number (the convert.rs one)

    @Test func aSectionNumberNeedsTwoGroupsAndATitle() {
        #expect(pdfStartsWithSectionNumberAndTitle("9.5. Title Here"))
        #expect(pdfStartsWithSectionNumberAndTitle("9.5 Title Here"))
        // One group is an ordered list item.
        #expect(!pdfStartsWithSectionNumberAndTitle("1. Title Here"))
        // And a number with no title is not this shape.
        #expect(!pdfStartsWithSectionNumberAndTitle("1.2"))
    }

    @Test func itDiffersFromTheTableHeuristicOfTheSameName() {
        // `tables/detect_heuristic.rs` has its own `starts_with_section_number`
        // that asks only whether the first token is a dotted number. The two
        // disagree on a bare number, which is why both are ported.
        #expect(pdfStartsWithSectionNumber("1.2"))
        #expect(!pdfStartsWithSectionNumberAndTitle("1.2"))
    }

    @Test func eachGroupIsAtMostThreeDigits() {
        #expect(pdfStartsWithSectionNumberAndTitle("999.2. Fine Group"))
        #expect(!pdfStartsWithSectionNumberAndTitle("1000.2. Big Group"))
    }

    @Test func theTitleMustBeginWithALetter() {
        #expect(!pdfStartsWithSectionNumberAndTitle("1.2. 42 numbers"))
        #expect(!pdfStartsWithSectionNumberAndTitle("1.2. (bracket)"))
        #expect(pdfStartsWithSectionNumberAndTitle("1.2. Words"))
    }

    // MARK: - is_body_size_all_bold_line

    @Test func theSizeWindowIsNarrowAndHalfOpen() {
        // From 0.95 of the body up to but not including 1.2 — a genuinely
        // larger bold heading is left to the size heuristics.
        #expect(!pdfIsBodySizeAllBoldLine(line(700, size: 9.4), bodySize: 10))
        #expect(pdfIsBodySizeAllBoldLine(line(700, size: 9.5), bodySize: 10))
        #expect(pdfIsBodySizeAllBoldLine(line(700, size: 11.9), bodySize: 10))
        #expect(!pdfIsBodySizeAllBoldLine(line(700, size: 12), bodySize: 10))
    }

    @Test func everyRunMustBeBoldAndTheSameSize() {
        // A bold label beside a regular value is not a bold paragraph.
        var mixed = line(700)
        mixed.items.append(
            PdfLayoutItem(text: "plain", x: 80, y: 700, width: 40, fontSize: 10, fontName: "F1"))
        #expect(!pdfIsBodySizeAllBoldLine(mixed, bodySize: 10))

        var sized = line(700)
        var bigger = PdfLayoutItem(
            text: "bigger", x: 80, y: 700, width: 40, fontSize: 10.6, fontName: "F1")
        bigger.isBold = true
        sized.items.append(bigger)
        #expect(!pdfIsBodySizeAllBoldLine(sized, bodySize: 10))
    }

    @Test func anEmptyLineIsNotBold() {
        #expect(!pdfIsBodySizeAllBoldLine(PdfTextLine(items: [], y: 0), bodySize: 10))
    }

    // MARK: - is_wrapped_same_style_line

    @Test func aWrapIsADownwardGapWithinTheParagraphThreshold() {
        func pair(_ gap: Float) -> Bool {
            pdfIsWrappedSameStyleLine(line(700), line(700 - gap), paragraphThreshold: 20)
        }
        #expect(pair(14))
        #expect(pair(20))
        #expect(!pair(21))
        // Zero and upward gaps are not wraps.
        #expect(!pair(0))
        #expect(!pair(-10))
    }

    @Test func theLeftEdgesMustAgreeWithinFortyPoints() {
        // Which tolerates a first-line indent without admitting a column.
        func pair(_ dx: Float) -> Bool {
            pdfIsWrappedSameStyleLine(line(700), line(690, x: 20 + dx), paragraphThreshold: 20)
        }
        #expect(pair(40))
        #expect(!pair(41))
    }

    @Test func aPageBoundaryIsNeverAWrap() {
        #expect(
            !pdfIsWrappedSameStyleLine(
                line(700), line(690, page: 2), paragraphThreshold: 20))
    }

    // MARK: - find_wrapped_bold_paragraph_lines

    private func run(_ count: Int, gap: Float = 14, size: Float = 10, bold: Bool = true)
        -> [PdfTextLine]
    {
        (0..<count).map { line(700 - Float($0) * gap, size: size, bold: bold) }
    }

    @Test func threeLinesAndTwentyWordsMakeAParagraph() {
        // A bold heading may wrap once, and may be long, but not both.
        #expect(pdfFindWrappedBoldParagraphLines(run(2), bodySize: 10, paragraphThreshold: 20)
            .isEmpty)
        #expect(pdfFindWrappedBoldParagraphLines(run(3), bodySize: 10, paragraphThreshold: 20)
            == [0, 1, 2])
    }

    @Test func theWordCountIsAcrossTheWholeRun() {
        // Three lines of seven words is twenty-one and qualifies; of six is
        // eighteen and does not.
        let short = (0..<3).map { line(700 - Float($0) * 14, "one two three four five six") }
        let long = (0..<3).map {
            line(700 - Float($0) * 14, "one two three four five six seven")
        }
        #expect(pdfFindWrappedBoldParagraphLines(short, bodySize: 10, paragraphThreshold: 20)
            .isEmpty)
        #expect(!pdfFindWrappedBoldParagraphLines(long, bodySize: 10, paragraphThreshold: 20)
            .isEmpty)
    }

    @Test func aGapTooLargeBreaksTheRun() {
        #expect(!pdfFindWrappedBoldParagraphLines(
            run(4, gap: 20), bodySize: 10, paragraphThreshold: 20).isEmpty)
        #expect(pdfFindWrappedBoldParagraphLines(
            run(4, gap: 21), bodySize: 10, paragraphThreshold: 20).isEmpty)
    }

    @Test func onlyBoldBodySizeLinesCount() {
        #expect(pdfFindWrappedBoldParagraphLines(
            run(4, bold: false), bodySize: 10, paragraphThreshold: 20).isEmpty)
        #expect(pdfFindWrappedBoldParagraphLines(
            run(4, size: 14), bodySize: 10, paragraphThreshold: 20).isEmpty)
    }

    @Test func twoSeparateRunsAreBothFound() {
        var page = run(3)
        page.append(line(500, "plain break", bold: false))
        page += (0..<3).map { line(400 - Float($0) * 14) }
        let found = pdfFindWrappedBoldParagraphLines(
            page, bodySize: 10, paragraphThreshold: 20)
        #expect(found == [0, 1, 2, 4, 5, 6])
    }

    // MARK: - struct_role_heading_level

    @Test func taggedHeadingRolesMapToLevels() {
        // A generic `H` carries no depth of its own, so it becomes H1.
        #expect(pdfStructRoleHeadingLevel(.h) == 1)
        #expect(pdfStructRoleHeadingLevel(.h1) == 1)
        #expect(pdfStructRoleHeadingLevel(.h6) == 6)
        #expect(pdfStructRoleHeadingLevel(.p) == nil)
        #expect(pdfStructRoleHeadingLevel(.table) == nil)
    }
}
