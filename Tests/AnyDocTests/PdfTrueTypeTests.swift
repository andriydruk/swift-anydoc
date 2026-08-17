import Testing

@testable import AnyDoc

/// The `cmap` parser, against tables built byte by byte from the
/// OpenType specification's own layouts.
@Suite struct PdfTrueTypeTests {
    /// A font file: an offset table naming one table, then its bytes.
    private func font(tag: String, _ table: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x00, 0x01, 0x00, 0x00]  // sfnt version 1.0
        out += [0x00, 0x01]  // numTables
        out += [0, 0, 0, 0, 0, 0]  // searchRange, entrySelector, rangeShift
        out += Array(tag.utf8)
        out += [0, 0, 0, 0]  // checksum
        let offset = UInt32(out.count + 8)
        out += [
            UInt8(offset >> 24), UInt8((offset >> 16) & 0xFF), UInt8((offset >> 8) & 0xFF),
            UInt8(offset & 0xFF),
        ]
        let length = UInt32(table.count)
        out += [
            UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
        ]
        return out + table
    }

    private func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    private func be32(_ value: Int) -> [UInt8] {
        [
            UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    /// A `cmap` table wrapping one subtable, with the given platform.
    private func cmap(platform: Int, encoding: Int, _ subtable: [UInt8]) -> [UInt8] {
        var out = be16(0) + be16(1)  // version, numTables
        out += be16(platform) + be16(encoding) + be32(12)
        return out + subtable
    }

    @Test func formatZeroMapsBytesDirectly() {
        var subtable = be16(0) + be16(262) + be16(0)
        var glyphs = [UInt8](repeating: 0, count: 256)
        glyphs[65] = 5
        glyphs[66] = 6
        subtable += glyphs
        let parsed = pdfParseTrueTypeCMap(font(tag: "cmap", cmap(platform: 1, encoding: 0, subtable)))
        #expect(parsed?.characterToGlyph[65] == 5)
        #expect(parsed?.glyphToCharacter[5] == "A")
        #expect(parsed?.glyphToCharacter[6] == "B")
    }

    @Test func formatFourMapsBySegmentDelta() {
        // One segment covering 'A'…'C' with a delta, plus the required
        // terminating segment at 0xFFFF.
        let segments = 2
        var subtable = be16(4) + be16(32) + be16(0)
        subtable += be16(segments * 2) + be16(4) + be16(1) + be16(0)  // search hints
        subtable += be16(0x43) + be16(0xFFFF)  // endCode
        subtable += be16(0)  // reservedPad
        subtable += be16(0x41) + be16(0xFFFF)  // startCode
        // delta chosen so 0x41 maps to glyph 10.
        subtable += be16((10 - 0x41) & 0xFFFF) + be16(1)
        subtable += be16(0) + be16(0)  // idRangeOffset
        let parsed = pdfParseTrueTypeCMap(font(tag: "cmap", cmap(platform: 3, encoding: 1, subtable)))
        #expect(parsed?.characterToGlyph[0x41] == 10)
        #expect(parsed?.characterToGlyph[0x43] == 12)
        #expect(parsed?.glyphToCharacter[10] == "A")
        #expect(parsed?.glyphToCharacter[12] == "C")
    }

    @Test func formatSixMapsATrimmedRun() {
        var subtable = be16(6) + be16(0) + be16(0)
        subtable += be16(0x41) + be16(3)  // first, count
        subtable += be16(7) + be16(8) + be16(9)
        let parsed = pdfParseTrueTypeCMap(font(tag: "cmap", cmap(platform: 3, encoding: 1, subtable)))
        #expect(parsed?.characterToGlyph[0x41] == 7)
        #expect(parsed?.characterToGlyph[0x43] == 9)
        #expect(parsed?.glyphToCharacter[9] == "C")
    }

    @Test func formatTwelveReachesBeyondTheBasicPlane() {
        // The only format that can carry an emoji, which is why a font
        // limited to format 4 loses them.
        var subtable = be32(12 << 16) + be32(0) + be32(0)
        subtable += be32(1)  // numGroups
        subtable += be32(0x1F31F) + be32(0x1F31F) + be32(42)
        let parsed = pdfParseTrueTypeCMap(
            font(tag: "cmap", cmap(platform: 3, encoding: 10, subtable)))
        #expect(parsed?.glyphToCharacter[42] == "\u{1F31F}")
    }

    @Test func glyphZeroIsNeverMapped() {
        // Glyph 0 is `.notdef`. Mapping it would claim the font draws a
        // character it explicitly cannot.
        var subtable = be16(0) + be16(262) + be16(0)
        subtable += [UInt8](repeating: 0, count: 256)
        #expect(pdfParseTrueTypeCMap(font(tag: "cmap", cmap(platform: 1, encoding: 0, subtable)))
            == nil)
    }

    @Test func aFontWithNoCmapYieldsNothing() {
        #expect(pdfParseTrueTypeCMap(font(tag: "glyf", [1, 2, 3, 4])) == nil)
        #expect(pdfParseTrueTypeCMap([]) == nil)
        #expect(pdfParseTrueTypeCMap([0x00, 0x01, 0x00]) == nil)
    }

    @Test func aCorruptTableCountIsRefused() {
        // A header claiming thousands of tables is a crafted file, not a
        // font — walking it would read far past the end.
        var corrupt: [UInt8] = [0x00, 0x01, 0x00, 0x00]
        corrupt += be16(9999) + [0, 0, 0, 0, 0, 0]
        #expect(pdfTrueTypeTables(corrupt).isEmpty)
    }
}
