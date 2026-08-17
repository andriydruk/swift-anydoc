import Testing

@testable import AnyDoc

/// What decides which character a byte shows.
///
/// Three authorities, in order: the font's `ToUnicode` CMap, its
/// `/Differences` encoding, then the byte itself. Wave 108 found the middle
/// one ported but never consulted, so a re-encoded font read as whatever its
/// codes happened to spell.
@Suite struct PdfDecodePrecedenceTests {
    @Test func differencesMapCodesToTheirGlyphs() {
        let encoding = pdfParseEncodingDifferences([
            .integer(65), .name(Array("bullet".utf8)), .name(Array("emdash".utf8)),
        ])
        #expect(encoding.map[65] == "\u{2022}")
        // The code advances with each name, so 66 is the second glyph.
        #expect(encoding.map[66] == "\u{2014}")
    }

    @Test func aCodeOutsideTheDifferencesKeepsItsByte() {
        // Only the codes the array names are re-encoded; the rest stand for
        // themselves, which is what keeps ordinary ASCII readable.
        let encoding = pdfParseEncodingDifferences([.integer(65), .name(Array("bullet".utf8))])
        #expect(encoding.map[66] == nil)
    }

    @Test func aGlyphNamedByGlyphIdIsRecordedRatherThanMapped() {
        // `gidNNNNN` is an index into the embedded font's own tables and
        // means nothing without it. Mapping it would be silently wrong; the
        // code is recorded so a caller can tell the text is undecodable.
        let encoding = pdfParseEncodingDifferences([
            .integer(65), .name(Array("gid00042".utf8)),
        ])
        #expect(encoding.map[65] == nil)
        #expect(encoding.gidCodes.contains(65))
    }
}
