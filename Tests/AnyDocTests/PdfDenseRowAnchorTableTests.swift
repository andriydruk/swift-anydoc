import Testing

@testable import AnyDoc

/// The dense-row anchor strategy, pinned without the oracle.
///
/// Unlike the text-anchor strategy it does not trust the first row: it takes
/// the widest schema any row exposes, then demands corroboration from two
/// rows and numbers in the body.
@Suite struct PdfDenseRowAnchorTableTests {
    /// Four rules at deliberately uneven spacing — 15, 30, 45 — so neither
    /// the uniform-grid test nor the uniform-run test fires.
    private let unevenRules = [
        PdfHorizontalRule(y: 700, xMin: 100, xMax: 500),
        PdfHorizontalRule(y: 685, xMin: 100, xMax: 500),
        PdfHorizontalRule(y: 655, xMin: 100, xMax: 500),
        PdfHorizontalRule(y: 610, xMin: 100, xMax: 500),
    ]

    private func build(
        rules: [PdfHorizontalRule]? = nil,
        verticals: [PdfVerticalRule] = [],
        header: [(Float, String)]? = nil,
        body: [[(Float, String)]]? = nil,
        width: Float = 40,
        rowGap: Float = 20
    ) -> PdfTable? {
        let header =
            header ?? [(Float(110), "Name"), (200, "Q1"), (300, "Q2"), (400, "Q3")]
        let body =
            body
            ?? [
                [(Float(110), "alpha"), (200, "10"), (300, "20"), (400, "30")],
                [(Float(110), "beta"), (200, "11"), (300, "21"), (400, "31")],
                [(Float(110), "gamma"), (200, "12"), (300, "22"), (400, "32")],
            ]
        var items = header.map {
            PdfLayoutItem(text: $0.1, x: $0.0, y: 690, width: width, fontSize: 10,
                fontName: "F1")
        }
        for (index, row) in body.enumerated() {
            items += row.map {
                PdfLayoutItem(
                    text: $0.1, x: $0.0, y: 670 - Float(index) * rowGap, width: width,
                    fontSize: 10, fontName: "F1")
            }
        }
        return pdfBuildDenseRowAnchorTable(
            items: items, horizontals: rules ?? unevenRules, verticals: verticals)
    }

    @Test func aNumericTableUnderUnevenRulesIsBuilt() {
        let table = build()
        #expect(table?.cells.first == ["Name", "Q1", "Q2", "Q3"])
        #expect(table?.cells.count == 4)
    }

    @Test func fewerThanFourRulesIsRefused() {
        #expect(build(rules: Array(unevenRules.prefix(3))) == nil)
    }

    @Test func evenlySpacedRulesAreRuledPaper() {
        let even = (0..<5).map {
            PdfHorizontalRule(y: 700 - Float($0) * 20, xMin: 100, xMax: 500)
        }
        #expect(build(rules: even) == nil)
    }

    @Test func fourEvenLevelsInsideAnUnevenBandStillCount() {
        // The band as a whole is uneven, but a run of four evenly spaced
        // levels anywhere inside it is enough.
        let mixed = [
            PdfHorizontalRule(y: 700, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 680, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 660, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 640, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 500, xMin: 100, xMax: 500),
        ]
        #expect(build(rules: mixed) == nil)
    }

    @Test func anOutlyingGapMeansTwoBandsNotOneTable() {
        // A page of stacked charts contributes one dense numeric row each,
        // and must not be merged into a synthetic page-wide table.
        let split = [
            PdfHorizontalRule(y: 700, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 685, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 655, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 200, xMin: 100, xMax: 500),
        ]
        #expect(build(rules: split) == nil)
    }

    @Test func twoVerticalStrokesInTheBandHandOverTheRegion() {
        #expect(
            build(verticals: [(x: 250, yMin: 610, yMax: 700), (x: 350, yMin: 610, yMax: 700)])
                == nil)
        // One is still allowed.
        #expect(build(verticals: [(x: 250, yMin: 610, yMax: 700)]) != nil)
    }

    @Test func atLeastTwoRulesMustCrossMostOfTheTable() {
        let short = [
            PdfHorizontalRule(y: 700, xMin: 100, xMax: 500),
            PdfHorizontalRule(y: 685, xMin: 100, xMax: 200),
            PdfHorizontalRule(y: 655, xMin: 100, xMax: 200),
            PdfHorizontalRule(y: 610, xMin: 100, xMax: 200),
        ]
        #expect(build(rules: short) == nil)
    }

    @Test func fewerThanFourAnchorsIsRefused() {
        #expect(
            build(
                header: [(110, "Name"), (200, "Q1"), (400, "Q2")],
                body: [
                    [(110, "alpha"), (200, "10"), (400, "30")],
                    [(110, "beta"), (200, "11"), (400, "31")],
                    [(110, "gamma"), (200, "12"), (400, "32")],
                ]) == nil)
    }

    @Test func anchorsMustSpanMostOfTheTable() {
        // Narrow items, deliberately: 40pt-wide ones spaced 40pt apart touch
        // within the join gap and collapse to a single anchor instead.
        #expect(
            build(
                header: [(110, "N"), (150, "A"), (190, "B"), (230, "C")],
                body: [
                    [(110, "a"), (150, "1"), (190, "2"), (230, "3")],
                    [(110, "b"), (150, "4"), (190, "5"), (230, "6")],
                    [(110, "c"), (150, "7"), (190, "8"), (230, "9")],
                ], width: 15) == nil)
    }

    @Test func oneDenseRowIsNotCorroboration() {
        // The header exposes the schema; every body row is a stub.
        #expect(build(body: [[(110, "alpha")], [(110, "beta")], [(110, "gamma")]]) == nil)
    }

    @Test func aBodyWithoutNumbersIsNotData() {
        #expect(
            build(body: [
                [(110, "alpha"), (200, "aa"), (300, "bb"), (400, "cc")],
                [(110, "beta"), (200, "dd"), (300, "ee"), (400, "ff")],
                [(110, "gamma"), (200, "gg"), (300, "hh"), (400, "ii")],
            ]) == nil)
    }

    @Test func numbersMustReachAQuarterOfTheFilledCells() {
        // Three numeric cells clears the floor but not the ratio: three of
        // sixteen filled body cells.
        #expect(
            build(body: [
                [(110, "alpha"), (200, "aa"), (300, "bb"), (400, "1")],
                [(110, "beta"), (200, "dd"), (300, "ee"), (400, "2")],
                [(110, "gamma"), (200, "gg"), (300, "hh"), (400, "3")],
                [(110, "delta"), (200, "jj"), (300, "kk"), (400, "ll")],
            ]) == nil)
    }

    @Test func moreRowsThanTheRuleLevelsCorroborateIsRefused() {
        // Eleven text rows against four rule levels. They have to sit inside
        // the band to be collected at all, hence the tight spacing.
        let many: [[(Float, String)]] = (0..<10).map { index in
            [
                (110, "r\(index)"), (200, "\(index)0"), (300, "\(index)1"),
                (400, "\(index)2"),
            ]
        }
        #expect(build(body: many, rowGap: 6) == nil)
    }
}
