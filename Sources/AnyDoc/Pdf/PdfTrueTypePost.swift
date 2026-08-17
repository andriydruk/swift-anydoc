/// The TrueType `post` table, for fonts whose glyph names are the only route
/// to their text — ported from `build_cmap_from_glyph_names` in
/// `tounicode.rs`.
///
/// A subset font may carry no `/ToUnicode`, and a symbol or converted font
/// may carry no usable `cmap` either. What it often does carry is a `post`
/// table naming each glyph: `H`, `i`, `exclam`. Those names go through the
/// Adobe glyph list — already ported as `pdfGlyphToScalar` — and the text
/// comes back.
///
/// The reference reaches this only when the `cmap` produced nothing, and so
/// does this port: a real character mapping is always the better authority.

/// The standard Macintosh glyph ordering, which `post` format 2.0 indexes
/// into for its first 258 names.
///
/// A font that uses only these — most do, for Latin text — stores no strings
/// at all, so without the table its `post` is an array of numbers meaning
/// nothing. The order is fixed by the format and is not a choice.
private let pdfMacintoshGlyphOrder: [String] = [
    ".notdef", ".null", "nonmarkingreturn", "space", "exclam", "quotedbl",
    "numbersign", "dollar", "percent", "ampersand", "quotesingle", "parenleft",
    "parenright", "asterisk", "plus", "comma", "hyphen", "period", "slash",
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
    "nine", "colon", "semicolon", "less", "equal", "greater", "question", "at",
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
    "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "bracketleft",
    "backslash", "bracketright", "asciicircum", "underscore", "grave", "a",
    "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p",
    "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "braceleft", "bar",
    "braceright", "asciitilde", "Adieresis", "Aring", "Ccedilla", "Eacute",
    "Ntilde", "Odieresis", "Udieresis", "aacute", "agrave", "acircumflex",
    "adieresis", "atilde", "aring", "ccedilla", "eacute", "egrave",
    "ecircumflex", "edieresis", "iacute", "igrave", "icircumflex", "idieresis",
    "ntilde", "oacute", "ograve", "ocircumflex", "odieresis", "otilde",
    "uacute", "ugrave", "ucircumflex", "udieresis", "dagger", "degree", "cent",
    "sterling", "section", "bullet", "paragraph", "germandbls", "registered",
    "copyright", "trademark", "acute", "dieresis", "notequal", "AE", "Oslash",
    "infinity", "plusminus", "lessequal", "greaterequal", "yen", "mu",
    "partialdiff", "summation", "product", "pi", "integral", "ordfeminine",
    "ordmasculine", "Omega", "ae", "oslash", "questiondown", "exclamdown",
    "logicalnot", "radical", "florin", "approxequal", "Delta", "guillemotleft",
    "guillemotright", "ellipsis", "nonbreakingspace", "Agrave", "Atilde",
    "Otilde", "OE", "oe", "endash", "emdash", "quotedblleft", "quotedblright",
    "quoteleft", "quoteright", "divide", "lozenge", "ydieresis", "Ydieresis",
    "fraction", "currency", "guilsinglleft", "guilsinglright", "fi", "fl",
    "daggerdbl", "periodcentered", "quotesinglbase", "quotedblbase",
    "perthousand", "Acircumflex", "Ecircumflex", "Aacute", "Edieresis",
    "Egrave", "Iacute", "Icircumflex", "Idieresis", "Igrave", "Oacute",
    "Ocircumflex", "apple", "Ograve", "Uacute", "Ucircumflex", "Ugrave",
    "dotlessi", "circumflex", "tilde", "macron", "breve", "dotaccent", "ring",
    "cedilla", "hungarumlaut", "ogonek", "caron", "Lslash", "lslash", "Scaron",
    "scaron", "Zcaron", "zcaron", "brokenbar", "Eth", "eth", "Yacute",
    "yacute", "Thorn", "thorn", "minus", "multiply", "onesuperior",
    "twosuperior", "threesuperior", "onehalf", "onequarter", "threequarters",
    "franc", "Gbreve", "gbreve", "Idotaccent", "Scedilla", "scedilla",
    "Cacute", "cacute", "Ccaron", "ccaron", "dcroat",
]

/// Glyph id to glyph name, from a `post` table.
///
/// Only format 2.0 carries names. Format 3.0 — by far the most common in
/// modern fonts — declares outright that it has none, and formats 1.0 and
/// 2.5 are obsolete; all of them yield nothing rather than a guess.
func pdfTrueTypeGlyphNames(_ data: [UInt8]) -> [UInt16: String]? {
    guard let table = pdfTrueTypeTables(data)["post"] else { return nil }
    let base = table.lowerBound
    guard base + 34 <= data.count else { return nil }

    let version =
        UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16
        | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    guard version == 0x0002_0000 else { return nil }

    let countOffset = base + 32
    guard countOffset + 1 < data.count else { return nil }
    let glyphCount = Int(UInt16(data[countOffset]) << 8 | UInt16(data[countOffset + 1]))
    guard glyphCount > 0, glyphCount <= 65535 else { return nil }

    let indexStart = countOffset + 2
    guard indexStart + glyphCount * 2 <= table.upperBound else { return nil }

    // The custom names follow the index array as Pascal strings, in order.
    var custom: [String] = []
    var cursor = indexStart + glyphCount * 2
    while cursor < table.upperBound {
        let length = Int(data[cursor])
        cursor += 1
        guard cursor + length <= table.upperBound else { break }
        custom.append(String(decoding: data[cursor..<(cursor + length)], as: UTF8.self))
        cursor += length
    }

    var names: [UInt16: String] = [:]
    for glyph in 0..<glyphCount {
        let at = indexStart + glyph * 2
        let index = Int(UInt16(data[at]) << 8 | UInt16(data[at + 1]))
        if index < pdfMacintoshGlyphOrder.count {
            names[UInt16(truncatingIfNeeded: glyph)] = pdfMacintoshGlyphOrder[index]
        } else {
            let custom_index = index - 258
            guard custom_index < custom.count else { continue }
            names[UInt16(truncatingIfNeeded: glyph)] = custom[custom_index]
        }
    }
    return names.isEmpty ? nil : names
}

/// Glyph id to character, read from the font's glyph names.
///
/// `.notdef` and the other structural names map to nothing, which is what
/// leaving them out of the Adobe glyph list already achieves.
func pdfTrueTypeCMapFromGlyphNames(_ data: [UInt8]) -> PdfTrueTypeCMap? {
    guard let names = pdfTrueTypeGlyphNames(data) else { return nil }
    var cmap = PdfTrueTypeCMap()
    for (glyph, name) in names {
        guard let scalar = pdfGlyphToScalar(name) else { continue }
        cmap.glyphToCharacter[glyph] = scalar
    }
    return cmap.isEmpty ? nil : cmap
}
