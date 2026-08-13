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

/// The style a font's `/FontDescriptor` declares.
///
/// A thin wrapper over `pdfDescriptorStyleFlags`, which is the reference's
/// own function and also consults the embedded font program. The cache is
/// fresh per call, matching the reference's call sites that pass
/// `&mut FontStyleCache::new()`.
func pdfStyleFromDescriptor(_ document: inout PdfDocument, _ font: PdfDictionary) -> PdfFontStyle {
    var cache = PdfFontStyleCache()
    return pdfDescriptorStyleFlags(&document, font, cache: &cache)
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

/// Stamp each item with the style its font declares, so the writer can weigh
/// bold, italic and underline together.
func pdfApplyFontStyles(_ items: inout [PdfLayoutItem], _ styles: [String: PdfFontStyle]) {
    for index in items.indices {
        guard let style = styles[items[index].fontName] else { continue }
        items[index].isBold = style.bold
        items[index].isItalic = style.italic
    }
}

/// A line's text with emphasis markers around the runs that carry them.
///
/// Underline is **exclusive**: `<u>` content stays free of `**` and `*`.
/// Consumers match tag content literally, and mixed `<u>**x**</u>` nesting
/// breaks that, so an underlined run is never also emphasised.
///
/// Each style opens and closes on its own. Closing all three whenever any one
/// changes would turn a bold run followed by a bold-italic run into
/// `**a*****b***` instead of `**a*b***`.
func pdfLineTextWithEmphasis(
    _ line: PdfTextLine,
    formatBold: Bool = true,
    formatItalic: Bool = true,
    formatUnderline: Bool = true
) -> String {
    if !formatBold, !formatItalic, !formatUnderline { return pdfLineText(line) }

    var result = ""
    var openBold = false
    var openItalic = false
    var openUnderline = false

    for (index, item) in line.items.enumerated() {
        let trimmed = item.text.rustTrim()
        if trimmed.isEmpty { continue }

        // The previous *item*, not the previous non-empty one: the reference
        // indexes back by one whatever sat there.
        let needsSpace =
            index == 0 || result.isEmpty
            ? false
            : pdfNeedsSpace(line.items[index - 1], item, result)
        // A leading space in the run is itself a word boundary, and the
        // trimmed text about to be appended would lose it.
        let hasLeadingSpace = item.text.hasPrefix(" ")

        let underline = formatUnderline && item.isUnderline
        let bold = formatBold && item.isBold && !underline
        let italic = formatItalic && item.isItalic && !underline

        // Close in the reverse of the order they open, so the markers nest.
        if openItalic, !italic {
            result += "*"
            openItalic = false
        }
        if openBold, !bold {
            result += "**"
            openBold = false
        }
        if openUnderline, !underline {
            result += "</u>"
            openUnderline = false
        }

        // The separating space sits outside the markers.
        if needsSpace || (hasLeadingSpace && !result.isEmpty && !result.hasSuffix(" ")) {
            result += " "
        }

        if underline, !openUnderline {
            result += "<u>"
            openUnderline = true
        }
        if bold, !openBold {
            result += "**"
            openBold = true
        }
        if italic, !openItalic {
            result += "*"
            openItalic = true
        }
        result += trimmed
    }

    if openItalic { result += "*" }
    if openBold { result += "**" }
    if openUnderline { result += "</u>" }
    return result
}
