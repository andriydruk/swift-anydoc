/// Glyph name to character, ported from `glyph_to_char` in pdf-inspector's
/// `glyph_names.rs`.
///
/// A font's `/Differences` array names its glyphs rather than numbering them,
/// so `/quotesingle` and `/uni2019` have to be turned back into characters
/// before any text comes out. The table is the Adobe Glyph List as the
/// *reference* carries it — see `scripts/gen-glyph-names.py` — and three
/// fallbacks handle names it does not list.
func pdfGlyphToScalar(_ name: String) -> Unicode.Scalar? {
    if let scalar = pdfLookUpGlyphName(name) { return scalar }

    // A suffix after a dot names a variant of the same glyph: `zero.tf` is
    // still a zero, `a.ss01` still an `a`. The Adobe spec says to strip it.
    if let dot = name.firstIndex(of: ".") {
        if let scalar = pdfLookUpGlyphName(String(name[name.startIndex..<dot])) {
            return scalar
        }
    }

    let scalars = Array(name.unicodeScalars)

    // `uniXXXX` — exactly four hex digits, and anything after them ignored.
    if name.hasPrefix("uni") && scalars.count >= 7 {
        let digits = String(String.UnicodeScalarView(scalars[3..<7]))
        if var code = UInt32(digits, radix: 16) {
            // Windows Symbol fonts map their glyphs into the private-use area
            // at F000; `uniF041` means `A`, not a private glyph.
            if (0xF000...0xF0FF).contains(code) { code -= 0xF000 }
            return Unicode.Scalar(code)
        }
    }

    // `uXXXX` through `uXXXXXX` — the whole remainder is the number, so a
    // trailing suffix makes it fail rather than being ignored.
    if name.hasPrefix("u") && scalars.count >= 5 {
        let digits = String(String.UnicodeScalarView(scalars[1...]))
        if let code = UInt32(digits, radix: 16) { return Unicode.Scalar(code) }
    }

    return nil
}

/// Binary search of the generated table.
private func pdfLookUpGlyphName(_ name: String) -> Unicode.Scalar? {
    var low = 0
    var high = pdfGlyphNames.count - 1
    while low <= high {
        let middle = (low + high) / 2
        let candidate = pdfGlyphNames[middle]
        if candidate == name { return Unicode.Scalar(pdfGlyphScalars[middle]) }
        if candidate < name { low = middle + 1 } else { high = middle - 1 }
    }
    return nil
}
