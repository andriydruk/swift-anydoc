import Testing

@testable import AnyDoc

/// Glyph-name resolution, pinned without the oracle.
@Suite struct PdfGlyphNamesTests {
    private func scalar(_ name: String) -> UInt32? { pdfGlyphToScalar(name)?.value }

    @Test func namesFromTheListResolve() {
        #expect(scalar("A") == 0x41)
        #expect(scalar("AE") == 0xC6)
        #expect(scalar("quotesingle") == 0x27)
        #expect(scalar("backslash") == 0x5C)
    }

    @Test func aDotSuffixNamesAVariantOfTheSameGlyph() {
        // `zero.tf` is still a zero, `a.ss01` still an `a`.
        #expect(scalar("zero.tf") == scalar("zero"))
        #expect(scalar("a.ss01") == scalar("a"))
        #expect(scalar("hyphen.case") == scalar("hyphen"))
    }

    @Test func aDotSuffixOnAnUnknownBaseStillFails() {
        #expect(scalar("notaglyph.tf") == nil)
        #expect(scalar(".notdef") == nil)
    }

    @Test func uniFormsTakeExactlyFourDigits() {
        #expect(scalar("uni0041") == 0x41)
        #expect(scalar("uni00E9") == 0xE9)
        // Anything past the four is ignored rather than rejected.
        #expect(scalar("uni0041FF") == 0x41)
        // Fewer than four is not the form at all.
        #expect(scalar("uni041") == nil)
        #expect(scalar("uniZZZZ") == nil)
    }

    @Test func theSymbolPrivateUseOffsetIsStripped() {
        // Windows Symbol fonts map their glyphs into the private-use area at
        // F000, so `uniF041` means `A` rather than a private glyph.
        #expect(scalar("uniF041") == 0x41)
        #expect(scalar("uniF000") == 0x00)
        #expect(scalar("uniF0FF") == 0xFF)
        // One past the range is left alone.
        #expect(scalar("uniF100") == 0xF100)
    }

    @Test func uFormsTakeTheWholeRemainder() {
        #expect(scalar("u0041") == 0x41)
        #expect(scalar("u1F600") == 0x1F600)
        #expect(scalar("u10FFFF") == 0x10FFFF)
        // So a suffix makes it fail, unlike the `uni` form.
        #expect(scalar("u0041.alt") == nil)
        // And four characters is too short to be tried.
        #expect(scalar("u041") == nil)
    }

    @Test func valuesThatAreNotScalarsYieldNothing() {
        // Surrogates and anything past the last plane.
        #expect(scalar("uniD800") == nil)
        #expect(scalar("uD800") == nil)
        #expect(scalar("u110000") == nil)
    }

    @Test func unrecognisedNamesYieldNothing() {
        #expect(scalar("") == nil)
        #expect(scalar("notaglyph") == nil)
        // The prefixes are case-sensitive.
        #expect(scalar("Uni0041") == nil)
        #expect(scalar("U0041") == nil)
    }

    @Test func theTableIsSortedAsTheSearchAssumes() {
        // A binary search over an unsorted table would fail silently on some
        // names and not others, so the ordering is asserted directly.
        #expect(pdfGlyphNames == pdfGlyphNames.sorted())
        #expect(pdfGlyphNames.count == pdfGlyphScalars.count)
    }
}
