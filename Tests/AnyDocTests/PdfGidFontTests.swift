// Fonts whose `/Differences` names raw glyph indices.
//
// The corpus covers the end-to-end behaviour; these pin the two pieces the
// corpus cannot show — the `/ToUnicode` rescue, and the fact that the
// suppression threshold is the *whole document* rather than the page.
import Testing

@testable import AnyDoc

@Suite struct PdfGidFontTests {
    /// One usable mapping is enough to rescue the font: a subset CMap that
    /// addresses these codes at all is addressing them.
    @Test func oneUsableMappingRescuesTheFont() {
        let cmap = parsePdfToUnicode(
            Array(
                """
                /CIDInit /ProcSet findresource begin
                12 dict begin
                begincmap
                1 begincodespacerange
                <00> <FF>
                endcodespacerange
                1 beginbfchar
                <41> <0041>
                endbfchar
                endcmap
                end
                end
                """.utf8))

        #expect(pdfToUnicodeMapsAnyCode(cmap, [0x41]))
        // Present but addressing none of them.
        #expect(!pdfToUnicodeMapsAnyCode(cmap, [0x42, 0x43]))
        // One hit among misses still counts.
        #expect(pdfToUnicodeMapsAnyCode(cmap, [0x42, 0x41]))
        // No CMap at all cannot rescue anything.
        #expect(!pdfToUnicodeMapsAnyCode(nil, [0x41]))
    }

    /// A mapping that yields nothing is not a mapping. Counting it would
    /// rescue a font on the strength of a rescue that produces no text.
    @Test func anUnusableMappingDoesNotRescue() {
        let cmap = parsePdfToUnicode(
            Array(
                """
                /CIDInit /ProcSet findresource begin
                12 dict begin
                begincmap
                1 begincodespacerange
                <00> <FF>
                endcodespacerange
                1 beginbfchar
                <41> <FFFD>
                endbfchar
                endcmap
                end
                end
                """.utf8))
        #expect(!pdfToUnicodeMapsAnyCode(cmap, [0x41]))
    }

    /// The name has to be `gid` followed by digits and nothing else — the
    /// boundary the corpus's `gid-name-nondigit` and `gid-name-bare` pin
    /// from the outside.
    @Test func onlyGidFollowedByDigitsCounts() {
        #expect(pdfIsGidGlyphName("gid65"))
        #expect(pdfIsGidGlyphName("gid00053"))
        #expect(pdfIsGidGlyphName("gid1"))
        #expect(!pdfIsGidGlyphName("gid"))
        #expect(!pdfIsGidGlyphName("gidXY"))
        #expect(!pdfIsGidGlyphName("gid65a"))
        #expect(!pdfIsGidGlyphName("Gid65"))
        #expect(!pdfIsGidGlyphName("g65"))
    }
}
