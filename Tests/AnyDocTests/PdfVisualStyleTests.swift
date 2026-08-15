import Testing

@testable import AnyDoc

/// A line's visual identity, and the three different tie-breaks behind it.
@Suite struct PdfVisualStyleTests {

    private func run(
        _ font: String, _ size: Float, bold: Bool = false, x: Float = 20, _ text: String
    ) -> PdfLayoutItem {
        var item = PdfLayoutItem(
            text: text, x: x, y: 0, width: 10, fontSize: size, fontName: font)
        item.isBold = bold
        return item
    }

    private func line(_ items: [PdfLayoutItem]) -> PdfTextLine {
        PdfTextLine(items: items, y: 0)
    }

    // MARK: - dominant font

    @Test func theFontMostCharactersAreSetIn() {
        let mixed = line([run("Body", 10, "short"), run("Bold", 10, "a much longer run here")])
        #expect(pdfDominantFont(mixed) == "Bold")
    }

    @Test func everyRunWeighsAtLeastOne() {
        // So a line of empty runs still has a dominant font rather than none.
        #expect(pdfDominantFont(line([run("Body", 10, ""), run("Other", 10, "")])) == "Body")
        #expect(pdfDominantFont(line([])) == nil)
    }

    @Test func aFontTieGoesToTheSmallerName() {
        let forward = line([run("Aaa", 10, "abcd"), run("Bbb", 10, "efgh")])
        let reversed = line([run("Bbb", 10, "abcd"), run("Aaa", 10, "efgh")])
        #expect(pdfDominantFont(forward) == "Aaa")
        #expect(pdfDominantFont(reversed) == "Aaa")
    }

    // MARK: - dominant font size

    @Test func aSmallSectionNumberDoesNotSetTheLineSize() {
        // Taking the first run's size would reject this heading outright.
        let numbered = line([run("Body", 8, "1."), run("Body", 16, "A Heading Title Here")])
        #expect(pdfDominantFontSize(numbered) == 16)
    }

    @Test func aSizeTieGoesToTheLargerSize() {
        // The opposite of every other vote here: between two equally
        // weighted sizes the heading is the bigger one.
        let forward = line([run("Body", 10, "abcd"), run("Body", 14, "efgh")])
        let reversed = line([run("Body", 14, "abcd"), run("Body", 10, "efgh")])
        #expect(pdfDominantFontSize(forward) == 14)
        #expect(pdfDominantFontSize(reversed) == 14)
    }

    @Test func sizesAreRoundedToATenth() {
        // Rounded, unlike the font statistics of wave 74, which truncate.
        #expect(pdfDominantFontSize(line([run("Body", 10.04, "a")])) == 10)
        #expect(pdfDominantFontSize(line([run("Body", 10.06, "a")])) == 10.1)
        #expect(pdfDominantFontSize(line([])) == nil)
    }

    // MARK: - document body font

    @Test func boldRunsDoNotVoteForTheBodyFont() {
        // The body is what is *not* emphasised, so a heavily headed document
        // cannot elect a heading font as its body.
        let document = [
            line([run("Bold", 10, bold: true, "a very long bold heading run here")]),
            line([run("Body", 10, "shorter")]),
        ]
        #expect(pdfDocumentBodyFont(document) == "Body")
        // With nothing unbold there is no answer at all.
        #expect(pdfDocumentBodyFont([line([run("Bold", 10, bold: true, "only bold")])]) == nil)
    }

    @Test func anEmptyRunContributesNothingToTheBodyVote() {
        // Unlike `pdfDominantFont`, where it weighs one — the two votes
        // differ deliberately.
        let document = [line([run("Body", 10, "")]), line([run("Other", 10, "abc")])]
        #expect(pdfDocumentBodyFont(document) == "Other")
        #expect(pdfDominantFont(line([run("Body", 10, ""), run("Other", 10, "abc")])) == "Other")
    }

    // MARK: - document body indent

    @Test func wholeLinesVoteForTheBodyIndent() {
        let document = [
            line([run("Body", 10, x: 20, "a long line of body text here")]),
            line([run("Body", 10, x: 20, "another long line of body")]),
            line([run("Body", 10, x: 100, "short")]),
        ]
        // 20 / 24 rounds to bucket 1.
        #expect(pdfDocumentBodyXBucket(document) == 1)
    }

    @Test func aMostlyBoldLineDoesNotVoteForTheIndent() {
        let document = [
            line([run("Body", 10, x: 20, "a long line of body text here")]),
            line([run("Body", 10, bold: true, x: 100, "an even longer bold line of text now")]),
        ]
        #expect(pdfDocumentBodyXBucket(document) == 1)
        #expect(pdfDocumentBodyXBucket([]) == nil)
    }

    @Test func indentsAreBucketedAtTwentyFourPoints() {
        func bucket(_ x: Float) -> Int? {
            pdfDocumentBodyXBucket([line([run("Body", 10, x: x, "some body text here")])])
        }
        #expect(bucket(0) == 0)
        #expect(bucket(11) == 0)
        #expect(bucket(13) == 1)
        #expect(bucket(36) == 2)
        #expect(bucket(240) == 10)
    }

    // MARK: - visual style

    @Test func theStyleCombinesFontIndentAndWeight() {
        let styled = line([
            run("Body", 10, bold: true, x: 36, "a bold line"),
            run("Body", 10, bold: true, x: 80, "continuing here"),
        ])
        let style = pdfVisualStyle(styled)
        #expect(style?.font == "Body")
        #expect(style?.xBucket == 2)
        #expect(style?.bold == true)
    }

    @Test func theIndentComesFromTheFirstRunNotTheDominantOne() {
        // Where a line starts is what the eye reads as its indent, however
        // its characters are distributed.
        let styled = line([
            run("Body", 10, x: 0, "a"),
            run("Body", 10, x: 200, "a very much longer run than the first"),
        ])
        #expect(pdfVisualStyle(styled)?.xBucket == 0)
    }

    @Test func aLineWithNoRunsHasNoStyle() {
        #expect(pdfVisualStyle(line([])) == nil)
    }
}
