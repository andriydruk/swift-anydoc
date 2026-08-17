import Testing

@testable import AnyDoc

/// The three passes every decoded string goes through.
///
/// The corpus proves each one separately — `decode-c1-controls.pdf`,
/// `decode-symbol-pua.pdf` and `decode-texcm-symbols.pdf` each stop matching
/// when the passes are removed. These pin the boundaries and, more
/// importantly, the *narrowness*: two of the three are corrections for
/// specific producer bugs, and a pass that fired too widely would corrupt
/// ordinary documents.
@Suite struct PdfDecodePostPassesTests {
    // MARK: - Windows-1252 C1 re-reading

    /// The whole C1 block, which is where smart punctuation lands when a
    /// producer writes Windows-1252 bytes into a `/ToUnicode` map.
    @Test func c1ControlsBecomePunctuation() {
        #expect(pdfNormaliseCp1252Controls("\u{0092}", useCp1252: true) == "\u{2019}")
        #expect(pdfNormaliseCp1252Controls("\u{0093}", useCp1252: true) == "\u{201C}")
        #expect(pdfNormaliseCp1252Controls("\u{0097}", useCp1252: true) == "\u{2014}")
    }

    /// Only for fonts that take the Windows-1252 reading. A TeX or symbol
    /// font puts real glyphs in that byte range, and rewriting them would
    /// turn ligatures into quotation marks.
    @Test func aSymbolFontKeepsItsC1Bytes() {
        #expect(pdfNormaliseCp1252Controls("\u{0092}", useCp1252: false) == "\u{0092}")
    }

    /// Everything outside C1 is untouched, so ordinary text costs nothing.
    @Test func ordinaryTextPassesThrough() {
        #expect(pdfNormaliseCp1252Controls("Hello, world.", useCp1252: true) == "Hello, world.")
    }

    // MARK: - Private-use area

    @Test func symbolPrivateUseCodesAreResolved() {
        // The offset is stripped for the printable range…
        #expect(pdfCleanSymbolPua("\u{F041}") == "A")
        // …and three codes are bullets in every such font, one a checkmark.
        #expect(pdfCleanSymbolPua("\u{F0A7}") == "\u{2022}")
        #expect(pdfCleanSymbolPua("\u{F0B7}") == "\u{2022}")
        #expect(pdfCleanSymbolPua("\u{F0FC}") == "\u{2713}")
    }

    /// Below 0x20 the offset would produce a control character, so the
    /// private-use codepoint is left as it is — a wrong glyph is better than
    /// an invisible one.
    @Test func lowPrivateUseCodesAreLeftAlone() {
        #expect(pdfCleanSymbolPua("\u{F010}") == "\u{F010}")
    }

    @Test func textWithoutPrivateUseIsUntouched() {
        #expect(pdfCleanSymbolPua("Ordinary text") == "Ordinary text")
    }

    // MARK: - TeXCMMathsSymbols

    /// The producer names its symbol glyphs after Latin lookalikes, so a
    /// faithful `/ToUnicode` reports the lookalike.
    @Test func texSymbolsAreRemapped() {
        let name = "ABCDEF+TeXCMMathsSymbols"
        #expect(pdfRemapTexCmMathSymbols("¼", baseFontName: name) == "=")
        #expect(pdfRemapTexCmMathSymbols("½", baseFontName: name) == "-")
        #expect(pdfRemapTexCmMathSymbols("þ", baseFontName: name) == "+")
        #expect(pdfRemapTexCmMathSymbols("ð", baseFontName: name) == "(")
        #expect(pdfRemapTexCmMathSymbols("Þ", baseFontName: name) == ")")
    }

    /// **Only** that font. This is the guard that matters: every other
    /// document writing a fraction must keep it, and a blanket substitution
    /// would silently corrupt them.
    @Test func everyOtherFontKeepsItsFractions() {
        #expect(pdfRemapTexCmMathSymbols("¼", baseFontName: "Helvetica") == "¼")
        #expect(pdfRemapTexCmMathSymbols("¼", baseFontName: nil) == "¼")
        #expect(pdfRemapTexCmMathSymbols("¼", baseFontName: "ABCDEF+Times") == "¼")
    }

    /// The subset tag is stripped at the *last* `+`, matching the
    /// reference's `rsplit_once`, and the comparison ignores case.
    @Test func theSubsetTagIsStrippedFromTheLastPlus() {
        #expect(pdfRemapTexCmMathSymbols("¼", baseFontName: "AAA+BBB+TeXCMMathsSymbols") == "=")
        #expect(pdfRemapTexCmMathSymbols("¼", baseFontName: "texcmmathssymbols") == "=")
    }
}
