/// Enough of the TrueType/OpenType container to recover text from a font
/// that carries no `/ToUnicode`.
///
/// The reference gets this from `ttf-parser`. This port has no dependency to
/// get it from, so the parts it needs are written out: the table directory,
/// and the `cmap` table's four common subtable formats.
///
/// **Why it matters.** A producer that subsets a font often omits
/// `/ToUnicode`, on the grounds that the font itself already says which
/// character each glyph draws. Without reading the font, such a document
/// extracts as the raw byte codes — confident, well-shaped nonsense. The
/// font's own `cmap` is the authority that recovers it.
///
/// Only what the extraction path needs is parsed. Glyph outlines, hinting,
/// kerning and layout tables are skipped entirely.

/// A font's character-to-glyph mapping, inverted.
struct PdfTrueTypeCMap: Equatable {
    /// Glyph id to the character it draws.
    var glyphToCharacter: [UInt16: Unicode.Scalar] = [:]
    /// Character code to glyph id, as the font's own table gives it — which
    /// a simple font needs, because its byte codes are *not* glyph ids.
    var characterToGlyph: [UInt32: UInt16] = [:]

    var isEmpty: Bool { glyphToCharacter.isEmpty }

    static func == (a: Self, b: Self) -> Bool {
        a.glyphToCharacter == b.glyphToCharacter && a.characterToGlyph == b.characterToGlyph
    }
}

/// Read a big-endian integer from `data` at `offset`.
private func pdfReadUInt16(_ data: [UInt8], _ offset: Int) -> UInt16? {
    guard offset >= 0, offset + 1 < data.count else { return nil }
    return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
}

private func pdfReadUInt32(_ data: [UInt8], _ offset: Int) -> UInt32? {
    guard offset >= 0, offset + 3 < data.count else { return nil }
    return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
        | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
}

/// The byte ranges of a font's tables, by their four-character tags.
///
/// A TrueType Collection (`ttcf`) names several fonts; the reference asks
/// for face zero, so this follows the first offset table.
func pdfTrueTypeTables(_ data: [UInt8]) -> [String: Range<Int>] {
    var base = 0
    if data.count >= 16, Array(data[0..<4]) == Array("ttcf".utf8) {
        guard let first = pdfReadUInt32(data, 12) else { return [:] }
        base = Int(first)
    }
    guard let tableCount = pdfReadUInt16(data, base + 4) else { return [:] }
    // A plausible font has a few dozen tables; a corrupt header can claim
    // thousands and walk off the end.
    guard tableCount <= 512 else { return [:] }

    var tables: [String: Range<Int>] = [:]
    for index in 0..<Int(tableCount) {
        let entry = base + 12 + index * 16
        guard entry + 16 <= data.count, let offset = pdfReadUInt32(data, entry + 8),
            let length = pdfReadUInt32(data, entry + 12)
        else { break }
        let start = Int(offset)
        let end = start + Int(length)
        // A table claiming to run past the file is truncated to it rather
        // than dropped: real fonts in the wild overstate their last table.
        guard start >= 0, start < data.count else { continue }
        let tag = String(decoding: data[entry..<(entry + 4)], as: UTF8.self)
        tables[tag] = start..<min(end, data.count)
    }
    return tables
}

/// Parse a font's `cmap`, preferring the subtable that maps most usefully.
///
/// Subtable preference is the reference's: a Windows Unicode table if there
/// is one, otherwise Macintosh Roman, otherwise whatever is first. A simple
/// font's byte codes come through Macintosh Roman; a CID font's glyph ids
/// come through Windows.
func pdfParseTrueTypeCMap(_ data: [UInt8]) -> PdfTrueTypeCMap? {
    guard let table = pdfTrueTypeTables(data)["cmap"] else { return nil }
    let base = table.lowerBound
    guard let subtableCount = pdfReadUInt16(data, base + 2), subtableCount <= 128 else {
        return nil
    }

    var best: (score: Int, offset: Int)?
    for index in 0..<Int(subtableCount) {
        let record = base + 4 + index * 8
        guard let platform = pdfReadUInt16(data, record),
            let encoding = pdfReadUInt16(data, record + 2),
            let offset = pdfReadUInt32(data, record + 4)
        else { break }
        // Windows Unicode beats Windows Symbol beats Macintosh Roman beats
        // anything else, which is the order that recovers the most text.
        let score: Int
        switch (platform, encoding) {
        case (3, 10), (3, 1): score = 4
        case (0, _): score = 3
        case (3, 0): score = 2
        case (1, 0): score = 1
        default: score = 0
        }
        if best == nil || score > best!.score {
            best = (score, base + Int(offset))
        }
    }
    guard let chosen = best else { return nil }

    var result = PdfTrueTypeCMap()
    pdfParseCMapSubtable(data, chosen.offset, into: &result)
    return result.isEmpty ? nil : result
}

/// Parse one `cmap` subtable into the mapping.
///
/// Formats 0, 4, 6 and 12 are read; anything else is ignored rather than
/// guessed at, since a misread mapping produces plausible wrong characters.
func pdfParseCMapSubtable(_ data: [UInt8], _ offset: Int, into result: inout PdfTrueTypeCMap) {
    guard let format = pdfReadUInt16(data, offset) else { return }

    func record(_ code: UInt32, _ glyph: UInt16) {
        guard glyph != 0, let scalar = Unicode.Scalar(code) else { return }
        result.characterToGlyph[code] = glyph
        // The *first* character wins: a font may map several codes to one
        // glyph, and the lowest is the one worth reporting.
        if result.glyphToCharacter[glyph] == nil { result.glyphToCharacter[glyph] = scalar }
    }

    switch format {
    case 0:
        // A byte-indexed table: 256 glyph ids, one per code.
        for code in 0..<256 {
            let position = offset + 6 + code
            guard position < data.count else { break }
            record(UInt32(code), UInt16(data[position]))
        }

    case 4:
        // Segment mapping. The arrays run end[], reserved, start[], delta[],
        // rangeOffset[], and the last segment always ends at 0xFFFF.
        guard let segmentsTimesTwo = pdfReadUInt16(data, offset + 6) else { return }
        let segments = Int(segmentsTimesTwo) / 2
        guard segments > 0, segments <= 16384 else { return }
        let endBase = offset + 14
        let startBase = endBase + segments * 2 + 2
        let deltaBase = startBase + segments * 2
        let rangeBase = deltaBase + segments * 2

        for segment in 0..<segments {
            guard let end = pdfReadUInt16(data, endBase + segment * 2),
                let start = pdfReadUInt16(data, startBase + segment * 2),
                let delta = pdfReadUInt16(data, deltaBase + segment * 2),
                let rangeOffset = pdfReadUInt16(data, rangeBase + segment * 2),
                start <= end
            else { continue }
            for code in UInt32(start)...UInt32(end) {
                if code == 0xFFFF { continue }
                var glyph: UInt16
                if rangeOffset == 0 {
                    // The delta is added modulo 2^16, which is why it is
                    // read unsigned and added with wrapping.
                    glyph = UInt16(truncatingIfNeeded: Int(code) &+ Int(delta))
                } else {
                    // The offset is a byte distance *from the rangeOffset
                    // slot itself*, which is the part of format 4 everyone
                    // gets wrong.
                    let slot = rangeBase + segment * 2
                    let index = slot + Int(rangeOffset) + Int(code - UInt32(start)) * 2
                    guard let raw = pdfReadUInt16(data, index), raw != 0 else { continue }
                    glyph = UInt16(truncatingIfNeeded: Int(raw) &+ Int(delta))
                }
                record(code, glyph)
            }
        }

    case 6:
        // A trimmed table: a run of codes starting at `first`.
        guard let first = pdfReadUInt16(data, offset + 6),
            let count = pdfReadUInt16(data, offset + 8), count <= 16384
        else { return }
        for index in 0..<Int(count) {
            guard let glyph = pdfReadUInt16(data, offset + 10 + index * 2) else { break }
            record(UInt32(first) + UInt32(index), glyph)
        }

    case 12:
        // Grouped ranges, the only format that reaches beyond the basic
        // plane — which is what an emoji or a rare CJK glyph needs.
        guard let groups = pdfReadUInt32(data, offset + 12), groups <= 100_000 else { return }
        for index in 0..<Int(groups) {
            let entry = offset + 16 + index * 12
            guard let startCode = pdfReadUInt32(data, entry),
                let endCode = pdfReadUInt32(data, entry + 4),
                let startGlyph = pdfReadUInt32(data, entry + 8),
                startCode <= endCode, endCode - startCode <= 0x10FFFF
            else { break }
            for code in startCode...endCode {
                record(code, UInt16(truncatingIfNeeded: startGlyph + (code - startCode)))
            }
        }

    default:
        break
    }
}
