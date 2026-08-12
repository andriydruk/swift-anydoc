import Testing

@testable import AnyDoc

/// The text-anchor (booktabs) strategy, pinned without the oracle.
///
/// Most of the strategy is refusals, and most of the refusals exist to keep
/// multi-column prose from being read as a table — so most of these tests are
/// about what it declines.
@Suite struct PdfTextAnchorTableTests {
    private typealias Cell = (x: Float, width: Float, text: String)

    /// Uneven rules, which is what a booktabs table has. Evenly spaced ones
    /// are ruled paper and get rejected before anything else runs.
    private let booktabs = [
        PdfHorizontalRule(y: 700, xMin: 100, xMax: 500),
        PdfHorizontalRule(y: 680, xMin: 100, xMax: 500),
        PdfHorizontalRule(y: 560, xMin: 100, xMax: 500),
    ]

    private let header: [Cell] = [
        (110, 40, "Name"), (250, 40, "Count"), (390, 40, "Share"),
    ]

    private func build(
        header: [Cell], body: [[Cell]], rules: [PdfHorizontalRule]? = nil
    ) -> PdfTable? {
        var items = header.map {
            PdfLayoutItem(text: $0.text, x: $0.x, y: 690, width: $0.width, fontSize: 10,
                fontName: "F1")
        }
        for (index, row) in body.enumerated() {
            items += row.map {
                PdfLayoutItem(
                    text: $0.text, x: $0.x, y: 670 - Float(index) * 15, width: $0.width,
                    fontSize: 10, fontName: "F1")
            }
        }
        return pdfBuildTextAnchorTable(items: items, rules: rules ?? booktabs)
    }

    private var plainBody: [[Cell]] {
        [
            [(110, 40, "alpha"), (250, 20, "12"), (390, 20, "5%")],
            [(110, 40, "beta"), (250, 20, "34"), (390, 20, "9%")],
        ]
    }

    @Test func aBooktabsTableIsBuiltFromItsHeaderStarts() {
        let table = build(header: header, body: plainBody)
        #expect(table?.cells.first == ["Name", "Count", "Share"])
        #expect(table?.cells.count == 3)
        // Boundaries sit midway between anchors, with the rules' span outside.
        #expect(table?.columns == [100, 180, 320, 500])
    }

    @Test func evenlySpacedRulesAreRuledPaperNotATable() {
        let uniform = (0..<6).map {
            PdfHorizontalRule(y: 700 - Float($0) * 20, xMin: 100, xMax: 500)
        }
        #expect(build(header: header, body: plainBody, rules: uniform) == nil)
    }

    @Test func oneRuleIsNotEnough() {
        #expect(
            build(
                header: header, body: plainBody,
                rules: [PdfHorizontalRule(y: 700, xMin: 100, xMax: 500)]) == nil)
    }

    @Test func anchorsMustSpanThirtyPoints() {
        let tight: [Cell] = [(110, 10, "A"), (125, 10, "B")]
        let body: [[Cell]] = [
            [(110, 10, "a"), (125, 10, "b")], [(110, 10, "c"), (125, 10, "d")],
        ]
        #expect(build(header: tight, body: body) == nil)
    }

    @Test func aHeaderOfNothingButNumbersIsNotAHeader() {
        let numeric: [Cell] = [(110, 40, "12"), (250, 40, "34"), (390, 40, "56")]
        #expect(build(header: numeric, body: plainBody) == nil)
    }

    @Test func aMostlyNumericHeaderIsWeakEvidence() {
        // Two of three cells numeric: 2 × 2 > 3, refused. Years in a header
        // are exactly this shape, which is why it is a *majority* test.
        let years: [Cell] = [(110, 40, "Name"), (250, 40, "2024"), (390, 40, "2025")]
        #expect(build(header: years, body: plainBody) == nil)
    }

    @Test func aBodyStubLeftOfTheFirstAnchorProvesAColumnIsMissing() {
        var body = plainBody
        body[0].insert((80, 20, "stub"), at: 0)
        #expect(build(header: header, body: body) == nil)
    }

    @Test func twoRulesAreOnlyTrustedForAResponseForm() {
        let twoRules = [
            PdfHorizontalRule(y: 700, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 560, xMin: 100, xMax: 500),
        ]
        // An ordinary table on two rules is refused...
        #expect(build(header: header, body: plainBody, rules: twoRules) == nil)
        // ...but a response form is not: short prompts in the leading column,
        // the response column deliberately blank.
        let formHeader: [Cell] = [(110, 40, "Question"), (300, 40, "Answer")]
        let prompts: [[Cell]] = (0..<6).map { [(110, 60, "prompt \($0)")] }
        #expect(build(header: formHeader, body: prompts, rules: twoRules) != nil)
    }

    @Test func fourOrMoreRulesDescribeRowsNotABooktabsBand() {
        let dense = [
            PdfHorizontalRule(y: 700, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 680, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 640, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 560, xMin: 100, xMax: 500),
        ]
        #expect(build(header: header, body: plainBody, rules: dense) == nil)
    }

    @Test func aSpanUnderFiftyPointsIsRefused() {
        let narrow = [
            PdfHorizontalRule(y: 700, xMin: 100, xMax: 140),
            PdfHorizontalRule(y: 680, xMin: 100, xMax: 140),
            PdfHorizontalRule(y: 560, xMin: 100, xMax: 140),
        ]
        let tight: [Cell] = [(100, 8, "A"), (118, 8, "B"), (136, 8, "C")]
        let body: [[Cell]] = [
            [(100, 8, "a"), (118, 8, "b"), (136, 8, "c")],
            [(100, 8, "d"), (118, 8, "e"), (136, 8, "f")],
        ]
        #expect(build(header: tight, body: body, rules: narrow) == nil)
    }

    @Test func sustainedProseUnderSparseRulesIsRefused() {
        // Height alone is fine — what is rejected is many rows of
        // sentence-shaped cells. The items stay narrow so this is the gate
        // being tested rather than the wide-item one.
        let rules = [
            PdfHorizontalRule(y: 700, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 690, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 400, xMin: 100, xMax: 500),
        ]
        let prose: [[Cell]] = (0..<9).map { _ in
            [
                (110, 50, "alpha beta gamma delta"), (250, 50, "one two three four"),
                (390, 50, "five six seven eight"),
            ]
        }
        #expect(build(header: header, body: prose, rules: rules) == nil)
    }

    @Test func aLongTableOfShortValuesSurvivesTheSameHeight() {
        // The prose gate keys on content, not row count.
        let rules = [
            PdfHorizontalRule(y: 700, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 690, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 400, xMin: 100, xMax: 500),
        ]
        let short: [[Cell]] = (0..<9).map { index in
            [(110, 40, "r\(index)"), (250, 20, "\(index)"), (390, 20, "\(index)%")]
        }
        #expect(build(header: header, body: short, rules: rules) != nil)
    }

    @Test func itemsFillingMostOfTheirColumnsAreParagraphStarts() {
        let wide: [[Cell]] = (0..<4).map { _ in
            [(110, 130, "wide text here"), (250, 130, "also wide"), (390, 105, "wide again")]
        }
        #expect(build(header: header, body: wide) == nil)
    }

    @Test func oneExtremeCellRejectsTheTable() {
        var body = plainBody
        body[0][0] = (110, 40, String(repeating: "x", count: 250))
        #expect(build(header: header, body: body) == nil)
    }

    @Test func aConcentrationOfLongCellsRejectsTheTable() {
        // Two cells over 100 characters out of ten: 2 × 5 ≥ 10.
        var body = plainBody
        body[0][0] = (110, 40, String(repeating: "y", count: 120))
        body[1][0] = (110, 40, String(repeating: "z", count: 120))
        #expect(build(header: header, body: body) == nil)
    }
}
