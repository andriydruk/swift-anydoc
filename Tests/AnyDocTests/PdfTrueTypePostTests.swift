import Testing

@testable import AnyDoc

/// The `post` table fallback.
///
/// `font-post-names.pdf` covers it end to end — without the fallback the
/// document extracts to nothing at all. These pin the format handling and
/// the precedence, neither of which one document can show.
@Suite struct PdfTrueTypePostTests {
    /// Build a `post` 2.0 table with the given glyph-name indices, plus the
    /// custom name strings that follow.
    private func postTable(indices: [UInt16], customNames: [String]) -> [UInt8] {
        var table: [UInt8] = []
        func be32(_ value: UInt32) {
            for shift in stride(from: 24, through: 0, by: -8) {
                table.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
            }
        }
        func be16(_ value: UInt16) {
            table.append(UInt8(truncatingIfNeeded: value >> 8))
            table.append(UInt8(truncatingIfNeeded: value))
        }
        be32(0x0002_0000)
        for _ in 0..<7 { be32(0) }  // italicAngle … maxMemType1, 28 bytes
        be16(UInt16(indices.count))
        for index in indices { be16(index) }
        for name in customNames {
            table.append(UInt8(name.utf8.count))
            table.append(contentsOf: Array(name.utf8))
        }
        return table
    }

    /// Wrap a table in a minimal sfnt container so the directory parser
    /// finds it.
    private func font(post: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let offset = UInt32(12 + 16)
        out.append(contentsOf: Array("post".utf8))
        for _ in 0..<4 { out.append(0) }  // checksum
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: offset >> UInt32(shift)))
        }
        let length = UInt32(post.count)
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: length >> UInt32(shift)))
        }
        out.append(contentsOf: post)
        return out
    }

    /// Indices below 258 name a glyph from the standard Macintosh ordering,
    /// which the font stores no strings for. Most Latin fonts use only
    /// these, so without the table their `post` is numbers meaning nothing.
    @Test func standardIndicesResolveThroughTheMacintoshOrder() {
        // 36 is "A", 37 "B", 3 "space", 0 ".notdef".
        let data = font(post: postTable(indices: [0, 36, 37, 3], customNames: []))
        let names = try! #require(pdfTrueTypeGlyphNames(data))
        #expect(names[0] == ".notdef")
        #expect(names[1] == "A")
        #expect(names[2] == "B")
        #expect(names[3] == "space")
    }

    /// Indices from 258 up name the strings that follow the array, in order.
    @Test func customIndicesResolveThroughTheStringList() {
        let data = font(
            post: postTable(indices: [0, 258, 259], customNames: ["exclam", "Alpha"]))
        let names = try! #require(pdfTrueTypeGlyphNames(data))
        #expect(names[1] == "exclam")
        #expect(names[2] == "Alpha")
    }

    /// The names become characters through the Adobe glyph list, and
    /// structural names like `.notdef` map to nothing rather than to a
    /// placeholder glyph.
    @Test func namesBecomeCharacters() {
        let data = font(post: postTable(indices: [0, 36, 258], customNames: ["exclam"]))
        let cmap = try! #require(pdfTrueTypeCMapFromGlyphNames(data))
        #expect(cmap.glyphToCharacter[1] == "A")
        #expect(cmap.glyphToCharacter[2] == "!")
        #expect(cmap.glyphToCharacter[0] == nil)
    }

    /// Format 3.0 declares outright that it carries no names — by far the
    /// most common case in modern fonts — and must yield nothing rather
    /// than a guess at the bytes that follow.
    @Test func formatThreeCarriesNoNames() {
        var table = postTable(indices: [0, 36], customNames: [])
        table[0] = 0x00
        table[1] = 0x03
        table[2] = 0x00
        table[3] = 0x00
        #expect(pdfTrueTypeGlyphNames(font(post: table)) == nil)
    }

    @Test func aFontWithNoPostTableYieldsNothing() {
        #expect(pdfTrueTypeGlyphNames([0x00, 0x01, 0x00, 0x00, 0x00, 0x00]) == nil)
    }

    /// A truncated table must not read past its own end.
    @Test func aTruncatedTableIsRefused() {
        var data = font(post: postTable(indices: [0, 36, 37], customNames: []))
        data.removeLast(4)
        // Either nothing, or only what genuinely fit — never a crash.
        _ = pdfTrueTypeGlyphNames(data)
    }
}
