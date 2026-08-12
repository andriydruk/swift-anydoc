import Testing

@testable import AnyDoc

/// The stacked-token and open-edge grid strategies, pinned without the oracle.
@Suite struct PdfOpenEdgeGridTests {
    private func rule(_ y: Float, _ xMin: Float = 100, _ xMax: Float = 500)
        -> PdfHorizontalRule
    {
        PdfHorizontalRule(y: y, xMin: xMin, xMax: xMax)
    }

    private func item(_ text: String, _ x: Float, _ y: Float, width: Float = 60)
        -> PdfLayoutItem
    {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: 10, fontName: "F1")
    }

    // MARK: stacked tokens

    /// Three rules around six left-aligned single tokens carrying underscores.
    private func stackedItems(_ texts: [String], xOffsets: [Float] = []) -> [PdfLayoutItem] {
        texts.enumerated().map { index, text in
            let dx = index < xOffsets.count ? xOffsets[index] : 0
            return item(text, 120 + dx, 690 - Float(index) * 12, width: 80)
        }
    }

    private let threeRules = [
        PdfHorizontalRule(y: 700, xMin: 100, xMax: 400),
        PdfHorizontalRule(y: 600, xMin: 100, xMax: 400),
        PdfHorizontalRule(y: 500, xMin: 100, xMax: 400),
    ]

    private func stacked(_ items: [PdfLayoutItem], rules: [PdfHorizontalRule]? = nil)
        -> PdfTable?
    {
        let rules = rules ?? threeRules
        let rows = pdfCollectAnchoredRows(items: items, rules: rules)
        return pdfBuildStackedTokenTable(rows: rows, rules: rules)
    }

    @Test func aStackOfFormTokensBecomesALabelAndAValue() {
        let table = stacked(
            stackedItems(["Field_name", "a_1", "b_2", "c_3", "d_4", "e_5"]))
        #expect(table?.cells == [["Field_name", "a_1 b_2 c_3 d_4 e_5"]])
        // The split sits 35% along the rules' span: 100 + 0.35 × 300.
        #expect(table?.columns == [100, 205, 400])
        #expect(table?.rows == [690])
    }

    @Test func tokensWithoutUnderscoreOrColonAreNotFormFields() {
        #expect(stacked(stackedItems((0..<6).map { "plain\($0)" })) == nil)
    }

    @Test func colonsCountAsWellAsUnderscores() {
        #expect(stacked(stackedItems(["Label:", "a:1", "b:2", "c:3", "d:4"])) != nil)
    }

    @Test func theTokenRatioIsThreeQuarters() {
        // Four of five body rows qualify: 4×4 ≥ 5×3, accepted.
        #expect(stacked(stackedItems(["Head", "a_1", "b_2", "c_3", "plain"])) != nil)
        // Three of five: 3×4 < 5×3, refused by a single row.
        #expect(stacked(stackedItems(["Head", "a_1", "b_2", "plain", "plainer"])) == nil)
    }

    @Test func aRowOfTwoWordsSimplyDoesNotCount() {
        // It is not disqualifying on its own — the underscore is there, but
        // the row is two words, so it fails the *token* test and the ratio
        // has to be carried by the rest.
        #expect(
            stacked(stackedItems(["Head", "two words_x", "b_2", "c_3", "d_4", "e_5"])) != nil)
        // Two such rows out of five leaves 3×4 < 5×3, and the table is gone.
        #expect(
            stacked(stackedItems(["Head", "two words_x", "more words_y", "c_3", "d_4", "e_5"]))
                == nil)
    }

    @Test func fewerThanFiveRowsIsRefused() {
        #expect(stacked(stackedItems(["Head", "a_1", "b_2", "c_3"])) == nil)
    }

    @Test func rowsMustShareAStartWithinTheJoinGap() {
        let texts = (0..<6).map { "t_\($0)" }
        // 6pt off is inside the gap; 7pt is outside.
        #expect(stacked(stackedItems(texts, xOffsets: [0, 0, 0, 6, 0, 0])) != nil)
        #expect(stacked(stackedItems(texts, xOffsets: [0, 0, 0, 7, 0, 0])) == nil)
    }

    @Test func exactlyThreeRulesAreRequired() {
        let four = threeRules + [PdfHorizontalRule(y: 450, xMin: 100, xMax: 400)]
        #expect(stacked(stackedItems((0..<6).map { "t_\($0)" }), rules: four) == nil)
    }

    // MARK: open-edge grids

    /// A two-column grid: three rules, one interior vertical, a header above.
    private func openEdgeCase(headerTexts: [String] = ["H0", "H1"], vertical: Float = 300)
        -> (rules: [PdfHorizontalRule], verticals: [PdfVerticalRule], items: [PdfLayoutItem])
    {
        let rules = [rule(700), rule(680), rule(660)]
        let verticals: [PdfVerticalRule] = [(x: vertical, yMin: 660, yMax: 700)]
        var items: [PdfLayoutItem] = []
        for (index, text) in headerTexts.enumerated() {
            items.append(item(text, index == 0 ? 110 : 310, 712))
        }
        items += [
            item("a", 110, 690), item("b", 310, 690),
            item("c", 110, 670), item("d", 310, 670),
        ]
        return (rules, verticals, items)
    }

    @Test func aRuledBandWithAnInteriorVerticalBecomesAGrid() {
        let (rules, verticals, items) = openEdgeCase()
        let tables = pdfBuildOpenEdgeGridTables(
            items: items, horizontals: rules, verticals: verticals)
        #expect(tables.count == 1)
        #expect(tables.first?.columns == [100, 300, 500])
        #expect(tables.first?.cells.first == ["H0", "H1"])
        // The header's own baseline leads, then every row edge but the last.
        #expect(tables.first?.rows == [712, 700, 680])
    }

    @Test func aBandWithNoVerticalsIsNotAGrid() {
        let (rules, _, items) = openEdgeCase()
        #expect(
            pdfBuildOpenEdgeGridTables(items: items, horizontals: rules, verticals: []).isEmpty)
    }

    @Test func aVerticalTooShortToSpanTheBandIsNotAColumnEdge() {
        let (rules, _, items) = openEdgeCase()
        // 60% of the band's height, under the 80% required.
        let short: [PdfVerticalRule] = [(x: 300, yMin: 660, yMax: 684)]
        #expect(
            pdfBuildOpenEdgeGridTables(items: items, horizontals: rules, verticals: short)
                .isEmpty)
    }

    @Test func anUnlabelledFirstColumnIsAccepted() {
        // The stub case: the header names every column but the first.
        let (rules, verticals, items) = openEdgeCase(headerTexts: ["", "H1"])
        let live = items.filter { !$0.text.isEmpty }
        let tables = pdfBuildOpenEdgeGridTables(
            items: live, horizontals: rules, verticals: verticals)
        #expect(tables.count == 1)
        #expect(tables.first?.cells.first == ["", "H1"])
    }

    @Test func aHeaderMissingALaterCellIsRefused() {
        let (rules, verticals, items) = openEdgeCase(headerTexts: ["H0"])
        #expect(
            pdfBuildOpenEdgeGridTables(items: items, horizontals: rules, verticals: verticals)
                .isEmpty)
    }

    @Test func aBandTooNarrowIsRefused() {
        let narrow = [rule(700, 100, 180), rule(680, 100, 180), rule(660, 100, 180)]
        let verticals: [PdfVerticalRule] = [(x: 140, yMin: 660, yMax: 700)]
        let items = [
            item("H0", 105, 712, width: 20), item("H1", 145, 712, width: 20),
            item("a", 105, 690, width: 20), item("b", 145, 690, width: 20),
            item("c", 105, 670, width: 20), item("d", 145, 670, width: 20),
        ]
        #expect(
            pdfBuildOpenEdgeGridTables(items: items, horizontals: narrow, verticals: verticals)
                .isEmpty)
    }

    @Test func aColumnWithNoTextRejectsTheGrid() {
        // The outer edges are inferred from the rules, so an empty column
        // means those edges are wrong rather than that the cell is blank.
        let rules = [rule(700), rule(680), rule(660)]
        let verticals: [PdfVerticalRule] = [
            (x: 233, yMin: 660, yMax: 700), (x: 366, yMin: 660, yMax: 700),
        ]
        let items = [
            item("H0", 110, 712), item("H1", 243, 712), item("H2", 376, 712),
            item("a", 110, 690), item("c", 376, 690),
            item("d", 110, 670), item("f", 376, 670),
        ]
        #expect(
            pdfBuildOpenEdgeGridTables(items: items, horizontals: rules, verticals: verticals)
                .isEmpty)
    }
}
