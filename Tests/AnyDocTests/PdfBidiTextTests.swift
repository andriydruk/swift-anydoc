import Testing

@testable import AnyDoc

/// Script classification and bidirectional text handling, pinned without the
/// oracle.
@Suite struct PdfBidiTextTests {
    private let arabic = "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}"  // marhaba
    private let hebrew = "\u{05E9}\u{05DC}\u{05D5}\u{05DD}"  // shalom

    // MARK: classification

    @Test func presentationFormsStopShortOfTheByteOrderMark() {
        // U+FEFF closes the Presentation Forms-B block but is the BOM, not a
        // glyph — so it is RTL by block and not a presentation form.
        #expect(pdfIsArabicPresentationForm("\u{FEFE}"))
        #expect(!pdfIsArabicPresentationForm("\u{FEFF}"))
        #expect(pdfIsRtlScalar("\u{FEFF}"))
    }

    @Test func blockBoundariesAreInclusive() {
        for scalar: Unicode.Scalar in ["\u{0590}", "\u{05FF}", "\u{0600}", "\u{06FF}"] {
            #expect(pdfIsRtlScalar(scalar))
        }
        #expect(!pdfIsRtlScalar("\u{058F}"))
        for scalar: Unicode.Scalar in ["\u{1100}", "\u{11FF}", "\u{4E00}", "\u{9FFF}"] {
            #expect(pdfIsCjkScalarValue(scalar))
        }
        #expect(!pdfIsCjkScalarValue("\u{10FF}"))
    }

    // MARK: direction

    @Test func aMajorityOfRightToLeftDecidesTheLine() {
        #expect(pdfIsRtlText([arabic]))
        #expect(!pdfIsRtlText(["plain latin text"]))
        // Five Arabic letters against three Latin ones.
        #expect(pdfIsRtlText([arabic + "abc"]))
        #expect(!pdfIsRtlText([arabic + "abcdef"]))
    }

    @Test func cjkCountsForNeitherSide() {
        // An Arabic line with a Japanese caption still reverses.
        #expect(pdfIsRtlText([arabic + "\u{65E5}\u{672C}\u{8A9E}"]))
        // And CJK alone is not left-to-right evidence either — but with no
        // RTL at all the answer is still false.
        #expect(!pdfIsRtlText(["\u{65E5}\u{672C}\u{8A9E}"]))
    }

    @Test func textWithNoRightToLeftNeverQualifies() {
        #expect(!pdfIsRtlText([""]))
        #expect(!pdfIsRtlText(["123 456"]))
    }

    @Test func directionIsDecidedAcrossTheWholeLine() {
        // The count is over every item, not each one separately — and it is a
        // strict majority, so five Arabic letters against five Latin ones is
        // *not* right-to-left.
        #expect(pdfIsRtlText(["ab", arabic, "c"]))
        #expect(!pdfIsRtlText(["abc", arabic, "de"]))
    }

    // MARK: reversal

    @Test func pureRightToLeftTextIsSimplyReversed() {
        #expect(pdfReverseVisualArabic(arabic) == String(arabic.reversed()))
        #expect(pdfReverseVisualArabic(hebrew) == String(hebrew.reversed()))
    }

    @Test func embeddedNumbersKeepTheirOwnDirection() {
        // The run order flips but the digits do not: `2024` must not become
        // `4202`.
        let reversed = pdfReverseVisualArabic(arabic + " 2024")
        #expect(reversed.contains("2024"))
        #expect(reversed.hasPrefix("2024"))
    }

    @Test func punctuationJoinsTheRunItTouches() {
        // The dot in `3.5` belongs with the digits...
        #expect(pdfReverseVisualArabic(arabic + " 3.5").contains("3.5"))
        // ...and the slash in `A/B` with the letters.
        #expect(pdfReverseVisualArabic(arabic + " A/B").contains("A/B"))
    }

    @Test func punctuationWithNoLatinNeighbourIsRightToLeft() {
        // A bare full stop next to Arabic is part of the Arabic run, so it
        // moves with it rather than anchoring an LTR run.
        let text = arabic + "!"
        #expect(pdfReverseVisualArabic(text) == String(text.reversed()))
    }

    @Test func anEmptyStringSurvivesReversal() {
        #expect(pdfReverseVisualArabic("") == "")
    }

    // MARK: text strings

    @Test func aByteOrderMarkSelectsUtf16() {
        let bytes: [UInt8] = [0xFE, 0xFF, 0x00, 0x41, 0x00, 0x42]
        #expect(pdfDecodeTextString(bytes) == "AB")
    }

    @Test func anOddTrailingByteAfterTheMarkIsDropped() {
        let bytes: [UInt8] = [0xFE, 0xFF, 0x00, 0x41, 0x00]
        #expect(pdfDecodeTextString(bytes) == "A")
    }

    @Test func withoutAMarkBytesAreLatinOne() {
        #expect(pdfDecodeTextString([0x41, 0x42, 0xE9]) == "AB\u{00E9}")
        #expect(pdfDecodeTextString([]) == "")
    }

    // MARK: small helpers

    @Test func theTextMatrixScalesTheFontSize() {
        // Both axes are vector magnitudes, so a rotated matrix still reports
        // its true scale.
        #expect(pdfEffectiveFontSize(baseSize: 10, textMatrix: [1, 0, 0, 1, 0, 0]) == 10)
        #expect(pdfEffectiveFontSize(baseSize: 10, textMatrix: [2, 0, 0, 2, 0, 0]) == 20)
        #expect(pdfEffectiveFontSize(baseSize: 10, textMatrix: [0, 1, -1, 0, 0, 0]) == 10)
        // The larger axis wins.
        #expect(pdfEffectiveFontSize(baseSize: 10, textMatrix: [1, 0, 0, 3, 0, 0]) == 30)
    }

    @Test func widthFallsBackToACharacterEstimate() {
        var item = PdfLayoutItem(text: "abcd", x: 0, y: 0, width: 12, fontSize: 10,
            fontName: "F1")
        #expect(pdfEffectiveItemWidth(item) == 12)
        item.width = 0
        #expect(pdfEffectiveItemWidth(item) == 20)
    }

    @Test func cidFontsAreNamedByPrefix() {
        #expect(pdfIsCidFontName("C2_0"))
        #expect(pdfIsCidFontName("C0_1"))
        #expect(!pdfIsCidFontName("C3_0"))
        #expect(!pdfIsCidFontName("Helvetica"))
    }
}
