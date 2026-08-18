// Decoding a run through a CMap, and what happens to codes it does not cover.
//
// The asymmetry between one-byte and two-byte codes is the substance here,
// and the corpus can only show it end to end. These pin it directly.
import Testing

@testable import AnyDoc

private func cmap(_ body: String, codespace: String = "<00> <FF>") -> PdfToUnicodeCMap {
    parsePdfToUnicode(
        Array(
            """
            /CIDInit /ProcSet findresource begin
            12 dict begin
            begincmap
            1 begincodespacerange
            \(codespace)
            endcodespacerange
            \(body)
            endcmap
            end
            end
            """.utf8))
}

@Suite struct PdfCMapDecodeTests {
    /// An unmapped single-byte code falls back to Latin-1, so a partial
    /// `/ToUnicode` leaves the rest of the range readable.
    @Test func unmappedSingleByteCodesFallBackToLatin1() {
        let map = cmap("1 beginbfchar\n<41> <005A>\nendbfchar")
        #expect(map.codeByteLength == 1)
        // 0x41 is mapped to Z; 0x78 is not and comes back as x.
        #expect(pdfDecodeThroughCMap(map, [0x78, 0x41, 0x78]) == "xZx")
        // Latin-1, not StandardEncoding — which would make 0xE9 an Oslash —
        // and not Windows-1252, which would make 0x92 a curly quote.
        #expect(pdfDecodeThroughCMap(map, [0xE9]) == "\u{00E9}")
        #expect(pdfDecodeThroughCMap(map, [0x92]) == "\u{0092}")
    }

    /// Below 0x20 the byte is dropped rather than rendered as a control.
    @Test func unmappedControlBytesAreDropped() {
        let map = cmap("1 beginbfchar\n<41> <005A>\nendbfchar")
        #expect(pdfDecodeThroughCMap(map, [0x00, 0x41, 0x1F]) == "Z")
    }

    /// A two-byte code is a CID — a glyph index with no relation to Unicode —
    /// so an unmapped one contributes nothing. Rendering it would produce
    /// exactly the plausible CJK-looking nonsense the port guards against.
    @Test func unmappedTwoByteCodesAreDropped() {
        let map = cmap(
            "1 beginbfchar\n<0041> <005A>\nendbfchar", codespace: "<0000> <FFFF>")
        #expect(map.codeByteLength == 2)
        #expect(pdfDecodeThroughCMap(map, [0x00, 0x41]) == "Z")
        #expect(pdfDecodeThroughCMap(map, [0x00, 0x78]) == "")
        #expect(pdfDecodeThroughCMap(map, [0x00, 0x78, 0x00, 0x41]) == "Z")
    }

    /// A mapping to U+FFFD is the CMap admitting it does not know, and counts
    /// as no mapping — which for a single-byte code means Latin-1 answers
    /// instead.
    @Test func aReplacementCharacterMappingIsNotAMapping() {
        let single = cmap("1 beginbfchar\n<41> <FFFD>\nendbfchar")
        #expect(pdfDecodeThroughCMap(single, [0x41]) == "A")

        let double = cmap(
            "1 beginbfchar\n<0041> <FFFD>\nendbfchar", codespace: "<0000> <FFFF>")
        #expect(pdfDecodeThroughCMap(double, [0x00, 0x41]) == "")
    }
}
