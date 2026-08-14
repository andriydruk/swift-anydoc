import Testing

@testable import AnyDoc

/// What section numbering means, and the shapes it deliberately refuses.
@Suite struct PdfNumberingTests {

    // MARK: - roman_value

    @Test func ordinaryNumeralsRead() {
        #expect(pdfRomanValue("I") == 1)
        #expect(pdfRomanValue("IV") == 4)
        #expect(pdfRomanValue("IX") == 9)
        #expect(pdfRomanValue("XIV") == 14)
        #expect(pdfRomanValue("XL") == 40)
        #expect(pdfRomanValue("XC") == 90)
        #expect(pdfRomanValue("CXLV") == 145)
    }

    @Test func onlyFiveLettersAreNumerals() {
        // `D` and `M` are excluded: section numbering does not reach five
        // hundred, and admitting them would read `DOC` and `MIX` as numbers.
        #expect(pdfRomanValue("D") == nil)
        #expect(pdfRomanValue("M") == nil)
        #expect(pdfRomanValue("MMXX") == nil)
        // Lowercase is not accepted either.
        #expect(pdfRomanValue("iv") == nil)
    }

    @Test func eightCharactersIsTheCeiling() {
        #expect(pdfRomanValue("XXXXXXXX") != nil)
        #expect(pdfRomanValue("XXXXXXXXX") == nil)
        #expect(pdfRomanValue("") == nil)
    }

    @Test func subtractiveNotationIsLoose() {
        // Each character is subtracted only when the *next* one is larger,
        // so malformed numerals still produce a value rather than being
        // rejected. `IIX` is 1 - 1 + 10 = 10, not the 8 a strict reader
        // would refuse outright. Reproduced rather than corrected.
        #expect(pdfRomanValue("IIX") == 10)
        #expect(pdfRomanValue("IC") == 99)
        #expect(pdfRomanValue("VX") == 5)
    }

    // MARK: - parse_numbering

    @Test func aNumberedHeadingParses() {
        let one = pdfParseNumbering("1. Introduction")
        #expect(one?.kind == .decimal)
        #expect(one?.parts == [1])
        #expect(one?.depth == 1)

        let nested = pdfParseNumbering("2.1. Method")
        #expect(nested?.parts == [2, 1])
        #expect(nested?.depth == 2)
    }

    @Test func theNumberMustCarryADelimiter() {
        // A bare number is a page number or a quantity far more often than
        // it is a section.
        #expect(pdfParseNumbering("1 Introduction") == nil)
        #expect(pdfParseNumbering("1. Introduction") != nil)
        #expect(pdfParseNumbering("1) Introduction") != nil)
        #expect(pdfParseNumbering("1: Introduction") != nil)
    }

    @Test func everyTrailingDelimiterIsStripped() {
        #expect(pdfParseNumbering("1... Weird")?.parts == [1])
        #expect(pdfParseNumbering("1.).: Weird")?.parts == [1])
    }

    @Test func eachPartIsAtMostThreeDigits() {
        // A four-digit part fails the whole token rather than truncating it,
        // which is what keeps a year out of the numbering.
        #expect(pdfParseNumbering("999. Big")?.parts == [999])
        #expect(pdfParseNumbering("1000. Too big") == nil)
    }

    @Test func romanIsOnlyTheFallback() {
        // So `1.1` is decimal and `I.` is roman, and a mixed token is
        // neither.
        #expect(pdfParseNumbering("I. Roman")?.kind == .roman)
        #expect(pdfParseNumbering("I. Roman")?.parts == [1])
        #expect(pdfParseNumbering("IV) Roman")?.parts == [4])
        #expect(pdfParseNumbering("1.a. Mixed") == nil)
        #expect(pdfParseNumbering("a.1. Mixed") == nil)
    }

    @Test func romanNumberingIsAlwaysOneLevelDeep() {
        // There is no `IV.2`.
        #expect(pdfParseNumbering("IV. Roman")?.depth == 1)
    }

    @Test func aTokenOfOnlyDelimitersIsNotANumber() {
        #expect(pdfParseNumbering(".") == nil)
        #expect(pdfParseNumbering("...") == nil)
        #expect(pdfParseNumbering("") == nil)
    }

    // MARK: - has_additional_decimal_numbering

    @Test func aSecondDecimalNumberIsProseAboutTheDocument() {
        // `1. See section 2.3` references another section, so it is prose
        // rather than a heading.
        #expect(pdfHasAdditionalDecimalNumbering("1. See section 2.3 for details"))
        #expect(!pdfHasAdditionalDecimalNumbering("1. Introduction"))
    }

    @Test func theFirstWordIsAlwaysSkipped() {
        // Otherwise every numbered heading would look like it referenced one.
        #expect(!pdfHasAdditionalDecimalNumbering("2.1 Method"))
    }

    @Test func surroundingPunctuationIsTrimmed() {
        #expect(pdfHasAdditionalDecimalNumbering("1. (2.3)"))
        #expect(pdfHasAdditionalDecimalNumbering("1. 2.3,"))
    }

    @Test func aSingleNumberIsNotAReference() {
        // Two dot-separated parts are needed, so a year or a price is not
        // mistaken for one.
        #expect(!pdfHasAdditionalDecimalNumbering("1. In 2024 we"))
        #expect(!pdfHasAdditionalDecimalNumbering("1. Figure 2 shows"))
        #expect(pdfHasAdditionalDecimalNumbering("1. price 1.50 each"))
    }

    // MARK: - numbering_forms_hierarchy

    @Test func aParentAndChildFormAHierarchy() {
        #expect(pdfNumberingFormsHierarchy([1], [1, 1]))
        #expect(pdfNumberingFormsHierarchy([1, 1], [1]))
        #expect(pdfNumberingFormsHierarchy([1, 2], [1, 2, 3]))
    }

    @Test func siblingsAndEqualsDoNot() {
        #expect(!pdfNumberingFormsHierarchy([1], [2]))
        #expect(!pdfNumberingFormsHierarchy([1, 1], [1, 2]))
        // A number with itself is not a hierarchy, since the lengths match.
        #expect(!pdfNumberingFormsHierarchy([1], [1]))
    }

    @Test func anEmptyNumberingIsAPrefixOfAnything() {
        // Which follows from `starts(with:)` and is worth pinning.
        #expect(pdfNumberingFormsHierarchy([], [1]))
        #expect(!pdfNumberingFormsHierarchy([], []))
    }
}
