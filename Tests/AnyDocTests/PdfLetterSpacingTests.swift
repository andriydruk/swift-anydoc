import Testing

@testable import AnyDoc

/// Letter-spacing repair, pinned without the oracle.
@Suite struct PdfLetterSpacingTests {
    private func item(_ text: String, x: Float, width: Float = 20, size: Float = 10)
        -> PdfLayoutItem
    {
        PdfLayoutItem(text: text, x: x, y: 700, width: width, fontSize: size, fontName: "F1")
    }

    /// One item per character at a fixed gap, which is Canva's second shape.
    private func perCharacter(_ text: String, gap: Float, count: Int? = nil)
        -> [PdfLayoutItem]
    {
        let characters = Array(text)
        let total = count ?? characters.count
        var items: [PdfLayoutItem] = []
        var x: Float = 100
        for index in 0..<total {
            items.append(
                item(String(characters[index % characters.count]), x: x, width: 5))
            x += 5 + gap
        }
        return items
    }

    // MARK: the pattern

    @Test func theAlternatingPatternIsRecognised() {
        #expect(pdfIsLetterspaced("a b"))
        #expect(pdfIsLetterspaced("a r i b"))
        #expect(!pdfIsLetterspaced("ab"))
        #expect(!pdfIsLetterspaced("ab cd"))
        // The text is trimmed first, so surrounding space does not break it.
        #expect(pdfIsLetterspaced(" a b "))
        // But an interior double space does.
        #expect(!pdfIsLetterspaced("a  b"))
        // Three characters minimum: "a b" is the shortest that can show it.
        #expect(!pdfIsLetterspaced("a"))
    }

    // MARK: repair

    @Test func spacesAreStrippedFromLetterspacedItems() {
        var items = [
            item("a r i b", x: 100, width: 40), item("t e x t", x: 150, width: 40),
            item("h e r e", x: 200, width: 40), item("a g a i n", x: 250, width: 50),
        ]
        _ = pdfFixLetterspacedItems(&items)
        #expect(items.map(\.text) == ["arib", "text", "here", "again"])
    }

    @Test func anOrdinaryPageIsLeftAlone() {
        var items = [
            item("ordinary", x: 100, width: 40), item("words", x: 150, width: 40),
            item("on", x: 200, width: 20), item("a page", x: 230, width: 40),
        ]
        let before = items.map(\.text)
        #expect(pdfFixLetterspacedItems(&items) == 0.10)
        #expect(items.map(\.text) == before)
    }

    @Test func aMinorityOfLetterspacedItemsIsNotEnough() {
        var items = [
            item("a r i b", x: 100, width: 40), item("ordinary", x: 150, width: 40),
            item("words", x: 200, width: 40), item("here", x: 250, width: 40),
        ]
        _ = pdfFixLetterspacedItems(&items)
        #expect(items[0].text == "a r i b")
    }

    @Test func fewerThanFourSubstantialItemsIsNotEnough() {
        var items = [item("a r i b", x: 100, width: 40), item("t e x t", x: 150, width: 40)]
        _ = pdfFixLetterspacedItems(&items)
        #expect(items[0].text == "a r i b")
    }

    // MARK: the per-character variant

    @Test func manySingleCharacterItemsRaiseTheThreshold() {
        // Nothing to rewrite here — the point is the threshold, since every
        // gap on the page is wide and the default would join nothing.
        var items = perCharacter("abcdefghijkl", gap: 8)
        let threshold = pdfFixLetterspacedItems(&items)
        #expect(threshold > 0.40)
        #expect(items.map(\.text).joined() == "abcdefghijkl")
    }

    @Test func tightlySpacedCharactersAreNotLetterspaced() {
        var items = perCharacter("abcdefghijkl", gap: 1)
        #expect(pdfFixLetterspacedItems(&items) == 0.10)
    }

    @Test func fewerThanTenItemsNeverTakeThatPath() {
        var items = perCharacter("abcdefgh", gap: 8)
        #expect(pdfFixLetterspacedItems(&items) == 0.10)
    }

    // MARK: the threshold

    @Test func theThresholdIsTheMedianRatioTimesOnePointFiveFive() {
        // A 5pt gap on a 10pt font is a ratio of 0.5, so 0.5 × 1.55 = 0.775.
        #expect(pdfCanvaJoinThreshold(perCharacter("a", gap: 5, count: 14)) == 0.775)
    }

    @Test func theUpperClampHolds() {
        // A 15pt gap gives 1.5 × 1.55 = 2.325, cut to 2.0.
        #expect(pdfCanvaJoinThreshold(perCharacter("a", gap: 15, count: 14)) == 2.0)
    }

    @Test func everyGapMustClearTheFloorNotJustTheMedian() {
        // One ordinary pair is enough to say the page is not uniformly
        // letter-spaced, which would otherwise glue real words together.
        var items = perCharacter("a", gap: 8, count: 14)
        items.append(item("x", x: items.last!.x + 6, width: 5))
        #expect(pdfCanvaJoinThreshold(items) == 0.10)
    }

    @Test func fewerThanEightSamplesFallsBackToTheDefault() {
        #expect(pdfCanvaJoinThreshold(perCharacter("a", gap: 8, count: 8)) == 0.10)
        #expect(pdfCanvaJoinThreshold(perCharacter("a", gap: 8, count: 9)) > 0.40)
    }

    // MARK: gap ratios

    @Test func cjkPairsAreSkipped() {
        // CJK is set without spaces, so its gaps say nothing about spacing.
        let cjk = (0..<12).map { item("\u{65E5}", x: 100 + Float($0) * 30) }
        #expect(pdfCollectGapRatios(cjk).isEmpty)
    }

    @Test func zeroWidthOrFontSizePairsAreSkipped() {
        #expect(pdfCollectGapRatios((0..<12).map { item("a", x: 100 + Float($0) * 30, width: 0) })
            .isEmpty)
        #expect(
            pdfCollectGapRatios((0..<12).map { item("a", x: 100 + Float($0) * 30, size: 0) })
                .isEmpty)
    }

    @Test func rightToLeftOrderingMeasuresTheGapTheOtherWay() {
        // Items running backwards contribute the same positive ratios.
        let leftToRight = (0..<12).map { item("a", x: 100 + Float($0) * 30, width: 20) }
        let rightToLeft = (0..<12).map { item("a", x: 400 - Float($0) * 30, width: 20) }
        #expect(pdfCollectGapRatios(leftToRight) == pdfCollectGapRatios(rightToLeft))
    }

    @Test func ratiosBeyondThreeAreColumnJumps() {
        let scattered = (0..<12).map { item("a", x: 100 + Float($0) * 200, width: 20) }
        #expect(pdfCollectGapRatios(scattered).isEmpty)
    }
}
