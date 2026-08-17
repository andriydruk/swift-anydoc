/// Single-byte decoding fallbacks, ported from `extractor/fonts.rs` in
/// pdf-inspector.
///
/// When a font declares no usable encoding, its bytes have to be guessed at.
/// Windows-1252 is the right guess for most documents — but exactly wrong for
/// TeX and symbol fonts, which put glyphs in the same byte range, so the guess
/// is made per font by name.

/// Decode a byte under the Windows-1252 assumption.
///
/// Only the C1 range differs from Latin-1; everything else is the byte's own
/// value. Note 0x81, 0x8D, 0x8F, 0x90 and 0x9D are unassigned in the codepage
/// and fall through to Latin-1 rather than being rejected.
func pdfDecodeSingleByte(_ byte: UInt8, useCp1252: Bool) -> Unicode.Scalar {
    guard useCp1252 else { return Unicode.Scalar(byte) }
    switch byte {
    case 0x80: return "\u{20AC}"
    case 0x82: return "\u{201A}"
    case 0x83: return "\u{0192}"
    case 0x84: return "\u{201E}"
    case 0x85: return "\u{2026}"
    case 0x86: return "\u{2020}"
    case 0x87: return "\u{2021}"
    case 0x88: return "\u{02C6}"
    case 0x89: return "\u{2030}"
    case 0x8A: return "\u{0160}"
    case 0x8B: return "\u{2039}"
    case 0x8C: return "\u{0152}"
    case 0x8E: return "\u{017D}"
    case 0x91: return "\u{2018}"
    case 0x92: return "\u{2019}"
    case 0x93: return "\u{201C}"
    case 0x94: return "\u{201D}"
    case 0x95: return "\u{2022}"
    case 0x96: return "\u{2013}"
    case 0x97: return "\u{2014}"
    case 0x98: return "\u{02DC}"
    case 0x99: return "\u{2122}"
    case 0x9A: return "\u{0161}"
    case 0x9B: return "\u{203A}"
    case 0x9C: return "\u{0153}"
    case 0x9E: return "\u{017E}"
    case 0x9F: return "\u{0178}"
    default: return Unicode.Scalar(byte)
    }
}

/// Decode a run of bytes one at a time.
func pdfDecodeSingleByteRun(_ bytes: [UInt8], useCp1252: Bool) -> String {
    var scalars = String.UnicodeScalarView()
    for byte in bytes { scalars.append(pdfDecodeSingleByte(byte, useCp1252: useCp1252)) }
    return String(scalars)
}

/// Re-decode C1 control characters that reached the text some other way.
///
/// Text decoded through a `/ToUnicode` map can still land in the C1 block,
/// where nothing legible lives. This applies the same Windows-1252 reading to
/// those characters after the fact.
func pdfNormaliseCp1252Controls(_ text: String, useCp1252: Bool) -> String {
    guard useCp1252 else { return text }
    guard text.unicodeScalars.contains(where: { (0x80...0x9F).contains($0.value) })
    else { return text }

    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if (0x80...0x9F).contains(scalar.value) {
            scalars.append(pdfDecodeSingleByte(UInt8(scalar.value), useCp1252: true))
        } else {
            scalars.append(scalar)
        }
    }
    return String(scalars)
}

/// TeX and Computer Modern font-name prefixes, which put ligatures and maths
/// in the C1 range and must not be read as Windows-1252.
private let pdfNonCp1252Prefixes = [
    "cmr", "cmb", "cmmi", "cmsy", "cmex", "cmtt", "cmss", "cmti", "ecrm", "ecbx", "ecti",
    "tcrm", "tctt", "msam", "msbm", "ttdc",
]

/// Name fragments that mark a symbol font, wherever they appear.
private let pdfNonCp1252Names = ["math", "symbol", "dingbat", "emoji"]

/// Whether a font's bytes should be read as Windows-1252.
///
/// The cost of getting it wrong is visible in the output: reading a TeX font
/// that way turns `deficiente` into `de…ciente` and `fluid` into `‡uid`,
/// because the ligature bytes land on C1 punctuation.
///
/// A CID font never qualifies — its codes are not bytes. A font with no name
/// does, since Windows-1252 is right far more often than not.
func pdfShouldUseCp1252(baseFontName: String?, isType0CidFont: Bool) -> Bool {
    if isType0CidFont { return false }
    guard let baseFontName else { return true }

    // `rsplit_once`, so the *last* `+` separates the subset tag.
    var name = baseFontName
    if let plus = baseFontName.lastIndex(of: "+") {
        name = String(baseFontName[baseFontName.index(after: plus)...])
    }
    let lowered = name.asciiLowercased()

    if pdfNonCp1252Prefixes.contains(where: { lowered.hasPrefix($0) }) { return false }
    return !pdfNonCp1252Names.contains { scalarsContain(lowered, $0) }
}

/// Fold the private-use area Symbol and Wingdings map into.
///
/// Their `/ToUnicode` maps point at F000–F0FF, which is the byte plus an
/// offset. Most of the range is recovered by removing it; three codes are
/// bullets in every such font and one is a checkmark, so those are named
/// outright.
func pdfCleanSymbolPua(_ text: String) -> String {
    guard text.unicodeScalars.contains(where: { (0xF000...0xF0FF).contains($0.value) })
    else { return text }

    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        guard (0xF000...0xF0FF).contains(scalar.value) else {
            scalars.append(scalar)
            continue
        }
        let low = scalar.value - 0xF000
        switch low {
        case 0xA1, 0xA7, 0xB7:
            scalars.append("\u{2022}")
        case 0xFC:
            scalars.append("\u{2713}")
        case 0x20...0xFF:
            scalars.append(Unicode.Scalar(low) ?? scalar)
        default:
            // Below 0x20 the offset would give a control character, so the
            // private-use codepoint is left as it is.
            scalars.append(scalar)
        }
    }
    return String(scalars)
}

/// Map a symbol font's bytes into the private-use area, or `nil`.
///
/// The inverse of the above, for fonts with no usable map at all: put the
/// bytes where `pdfCleanSymbolPua` expects them. Only for fonts named as
/// symbol fonts, and control bytes are dropped rather than offset.
func pdfDecodeSymbolFallback(_ bytes: [UInt8], baseFontName: String?) -> String? {
    guard let baseFontName else { return nil }
    let name = baseFontName.asciiLowercased()
    guard scalarsContain(name, "symbol") || scalarsContain(name, "wingdings")
        || scalarsContain(name, "zapfdingbats")
    else { return nil }

    var scalars = String.UnicodeScalarView()
    for byte in bytes where byte >= 0x20 {
        if let scalar = Unicode.Scalar(0xF000 + UInt32(byte)) { scalars.append(scalar) }
    }
    return scalars.isEmpty ? nil : String(scalars)
}

/// English function words, used only to score a decoding.
private let pdfCommonWords: Set<String> = [
    "the", "and", "of", "to", "in", "a", "is", "that", "for", "with", "on", "as", "by", "from",
    "this", "be", "are", "at", "or", "not", "it", "our",
]

/// How much a decoded string looks like text.
///
/// Words count for ten, letters and spaces for a little, and anything
/// unprintable counts against. CJK ideographs and kana count as letters, so a
/// Japanese document is not scored as noise. A long run of letters that forms
/// no known word is penalised outright — that is the shape of a wrong
/// single-byte decoding, which produces plausible letters in implausible
/// arrangements.
func pdfScoreText(_ text: String) -> Int {
    var letters = 0
    var spaces = 0
    var digits = 0
    var other = 0
    var wordHits = 0
    var current = ""

    func closeWord() {
        if !current.isEmpty {
            if pdfCommonWords.contains(current) { wordHits += 1 }
            current = ""
        }
    }

    for scalar in text.unicodeScalars {
        if pdfIsAsciiAlphabetic(scalar) {
            letters += 1
            current.unicodeScalars.append(pdfAsciiLowercased(scalar))
            continue
        }
        closeWord()
        if scalar == " " {
            spaces += 1
        } else if scalar.value >= 0x30 && scalar.value <= 0x39 {
            digits += 1
        } else if scalar.properties.generalCategory == .control || scalar.value == 0xFFFD {
            other += 3
        } else if (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3040...0x309F).contains(scalar.value)
            || (0x30A0...0x30FF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
        {
            letters += 1
        } else {
            other += 1
        }
    }
    closeWord()

    var score = wordHits * 10 + letters + spaces * 2 + digits - other * 2
    if letters > 15 && wordHits == 0 { score -= 15 }
    return score
}

/// Pick between two decodings of the same bytes.
///
/// The remapped one has to win by more than three to be taken: the primary
/// decoding is what the font declared, and a near-tie is not evidence enough
/// to overrule it.
func pdfChooseBestCmapDecode(primary: String, remapped: String) -> String {
    if primary.isEmpty { return remapped }
    if remapped.isEmpty { return primary }
    return pdfScoreText(remapped) > pdfScoreText(primary) + 3 ? remapped : primary
}

/// Undo a known producer bug in `TeXCMMathsSymbols` subset fonts.
///
/// IntechOpen and sibling academic pipelines emit Computer Modern symbol
/// glyphs under the names of Latin lookalikes — `equal` as `/onequarter`,
/// `plus` as `/thorn` — and the generated `/ToUnicode` faithfully propagates
/// the wrong names. The text then extracts as `¼` where the page shows `=`.
///
/// Keyed on the base font name, so it can only fire on text decoded through
/// that font. A blanket substitution would corrupt every document that
/// legitimately writes a fraction.
func pdfRemapTexCmMathSymbols(_ text: String, baseFontName: String?) -> String {
    guard let baseFontName else { return text }
    // `rsplit_once`, so the *last* `+` separates the subset tag.
    var name = baseFontName
    if let plus = baseFontName.lastIndex(of: "+") {
        name = String(baseFontName[baseFontName.index(after: plus)...])
    }
    guard name.asciiLowercased() == "texcmmathssymbols" else { return text }

    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        switch scalar {
        case "¼": scalars.append("=")
        case "½": scalars.append("-")
        case "þ": scalars.append("+")
        case "ð": scalars.append("(")
        case "Þ": scalars.append(")")
        default: scalars.append(scalar)
        }
    }
    return String(scalars)
}
