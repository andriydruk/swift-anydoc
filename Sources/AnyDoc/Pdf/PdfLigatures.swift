/// Ligature expansion and visual-order repair, ported from
/// `expand_ligatures` in pdf-inspector's `text_utils.rs`.
///
/// Deferred through waves 44 and 54 because it normalises with NFKC, which
/// the port had no tables for; wave 55 supplied them.
///
/// The function does three jobs that look unrelated but share one cause — a
/// PDF stores *glyphs*, not characters. A ligature is one glyph for two
/// letters, pre-shaped Arabic is one glyph per contextual form, and invisible
/// formatting characters are glyphs with no width. All three have to be undone
/// before the text means anything to a reader or a search.
func pdfExpandLigatures(_ text: String) -> String {
    // Control characters are stripped first, and only when some are present —
    // the reference avoids rebuilding the string otherwise.
    var working = text
    if text.utf8.contains(where: { $0 < 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }) {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars
        where scalar.value >= 0x20 || scalar == "\n" || scalar == "\r" || scalar == "\t" {
            kept.append(scalar)
        }
        working = String(kept)
    }

    // Arabic presentation forms mean the text was stored in visual order, and
    // that has to be known *before* normalising — NFKC turns the forms back
    // into base letters, erasing the evidence.
    let hadPresentationForms = working.unicodeScalars.contains(where: pdfIsArabicPresentationForm)

    // Normalisation runs only in that case. Applying NFKC to everything would
    // fold a non-breaking space into an ordinary one, which the spacing logic
    // downstream depends on being distinct; the Latin ligatures below are
    // handled explicitly instead.
    if hadPresentationForms { working = pdfNfkc(working) }

    var result = String.UnicodeScalarView()
    for scalar in working.unicodeScalars {
        switch scalar {
        // Kept as an explicit fallback for fonts whose ToUnicode maps to the
        // ligature codepoints directly, bypassing normalisation.
        case "\u{FB00}": result.append(contentsOf: "ff".unicodeScalars)
        case "\u{FB01}": result.append(contentsOf: "fi".unicodeScalars)
        case "\u{FB02}": result.append(contentsOf: "fl".unicodeScalars)
        case "\u{FB03}": result.append(contentsOf: "ffi".unicodeScalars)
        case "\u{FB04}": result.append(contentsOf: "ffl".unicodeScalars)
        case "\u{FB05}", "\u{FB06}": result.append(contentsOf: "st".unicodeScalars)
        // Invisible characters that would otherwise pollute the Markdown.
        case "\u{00AD}": break  // soft hyphen
        case "\u{200B}": break  // zero-width space
        case "\u{FEFF}": break  // byte-order mark
        case "\u{200C}", "\u{200D}": break  // zero-width non-joiner and joiner
        case "\u{2060}": break  // word joiner
        // Typographic spaces become ordinary ones so the joining logic can see
        // a word boundary. U+00A0 is deliberately absent: a non-breaking space
        // is common in PDFs and the coordinate-based spacing handles it.
        case "\u{2000}"..."\u{200A}": result.append(" ")
        default: result.append(scalar)
        }
    }

    // Normalisation has left the characters in visual order, so the reversal
    // comes last.
    return hadPresentationForms
        ? pdfReverseVisualArabic(String(result)) : String(result)
}
