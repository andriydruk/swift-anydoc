import Testing

@testable import AnyDoc

/// The heading-tier and heading-level pair, including the three branches
/// wave 5's port left out and wave 72 restored.
@Suite struct PdfHeadingLevelTests {

    private func line(_ size: Float, bold: Bool = false, _ text: String = "Heading")
        -> PdfTextLine
    {
        var item = PdfLayoutItem(
            text: text, x: 0, y: 0, width: 10, fontSize: size, fontName: "F1")
        item.isBold = bold
        return PdfTextLine(items: [item], y: 0)
    }

    private let tiers: [Float] = [24, 16, 13]

    // MARK: - detect_header_level

    @Test func sizeAloneDecidesAboveTheGate() {
        #expect(pdfHeadingLevel(fontSize: 24, bodySize: 10, tiers: tiers) == 1)
        #expect(pdfHeadingLevel(fontSize: 16, bodySize: 10, tiers: tiers) == 2)
        #expect(pdfHeadingLevel(fontSize: 13, bodySize: 10, tiers: tiers) == 3)
        #expect(pdfHeadingLevel(fontSize: 11.9, bodySize: 10, tiers: tiers) == nil)
    }

    @Test func aBoldLineJustAboveBodySizeCanStillMatchATier() {
        // The sub-gate branch, missing before wave 72. Tiers below the 1.2
        // gate only exist because of the bold fallback in `pdfHeadingTiers`,
        // so honouring them for *non-bold* text at the same size would
        // promote every caption — hence the boldness requirement.
        // Note the tiers must be more than half a point apart to be
        // distinguishable: at [11, 10.6] a 10.6pt line matches the *11* tier
        // first, since 0.4 is inside the tolerance.
        let subGate: [Float] = [11.8, 11.0]
        #expect(pdfHeadingLevel(fontSize: 11.8, bodySize: 10, tiers: subGate, isBold: true) == 1)
        #expect(pdfHeadingLevel(fontSize: 11.0, bodySize: 10, tiers: subGate, isBold: true) == 2)
        #expect(pdfHeadingLevel(fontSize: 11.0, bodySize: 10, tiers: subGate, isBold: false) == nil)
        // And it needs tiers to match against.
        #expect(pdfHeadingLevel(fontSize: 11, bodySize: 10, tiers: [], isBold: true) == nil)
    }

    @Test func theSubGateWindowIsInclusiveBelowAndExclusiveAbove() {
        let subGate: [Float] = [10.4, 10.5, 11.9, 12.0]
        // 1.05 exactly is in; 1.2 exactly belongs to the ordinary path.
        #expect(pdfHeadingLevel(fontSize: 10.5, bodySize: 10, tiers: subGate, isBold: true) != nil)
        #expect(pdfHeadingLevel(fontSize: 10.4, bodySize: 10, tiers: subGate, isBold: true) == nil)
    }

    @Test func withNoTiersTheRatioDecidesAlone() {
        // The fallback, also missing before wave 72. Note it never returns
        // nothing: past the 1.2 gate with no tiers, everything is a heading.
        #expect(pdfHeadingLevel(fontSize: 25, bodySize: 10, tiers: []) == 1)
        #expect(pdfHeadingLevel(fontSize: 20, bodySize: 10, tiers: []) == 1)
        #expect(pdfHeadingLevel(fontSize: 19.9, bodySize: 10, tiers: []) == 2)
        #expect(pdfHeadingLevel(fontSize: 15, bodySize: 10, tiers: []) == 2)
        #expect(pdfHeadingLevel(fontSize: 14.9, bodySize: 10, tiers: []) == 3)
        #expect(pdfHeadingLevel(fontSize: 12.5, bodySize: 10, tiers: []) == 3)
        #expect(pdfHeadingLevel(fontSize: 12.4, bodySize: 10, tiers: []) == 4)
        #expect(pdfHeadingLevel(fontSize: 12, bodySize: 10, tiers: []) == 4)
        // Still nothing below the gate.
        #expect(pdfHeadingLevel(fontSize: 11.9, bodySize: 10, tiers: []) == nil)
    }

    @Test func aLargeSizeMatchingNoTierGoesAfterTheKnownOnes() {
        #expect(pdfHeadingLevel(fontSize: 40, bodySize: 10, tiers: [100]) == 2)
        #expect(pdfHeadingLevel(fontSize: 40, bodySize: 10, tiers: [100, 90]) == 3)
        // Capped at four however many tiers there are.
        #expect(pdfHeadingLevel(fontSize: 40, bodySize: 10, tiers: [100, 90, 80]) == 4)
        #expect(pdfHeadingLevel(fontSize: 40, bodySize: 10, tiers: [100, 90, 80, 70, 60]) == 4)
        // A modest size matching no tier is not a heading at all.
        #expect(pdfHeadingLevel(fontSize: 13, bodySize: 10, tiers: [100]) == nil)
    }

    @Test func tierToleranceIsHalfAPointExclusive() {
        // Inside the tolerance the tier decides.
        #expect(pdfHeadingLevel(fontSize: 16.4, bodySize: 10, tiers: tiers) == 2)
        // Exactly half a point away matches nothing — and since 1.65 clears
        // the 1.5 ratio, the line is placed *after* the known tiers rather
        // than rejected. A tenth of a point changes H2 into H4.
        #expect(pdfHeadingLevel(fontSize: 16.5, bodySize: 10, tiers: tiers) == 4)
    }

    @Test func aZeroBodySizeIsNotGuardedAgainst() {
        // The reference has no guard and relies on float division: the ratio
        // becomes infinite and the line is a heading. An earlier defensive
        // guard here was itself the divergence, and the probe found it.
        #expect(pdfHeadingLevel(fontSize: 12, bodySize: 0, tiers: tiers) == 4)
        #expect(pdfHeadingTiers([line(24)], bodySize: 0).count == 1)
    }

    // MARK: - compute_heading_tiers

    @Test func tiersAreTheDistinctHeadingSizesLargestFirst() {
        let tiers = pdfHeadingTiers(
            [line(24, "Title"), line(16, "Section"), line(10, "body text")], bodySize: 10)
        #expect(tiers == [24, 16])
    }

    @Test func sizesWithinHalfAPointAreOneTier() {
        let tiers = pdfHeadingTiers(
            [line(16.0), line(16.4), line(16.6), line(17.2)], bodySize: 10)
        #expect(tiers == [17.2, 16.6, 16])
    }

    @Test func digitOnlyLinesNeverDefineATier() {
        // A large bold folio would otherwise claim tier 0 and block the bold
        // fallback for the document's real same-size headings.
        #expect(pdfHeadingTiers([line(24, "7"), line(16, "Section")], bodySize: 10) == [16])
        // A line merely *containing* digits is fine.
        #expect(
            pdfHeadingTiers([line(24, "Chapter 7"), line(16, "Section")], bodySize: 10)
                == [24, 16])
    }

    @Test func atMostFourTiers() {
        let many = (0..<8).map { line(40 - Float($0) * 3) }
        #expect(pdfHeadingTiers(many, bodySize: 10).count == 4)
    }

    @Test func boldLinesJustAboveBodySizeSupplyTiersWhenNothingElseDoes() {
        // Books set section headings barely above body size — 11pt bold over
        // 10pt — and nothing clears the 1.2 gate. Without this fallback every
        // heading in such a document defaults to H2.
        #expect(pdfHeadingTiers([line(11, bold: true), line(10)], bodySize: 10) == [11])
        // Only bold lines, and only from 1.05 up.
        #expect(pdfHeadingTiers([line(11, bold: false), line(10)], bodySize: 10).isEmpty)
        #expect(pdfHeadingTiers([line(10.4, bold: true), line(10)], bodySize: 10).isEmpty)
        #expect(pdfHeadingTiers([line(10.5, bold: true), line(10)], bodySize: 10) == [10.5])
    }

    @Test func theFallbackAlsoSkipsDigitOnlyLines() {
        #expect(pdfHeadingTiers([line(11, bold: true, "7"), line(10)], bodySize: 10).isEmpty)
        #expect(
            pdfHeadingTiers(
                [line(11, bold: true, "7"), line(11, bold: true, "Real heading")], bodySize: 10)
                == [11])
    }

    @Test func theFallbackOnlyRunsWhenNoTierWasFound() {
        // A document with one real heading does not also collect its bold
        // body text as tiers.
        #expect(pdfHeadingTiers([line(24), line(11, bold: true)], bodySize: 10) == [24])
    }

    // MARK: - line_is_mostly_bold

    private func run(_ bold: Bool, _ text: String) -> PdfLayoutItem {
        var item = PdfLayoutItem(text: text, x: 0, y: 0, width: 10, fontSize: 12, fontName: "F1")
        item.isBold = bold
        return item
    }

    @Test func boldnessIsMeasuredByCharacterMass() {
        // Half the characters is the bar, and it is inclusive — so a heading
        // with an unbold section-number prefix still counts as bold.
        #expect(pdfLineIsMostlyBold(PdfTextLine(items: [run(true, "abcd"), run(false, "efgh")], y: 0)))
        #expect(
            !pdfLineIsMostlyBold(
                PdfTextLine(items: [run(true, "abcd"), run(false, "efghi")], y: 0)))
        #expect(
            pdfLineIsMostlyBold(
                PdfTextLine(items: [run(false, "4. "), run(true, "A bold section title")], y: 0)))
    }

    @Test func whitespaceIsTrimmedPerRunBeforeCounting() {
        // A run of spaces contributes nothing either way.
        #expect(pdfLineIsMostlyBold(PdfTextLine(items: [run(false, "      "), run(true, "ab")], y: 0)))
    }

    @Test func anEmptyLineIsNotBold() {
        #expect(!pdfLineIsMostlyBold(PdfTextLine(items: [], y: 0)))
        #expect(!pdfLineIsMostlyBold(PdfTextLine(items: [run(true, "   ")], y: 0)))
    }
}
