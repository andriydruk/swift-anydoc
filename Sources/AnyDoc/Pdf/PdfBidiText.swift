/// Script classification and bidirectional text handling, ported from
/// `text_utils.rs` in pdf-inspector.
///
/// A PDF stores glyphs in the order they are *drawn*, which for Arabic and
/// Hebrew is left-to-right screen order rather than reading order. Whether a
/// line needs reversing is decided by counting characters, and the reversal
/// itself has to leave embedded numbers and Latin words alone — they run the
/// other way inside the same line.
///
/// Not ported here: `expand_ligatures`, which applies NFKC normalisation when
/// Arabic presentation forms are present. NFKC needs a Unicode decomposition
/// table this port does not have yet; generating one is its own wave, and the
/// function is inert without it. Everything it *calls* is here.

/// Whether a scalar is CJK, by block.
///
/// Used to keep CJK out of the left-to-right count when deciding a line's
/// direction: CJK is not RTL, but it is not evidence of LTR either.
func pdfIsCjkScalarValue(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x1100...0x11FF,  // Hangul Jamo
        0x3000...0x303F,  // CJK Symbols and Punctuation
        0x3040...0x309F,  // Hiragana
        0x30A0...0x30FF,  // Katakana
        0x3130...0x318F,  // Hangul Compatibility Jamo
        0x4E00...0x9FFF,  // CJK Unified Ideographs
        0xAC00...0xD7AF,  // Hangul Syllables
        0xF900...0xFAFF,  // CJK Compatibility Ideographs
        0xFF00...0xFFEF:  // Halfwidth and Fullwidth Forms
        return true
    default:
        return false
    }
}

/// Whether a scalar belongs to a right-to-left script, by block.
func pdfIsRtlScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0590...0x05FF,  // Hebrew
        0x0600...0x06FF,  // Arabic
        0x0700...0x074F,  // Syriac
        0x0750...0x077F,  // Arabic Supplement
        0x0780...0x07BF,  // Thaana
        0x07C0...0x07FF,  // NKo
        0x0800...0x083F,  // Samaritan
        0x0840...0x085F,  // Mandaic
        0x08A0...0x08FF,  // Arabic Extended-A
        0xFB1D...0xFB4F,  // Hebrew Presentation Forms
        0xFB50...0xFDFF,  // Arabic Presentation Forms-A
        0xFE70...0xFEFF:  // Arabic Presentation Forms-B
        return true
    default:
        return false
    }
}

/// Whether a scalar is an Arabic *presentation form* — a pre-shaped glyph,
/// which is the signal that the text is stored in visual order.
///
/// Note the range stops at U+FEFE rather than U+FEFF: the last codepoint of
/// Presentation Forms-B is the byte-order mark, which is not a glyph at all.
func pdfIsArabicPresentationForm(_ scalar: Unicode.Scalar) -> Bool {
    (0xFB50...0xFDFF).contains(scalar.value) || (0xFE70...0xFEFE).contains(scalar.value)
}

/// Whether a run of text reads right to left.
///
/// A simple majority of RTL characters over LTR ones, with CJK excluded from
/// both counts — an Arabic line with a Japanese caption should still reverse.
/// Requires at least one RTL character, so ordinary text never qualifies.
func pdfIsRtlText<S: Sequence>(_ texts: S) -> Bool where S.Element: StringProtocol {
    var rtl = 0
    var ltr = 0
    for text in texts {
        for scalar in text.unicodeScalars {
            if pdfIsRtlScalar(scalar) {
                rtl += 1
            } else if scalar.properties.isAlphabetic && !pdfIsCjkScalarValue(scalar) {
                ltr += 1
            }
        }
    }
    return rtl > 0 && rtl > ltr
}

/// Whether the scalar at `index` sits next to an ASCII alphanumeric.
///
/// This is what attaches punctuation to a Latin run: the `.` in `3.5` and the
/// `/` in `A/B` belong with the numbers, while a full stop after Arabic does
/// not.
func pdfIsAdjacentToAsciiAlphanumeric(_ scalars: [Unicode.Scalar], _ index: Int) -> Bool {
    (index > 0 && pdfIsAsciiAlphanumericScalar(scalars[index - 1]))
        || (index + 1 < scalars.count && pdfIsAsciiAlphanumericScalar(scalars[index + 1]))
}

/// Restore logical reading order from visual-order Arabic.
///
/// Pure RTL text is simply reversed. Mixed content cannot be: an embedded
/// number or Latin word reads left to right *inside* a right-to-left line, so
/// the text is split into runs, the run *order* is reversed, and only the
/// non-LTR runs are reversed internally. `2024 مارس` and `مارس 2024` differ
/// only in that distinction.
func pdfReverseVisualArabic(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    let hasLtr = scalars.contains(where: pdfIsAsciiAlphanumericScalar)
    if !hasLtr { return String(String.UnicodeScalarView(scalars.reversed())) }

    func isLtr(at index: Int) -> Bool {
        let scalar = scalars[index]
        return pdfIsAsciiAlphanumericScalar(scalar)
            || (pdfIsAsciiPunctuationScalar(scalar)
                && pdfIsAdjacentToAsciiAlphanumeric(scalars, index))
    }

    var runs: [(isLtr: Bool, scalars: [Unicode.Scalar])] = []
    var index = 0
    while index < scalars.count {
        let runIsLtr = isLtr(at: index)
        var run: [Unicode.Scalar] = []
        while index < scalars.count, isLtr(at: index) == runIsLtr {
            run.append(scalars[index])
            index += 1
        }
        runs.append((runIsLtr, run))
    }

    var result = String.UnicodeScalarView()
    for run in runs.reversed() {
        if run.isLtr {
            result.append(contentsOf: run.scalars)
        } else {
            result.append(contentsOf: run.scalars.reversed())
        }
    }
    return String(result)
}

/// Decode a PDF text string: UTF-16BE when it carries a byte-order mark,
/// PDFDocEncoding otherwise.
///
/// PDFDocEncoding is treated as Latin-1, which the reference does too — the
/// two differ only outside the range that matters here. An odd trailing byte
/// after the BOM is dropped, as `chunks_exact` does.
func pdfDecodeTextString(_ bytes: [UInt8]) -> String {
    if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
        var units: [UInt16] = []
        var index = 2
        while index + 1 < bytes.count {
            units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
    var scalars = String.UnicodeScalarView()
    for byte in bytes { scalars.append(Unicode.Scalar(byte)) }
    return String(scalars)
}

/// The font size after the text matrix is applied.
///
/// Both axes are measured as vector magnitudes — so a rotated matrix still
/// reports its true scale — and the larger is used, which for unrotated text
/// is simply whichever axis was stretched.
func pdfEffectiveFontSize(baseSize: Float, textMatrix: [Float]) -> Float {
    guard textMatrix.count >= 4 else { return baseSize }
    let scaleX = (textMatrix[0] * textMatrix[0] + textMatrix[1] * textMatrix[1]).squareRoot()
    let scaleY = (textMatrix[2] * textMatrix[2] + textMatrix[3] * textMatrix[3]).squareRoot()
    return baseSize * max(scaleX, scaleY)
}

/// An item's width, estimated from its text when the extractor recorded none.
func pdfEffectiveItemWidth(_ item: PdfLayoutItem) -> Float {
    if item.width > 0 { return item.width }
    return Float(item.text.unicodeScalars.count) * item.fontSize * 0.5
}

/// Whether a font name marks a CID-keyed font, by the prefix the extractor
/// gives them.
func pdfIsCidFontName(_ font: String) -> Bool {
    font.hasPrefix("C2_") || font.hasPrefix("C0_")
}

// MARK: - ASCII scalar helpers

func pdfIsAsciiAlphanumericScalar(_ scalar: Unicode.Scalar) -> Bool {
    pdfIsAsciiAlphabetic(scalar) || (scalar.value >= 0x30 && scalar.value <= 0x39)
}

/// Rust's `is_ascii_punctuation`: the ASCII graphic characters that are
/// neither letters nor digits.
func pdfIsAsciiPunctuationScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E:
        return true
    default:
        return false
    }
}
