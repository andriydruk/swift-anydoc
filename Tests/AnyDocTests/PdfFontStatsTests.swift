import Testing

@testable import AnyDoc

/// The font-size distribution everything else rests on.
@Suite struct PdfFontStatsTests {

    private func item(_ size: Float, _ text: String = "text") -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: 0, y: 0, width: 10, fontSize: size, fontName: "F1")
    }

    private func lines(_ sizes: [Float]) -> [PdfTextLine] {
        sizes.map { PdfTextLine(items: [item($0)], y: 0) }
    }

    // MARK: - the body size

    @Test func theBodySizeIsTheMostCommonOne() {
        let document = lines([Float](repeating: 10, count: 20) + [24] + [16, 16, 16])
        #expect(pdfFontStats(document).mostCommonSize == 10)
    }

    @Test func aTieGoesToTheSmallerSize() {
        // Deterministic output matters more than the choice itself.
        #expect(pdfFontStats(lines([10, 10, 12, 12])).mostCommonSize == 10)
        #expect(pdfFontStats(lines([12, 12, 10, 10])).mostCommonSize == 10)
    }

    @Test func nothingUnderNinePointsVotes() {
        // Footnotes and superscripts would otherwise claim the majority on a
        // densely annotated page.
        #expect(pdfFontStats(lines([Float](repeating: 8.5, count: 10) + [10, 10, 10]))
            .mostCommonSize == 10)
        // With nothing at all above the floor, the fallback is 12 — not zero,
        // which an earlier version of this port returned.
        #expect(pdfFontStats(lines([Float](repeating: 8, count: 10))).mostCommonSize == 12)
        #expect(pdfFontStats([]).mostCommonSize == 12)
        // Nine exactly is in.
        #expect(pdfFontStats(lines([9, 9, 9])).mostCommonSize == 9)
    }

    @Test func sizesAreBucketedByTruncationNotRounding() {
        // Tenths, truncated toward zero: 12.11 and 12.19 share a bucket, and
        // 12.2 does not. Rounding — which an earlier version of this port
        // used — would put 12.19 with 12.2 instead.
        let shared = pdfFontStats(lines([12.11, 12.11, 12.19]))
        #expect(shared.sizeCounts.count == 1)
        #expect(shared.mostCommonSize == 12.1)

        let split = pdfFontStats(lines([12.19, 12.19, 12.2]))
        #expect(split.sizeCounts.count == 2)
    }

    @Test func eachLineVotesOnceThroughItsFirstItem() {
        // A line of many runs counts as one, so a page of short captions
        // cannot outvote its body text by sheer run count.
        let heavy = PdfTextLine(
            items: (0..<20).map { _ in item(24, "caption") }, y: 0)
        let body = (0..<3).map { _ in PdfTextLine(items: [item(10)], y: 0) }
        #expect(pdfFontStats([heavy] + body).mostCommonSize == 10)
    }

    @Test func statsFromItemsCountEveryItem() {
        // Before grouping there are no lines to weight by, so each item votes
        // — which is the opposite bias, and deliberately so.
        let items = (0..<20).map { _ in item(24, "caption") } + (0..<3).map { _ in item(10) }
        #expect(pdfFontStatsFromItems(items).mostCommonSize == 24)
    }

    // MARK: - rarity

    @Test func rarityIsOneMinusTheFrequency() {
        let stats = pdfFontStats(lines([Float](repeating: 10, count: 99) + [24]))
        #expect(stats.totalLines == 100)
        #expect(abs(pdfFontSizeRarity(24, stats) - 0.99) < 0.0001)
        #expect(abs(pdfFontSizeRarity(10, stats) - 0.01) < 0.0001)
    }

    @Test func anUnseenSizeIsMaximallyRare() {
        let stats = pdfFontStats(lines([10, 10, 10]))
        #expect(pdfFontSizeRarity(30, stats) == 1)
    }

    @Test func anEmptyDocumentHasNoRarity() {
        // Zero rather than one, so nothing is treated as a heading on the
        // strength of a document with no text.
        #expect(pdfFontSizeRarity(24, pdfFontStats([])) == 0)
    }

    // MARK: - bold heading level

    @Test func aBoldHeadingSitsBelowEverySizeTier() {
        #expect(pdfBoldHeadingLevel([24, 16, 13]) == 4)
        #expect(pdfBoldHeadingLevel([24]) == 2)
    }

    @Test func theBoldLevelIsClampedBetweenTwoAndSix() {
        // H1 is reserved for titles, which are larger — so a bold heading
        // with no tiers at all is H2, not H1.
        #expect(pdfBoldHeadingLevel([]) == 2)
        // And it never goes past H6 however many tiers there are.
        #expect(pdfBoldHeadingLevel([Float](repeating: 12, count: 8)) == 6)
        #expect(pdfBoldHeadingLevel([Float](repeating: 12, count: 5)) == 6)
        #expect(pdfBoldHeadingLevel([Float](repeating: 12, count: 4)) == 5)
    }
}
