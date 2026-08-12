import Testing

@testable import AnyDoc

/// Band scoping for the text-anchor strategy: which ruled regions are quiet
/// enough for anchors inferred from text alone to be trusted.
@Suite struct PdfTextAnchorBandsTests {
    private let rules = [
        PdfHorizontalRule(y: 700, xMin: 100, xMax: 500),
        PdfHorizontalRule(y: 680, xMin: 100, xMax: 500),
        PdfHorizontalRule(y: 560, xMin: 100, xMax: 500),
    ]

    /// A booktabs table that is accepted when nothing disqualifies its band.
    private var items: [PdfLayoutItem] {
        var items: [PdfLayoutItem] = []
        for (x, width, text) in [
            (Float(110), Float(40), "Name"), (250, 40, "Count"), (390, 40, "Share"),
        ] {
            items.append(
                PdfLayoutItem(text: text, x: x, y: 690, width: width, fontSize: 10,
                    fontName: "F1"))
        }
        for (row, values) in [["alpha", "12", "5%"], ["beta", "34", "9%"]].enumerated() {
            for (column, text) in values.enumerated() {
                items.append(
                    PdfLayoutItem(
                        text: text, x: 110 + Float(column) * 140, y: 670 - Float(row) * 15,
                        width: column == 0 ? 40 : 20, fontSize: 10, fontName: "F1"))
            }
        }
        return items
    }

    private func detect(verticals: [PdfVerticalRule] = [], paths: [PdfLineSegment] = [])
        -> [PdfTextAnchorBand]
    {
        pdfDetectTextAnchorRuleTables(
            items: items, horizontals: rules, verticals: verticals, pathLines: paths)
    }

    private func line(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) -> PdfLineSegment {
        PdfLineSegment(x1: x1, y1: y1, x2: x2, y2: y2, strokeWidth: 1)
    }

    @Test func aQuietBandYieldsATableAndItsBounds() {
        let bands = detect()
        #expect(bands.count == 1)
        #expect(bands.first?.xLeft == 100)
        #expect(bands.first?.xRight == 500)
        #expect(bands.first?.yBottom == 560)
        #expect(bands.first?.yTop == 700)
        #expect(bands.first?.table.cells.first == ["Name", "Count", "Share"])
    }

    @Test func twoSpanningVerticalsAreOuterBordersNotAGrid() {
        // A borderless table can still be boxed. Two coordinates prove
        // nothing about columns.
        let borders: [PdfVerticalRule] = [(x: 100, yMin: 560, yMax: 700), (x: 500, yMin: 560, yMax: 700)]
        #expect(detect(verticals: borders).count == 1)
    }

    @Test func aThirdSpanningVerticalIsAnInteriorDivider() {
        // That is a physical grid, and a detector that can read it should own
        // the region.
        let grid: [PdfVerticalRule] = [
            (x: 100, yMin: 560, yMax: 700), (x: 300, yMin: 560, yMax: 700),
            (x: 500, yMin: 560, yMax: 700),
        ]
        #expect(detect(verticals: grid).isEmpty)
    }

    @Test func sixShortStrokesInsideTheBandAreDiagramEvidence() {
        // None of them spans the band, so no single one proves a cell — but
        // together they are enough to hand the region over.
        let strokes = (0..<6).map { (x: 120 + Float($0) * 60, yMin: Float(600), yMax: Float(620)) }
        #expect(detect(verticals: strokes).isEmpty)
        #expect(detect(verticals: Array(strokes.dropLast())).count == 1)
    }

    @Test func strokesOutsideTheBandDoNotCount() {
        let elsewhere = (0..<6).map {
            (x: 600 + Float($0) * 20, yMin: Float(560), yMax: Float(700))
        }
        #expect(detect(verticals: elsewhere).count == 1)
    }

    @Test func twoHundredPathLinesMakeItLineArt() {
        let dense = (0..<200).map { index -> PdfLineSegment in
            let x = 110 + Float(index % 40)
            return line(x, 600, x + 20, 620)
        }
        #expect(detect(paths: dense).isEmpty)
        #expect(detect(paths: Array(dense.dropLast())).count == 1)
    }

    @Test func pathLinesOutsideTheBandDoNotCount() {
        let elsewhere = (0..<250).map { _ in line(110, 100, 130, 120) }
        #expect(detect(paths: elsewhere).count == 1)
    }

    @Test func bandOverlapIsTestedWithTheUsualTolerances() {
        let band = PdfTextAnchorBand(
            table: PdfTable(), xLeft: 100, xRight: 500, yBottom: 560, yTop: 700)
        #expect(pdfLineOverlapsTextAnchorBand(line(200, 600, 300, 620), band: band))
        // The left edge is loosened by the 6pt join gap: a line reaching
        // x=94 touches, one stopping at 93 does not.
        #expect(pdfLineOverlapsTextAnchorBand(line(80, 600, 94, 620), band: band))
        #expect(!pdfLineOverlapsTextAnchorBand(line(80, 600, 93, 620), band: band))
        // And the 2pt vertical slack.
        #expect(pdfLineOverlapsTextAnchorBand(line(200, 701, 300, 701), band: band))
        #expect(!pdfLineOverlapsTextAnchorBand(line(200, 703, 300, 720), band: band))
    }
}
