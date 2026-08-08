/// Whether a font is bold or italic, from pdf-inspector's `text_utils.rs`
/// name heuristics and `fonts.rs` descriptor flags.
///
/// PDF has no bold or italic attribute on text: the writer selects a
/// different font. Recovering emphasis therefore means asking what the font
/// *is*, which two sources answer and neither answers reliably — the
/// `BaseFont` name, which subset generators often reduce to something opaque
/// like `Tc1`, and the `FontDescriptor`, which some generators fill in
/// wrongly. Both are consulted, either one is enough.

struct PdfFontStyle: Equatable {
    var bold = false
    var italic = false
}

/// The style a `BaseFont` name declares.
///
/// Matching is on the lowercased name, so `Helvetica-BoldOblique` reads as
/// both. The abbreviations are the ones real producers emit.
func pdfStyleFromFontName(_ name: String) -> PdfFontStyle {
    // Rust's `to_lowercase` and byte-wise `contains`, not Swift's
    // grapheme-wise ones: `Courier` followed by a combining mark still
    // contains `courier` to the reference, and `Ö` still lowercases.
    let lower = name.rustLowercased()
    func has(_ needle: String) -> Bool { scalarsContain(lower, needle) }

    // `Medium` is a weight several families use for semi-bold; `Medi` is the
    // URW Type 1 abbreviation (NimbusRomNo9L-Medi is LaTeX's Times-Bold).
    // Both are excluded when the name goes on to say italic, since that is a
    // different face rather than a bolder one.
    let bold =
        has("bold") || has("-bd") || has("_bd") || has("black") || has("heavy")
        || has("demibold") || has("semibold") || has("demi-bold") || has("semi-bold")
        || has("extrabold") || has("ultrabold")
        || (has("medium") && !has("mediumitalic"))
        || (has("-medi") && !has("mediumital"))

    let italic =
        has("italic") || has("oblique") || has("-it") || has("_it") || has("slant")
        || has("inclined") || has("kursiv")

    return PdfFontStyle(bold: bold, italic: italic)
}

/// Beyond this many degrees of slant the font is italic. A token angle is
/// not a style: some upright fonts declare one or two degrees.
private let italicAngleThreshold: Float = 4

/// The style a font's `/FontDescriptor` declares.
func pdfStyleFromDescriptor(_ document: inout PdfDocument, _ font: PdfDictionary) -> PdfFontStyle {
    // A composite font keeps its descriptor on the descendant CIDFont.
    var target = font
    if let descendants = document.value(font, "DescendantFonts")?.asArray,
        let first = descendants.first,
        let cidFont = document.resolve(first).asDictionary
    {
        target = cidFont
    }
    guard let descriptor = document.value(target, "FontDescriptor")?.asDictionary else {
        return PdfFontStyle()
    }
    var style = PdfFontStyle()
    if let angle = document.value(descriptor, "ItalicAngle")?.asNumber,
        abs(Float(angle)) > italicAngleThreshold
    {
        style.italic = true
    }
    if let flags = document.value(descriptor, "Flags")?.asInteger {
        // Bit 7 (value 64) is Italic; bit 19 (value 1 << 18) is ForceBold.
        if flags & 64 != 0 { style.italic = true }
        if flags & (1 << 18) != 0 { style.bold = true }
    }
    return style
}

/// A font's style, taking either source's word for it.
func pdfFontStyle(_ document: inout PdfDocument, _ font: PdfDictionary) -> PdfFontStyle {
    let name = document.value(font, "BaseFont")?.asName.map { String(decoding: $0, as: UTF8.self) }
    var style = name.map(pdfStyleFromFontName) ?? PdfFontStyle()
    let descriptor = pdfStyleFromDescriptor(&document, font)
    style.bold = style.bold || descriptor.bold
    style.italic = style.italic || descriptor.italic
    return style
}

/// A line's text with emphasis markers around the runs that carry them.
///
/// Markers open and close as the style changes, and never wrap the space
/// between two words — `**a** **b**` rather than `**a b**` would be wrong
/// only if the space itself were emphasized, which it never meaningfully is,
/// so trailing spaces are pushed outside the markers.
func pdfLineTextWithEmphasis(_ line: PdfTextLine, styles: [String: PdfFontStyle]) -> String {
    var result = ""
    var openBold = false
    var openItalic = false
    var previous: PdfLayoutItem?

    func closeAll() {
        if openItalic {
            result += "*"
            openItalic = false
        }
        if openBold {
            result += "**"
            openBold = false
        }
    }

    for item in line.items {
        let trimmed = item.text.rustTrim()
        if trimmed.isEmpty { continue }
        let style = styles[item.fontName] ?? PdfFontStyle()

        var separator = ""
        if let previous, !result.isEmpty, pdfNeedsSpace(previous, item, result) {
            separator = " "
        }
        // A style change closes the old markers before the separating space,
        // so the space sits outside them.
        if style.bold != openBold || style.italic != openItalic {
            closeAll()
        }
        result += separator
        if style.bold, !openBold {
            result += "**"
            openBold = true
        }
        if style.italic, !openItalic {
            result += "*"
            openItalic = true
        }
        result += trimmed
        previous = item
    }
    closeAll()
    return result
}
