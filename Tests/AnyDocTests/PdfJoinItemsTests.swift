import Testing

@testable import AnyDoc

/// The join decision, pinned without the oracle.
@Suite struct PdfJoinItemsTests {
    /// Two items separated by `gap`, the first `width` wide.
    private func join(
        _ previousText: String, _ currentText: String, gap: Float = 2, threshold: Float = 0.10,
        width: Float = 20, size: Float = 10, font: String = "F1", currentX: Float? = nil
    ) -> Bool {
        let previous = PdfLayoutItem(
            text: previousText, x: 100, y: 700, width: width, fontSize: size, fontName: font)
        let current = PdfLayoutItem(
            text: currentText, x: currentX ?? (100 + width + gap), y: 700, width: 20,
            fontSize: size, fontName: "F1")
        return pdfShouldJoinItems(
            previous: previous, current: current, singleCharacterThreshold: threshold)
    }

    @Test func explicitSpacesAreRespected() {
        #expect(!join("word ", "next", gap: 0))
        #expect(!join("word", " next", gap: 0))
    }

    @Test func trailingPunctuationJoinsWhateverTheGap() {
        // `www` and `.com` are one word however they were positioned.
        for punctuation in [".com", ",x", ";x", "!x", "?x", ")x", "]x", "}x", "'x"] {
            #expect(join("www", punctuation, gap: 25))
        }
    }

    @Test func aColonBeforeAValueTakesASpace() {
        #expect(!join("Clave:", "T9N2I6", gap: 0))
        // Only before something alphanumeric.
        #expect(join("Clave:", "-x", gap: 0))
    }

    @Test func columnGapsAndLargeOverlapsNeverJoin() {
        #expect(!join("word", "next", gap: 31))
        #expect(!join("word", "next", gap: -11))
        #expect(join("word", "next", gap: -9))
    }

    @Test func aCidFontReadsAZeroGapAsASpace() {
        // The opposite of everywhere else: these emit one word per operator,
        // so touching items are separate words.
        #expect(!join("word", "next", gap: 0, font: "C2_0"))
        // A non-CID font at the same gap joins.
        #expect(join("word", "next", gap: 0, font: "F1"))
    }

    @Test func aCidPhraseIsAMidWordBoundaryInstead() {
        // Three words means the operator carried a whole phrase, so a zero
        // gap is inside a word rather than between two — the opposite verdict
        // from the one- or two-word case at the same gap.
        #expect(join("one two three", "next", gap: 0, font: "C2_0"))
        #expect(!join("one two", "next", gap: 0, font: "C2_0"))
        // Its `gap < font_size × 0.15` test can only ever be true: the branch
        // is already guarded on `gap < font_size × 0.01`. Pinned so a future
        // change to either constant shows up here.
        #expect(join("one two three", "next", gap: 0.09, font: "C2_0"))
    }

    @Test func cjkIsExemptFromTheCidRule() {
        #expect(join("\u{65E5}", "\u{672C}", gap: 0, font: "C2_0"))
    }

    @Test func numbersStayTogether() {
        #expect(join("34,20", "8", gap: 2))
        #expect(!join("34,20", "8", gap: 4))
        #expect(join("+13.", "0", gap: 2))
        #expect(join("13", "%", gap: 2))
    }

    @Test func aLetterSpacedPageJudgesAgainstCharacterWidth() {
        // The threshold is a multiple of the previous item's own width, not
        // of the font size.
        #expect(join("a", "b", gap: 5, threshold: 0.8, width: 5))
        #expect(!join("a", "b", gap: 7, threshold: 0.8, width: 5))
    }

    @Test func multiToSingleAveragesTheCharacterWidth() {
        // 15pt over three characters is 5pt each, so the bar is 6.25.
        #expect(join("abc", "d", gap: 5, threshold: 0.8, width: 15))
        #expect(!join("abc", "d", gap: 7, threshold: 0.8, width: 15))
    }

    @Test func aSplitWordFragmentIsGivenLatitude() {
        // `b` + `illion` at a fifth of the font size.
        #expect(join("b", "illion", gap: 1))
        #expect(!join("b", "illion", gap: 3))
    }

    @Test func twoSingleCharactersUseTheThreshold() {
        #expect(join("a", "b", gap: 0.5))
        #expect(!join("a", "b", gap: 2))
        // Digits get a looser bar, since a boundary between them is rarer.
        #expect(join("1", "2", gap: 2))
    }

    @Test func lowercaseJunctionsGetAWiderBar() {
        // Imprecise CID metrics otherwise split `enterta` + `inment`...
        #expect(join("enterta", "inment", gap: 1.7))
        #expect(!join("enterta", "inment", gap: 1.9))
        // ...while a capital on either side keeps the tighter one.
        #expect(join("LCOE", "WITH", gap: 1.4))
        #expect(!join("LCOE", "WITH", gap: 1.6))
    }

    // MARK: the fallback path

    @Test func sameCaseFragmentsJoinGenerously() {
        // No measured width, so the width is *estimated* — five characters at
        // 4.5pt each puts the previous item's end at 122.5, and the current
        // item's own x is what the gap is measured from.
        #expect(join("CONST", "ANCIA", width: 0, currentX: 124))
        #expect(!join("CONST", "ANCIA", width: 0, currentX: 127))
    }

    @Test func lowercaseToUppercaseIsAlwaysABoundary() {
        // Words do not change case mid-word, so distance does not matter.
        #expect(!join("presente", "CONSTANCIA", width: 0, currentX: 136.1))
    }

    @Test func uppercaseToLowercaseKeepsAThreshold() {
        // Eight characters put the estimated end at 136; the bar is 1.35.
        #expect(join("REGISTRO", "para", width: 0, currentX: 137))
        #expect(!join("REGISTRO", "para", width: 0, currentX: 138))
    }

    @Test func theFallbackAlsoRefusesColumnGaps() {
        #expect(!join("word", "next", width: 0, currentX: 150))
    }

    @Test func cjkJoinsOnProximityAloneInTheFallback() {
        #expect(join("\u{65E5}", "\u{672C}", width: 0, currentX: 106))
    }
}
