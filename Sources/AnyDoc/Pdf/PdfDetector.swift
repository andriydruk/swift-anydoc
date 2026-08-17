/// Scanned-versus-text classification primitives, ported from
/// pdf-inspector's `detector.rs`.
///
/// The detector decides whether a PDF carries real text or is a scan needing
/// OCR. This wave ports the parts that stand alone: the byte-level page-count
/// fallback for files too broken to parse, the sampling that picks which pages
/// to analyse, and the rule that turns one page's analysis into a reason it
/// needs OCR.

/// Why a page needs OCR. These strings are the reference's own, and are part
/// of its output rather than internal names.
enum PdfOcrReason {
    static let suspectedGarbledText = "suspected_garbled_text"
    static let scanned = "scanned"
    static let noText = "no_text"
    static let vectorText = "vector_text"
}

/// The PDF whitespace set: null, tab, newline, form feed, carriage return,
/// space. Note this is narrower than Unicode whitespace and wider than ASCII
/// space alone.
func pdfIsWhitespaceByte(_ byte: UInt8) -> Bool {
    byte == 0x00 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
}

/// What ends a PDF name token: whitespace, or one of the structural
/// delimiters. This is what separates `/Page` from `/Pages`.
func pdfIsNameDelimiterByte(_ byte: UInt8) -> Bool {
    if pdfIsWhitespaceByte(byte) { return true }
    switch byte {
    case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
        UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
        UInt8(ascii: "/"), UInt8(ascii: "%"):
        return true
    default:
        return false
    }
}

/// The first index at or after `position` that is not PDF whitespace.
func pdfSkipWhitespace(_ buffer: [UInt8], from position: Int) -> Int {
    var position = position
    while position < buffer.count && pdfIsWhitespaceByte(buffer[position]) { position += 1 }
    return position
}

/// A heuristic page count for a PDF too malformed to parse.
///
/// It counts `/Type /Page` dictionaries in the raw bytes while excluding the
/// page-tree node `/Type /Pages` — the delimiter check after `Page` is the
/// whole of that distinction, since `s` is not a delimiter.
///
/// Low confidence by design: a parsed page tree remains authoritative, and
/// this exists only so a broken file still reports something.
func pdfEstimatePageCountFromBytes(_ buffer: [UInt8]) -> UInt32 {
    let needle = Array("/Type".utf8)
    var count: UInt32 = 0
    var position = 0

    while position <= buffer.count - needle.count {
        guard let found = pdfFindBytes(buffer, needle, from: position) else { break }
        var valuePosition = found + needle.count
        valuePosition = pdfSkipWhitespace(buffer, from: valuePosition)

        if valuePosition < buffer.count && buffer[valuePosition] == UInt8(ascii: "/") {
            let nameStart = valuePosition + 1
            let nameEnd = nameStart + 4  // "Page"
            if nameEnd <= buffer.count && Array(buffer[nameStart..<nameEnd]) == Array("Page".utf8)
                // A name running to the end of the buffer counts: there is no
                // byte after it to disqualify it.
                && (nameEnd >= buffer.count || pdfIsNameDelimiterByte(buffer[nameEnd]))
            {
                count += 1
            }
        }
        position = found + needle.count
    }
    return count
}

/// The first offset at or after `from` where `needle` occurs.
func pdfFindBytes(_ haystack: [UInt8], _ needle: [UInt8], from: Int = 0) -> Int? {
    guard !needle.isEmpty, haystack.count >= needle.count, from <= haystack.count - needle.count
    else { return nil }
    for start in from...(haystack.count - needle.count) {
        var matched = true
        for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
            matched = false
            break
        }
        if matched { return start }
    }
    return nil
}

/// Which pages to sample, 1-indexed: `count` of them spread across `total`.
///
/// The first and last page always appear — a scan usually starts and ends the
/// way it continues — and the rest are spaced evenly between. The spacing is
/// integer division, so on small documents several computed indices collide
/// and the result is simply shorter than `count`; that is the reference's
/// behaviour, not an approximation of it.
func pdfDistributePages(_ count: UInt32, total: UInt32) -> [UInt32] {
    if count == 0 { return [] }
    if count >= total { return total == 0 ? [] : Array(1...total) }

    var indices: [UInt32] = [1]
    if count > 1 { indices.append(total) }

    let remaining = count >= 2 ? count - 2 : 0
    if remaining > 0 && total > 2 {
        let step = (total - 2) / (remaining + 1)
        for i in 1...remaining {
            let index = 1 + step * i
            if index > 1 && index < total && !indices.contains(index) { indices.append(index) }
        }
    }

    indices.sort()
    var deduplicated: [UInt32] = []
    for index in indices where deduplicated.last != index { deduplicated.append(index) }
    return deduplicated
}

/// What one page's content analysis says about its need for OCR.
struct PdfPageAnalysis {
    var textOperatorCount: UInt32 = 0
    var hasImages = false
    /// A background or template image covering more than half the page.
    var hasTemplateImage = false
    var uniqueTextCharacters: UInt32 = 0
    /// Text drawn as filled outlines: many path operators, almost no text
    /// ones. No text layer exists to extract at all.
    var hasVectorText = false
    /// Identity-H or Identity-V encoding with no ToUnicode CMap, so the CIDs
    /// cannot be mapped back to characters.
    var hasIdentityHNoToUnicode = false
    /// Every font on the page is Type 3, which draws each glyph as a custom
    /// procedure rather than referencing a character.
    var hasOnlyType3Fonts = false
    /// Pixels of image on the page, summed over every XObject image — the
    /// tiled-scan signal, since a page of JBIG2 strips has no single image
    /// large enough to look like a template but plenty in total.
    var totalImageArea: UInt64 = 0
    var imageCount: UInt32 = 0
    /// Distinct ASCII letters and digits among the raw bytes drawn. A CID
    /// font produces almost none of these while extracting perfectly, which
    /// is why `hasDecodableTextFonts` exists to overrule it.
    var uniqueAlphanumericCharacters: UInt32 = 0
    var pathOperatorCount: UInt32 = 0
    var fontChangeCount: UInt32 = 0
    /// At least one used font can produce Unicode.
    var hasDecodableTextFonts = false
}

/// Why a page needs OCR, in priority order.
///
/// Undecodable fonts and vector-outlined text come first because they persist
/// *even when a text layer is present* — extracting it yields garbage rather
/// than nothing, which is the harder failure to notice. Only when neither
/// applies does the absence of text matter, and then an image-backed page is
/// `scanned` while a bare one is `no_text`.
///
/// Both leading reasons can apply at once, so the result is a list.
func pdfPageOcrReasons(_ analysis: PdfPageAnalysis) -> [String] {
    var reasons: [String] = []
    if analysis.hasIdentityHNoToUnicode || analysis.hasOnlyType3Fonts {
        reasons.append(PdfOcrReason.suspectedGarbledText)
    }
    if analysis.hasVectorText { reasons.append(PdfOcrReason.vectorText) }
    if reasons.isEmpty {
        let hasExtractableText = analysis.textOperatorCount > 0 && analysis.uniqueTextCharacters > 0
        if !hasExtractableText && !analysis.hasImages && !analysis.hasTemplateImage {
            reasons.append(PdfOcrReason.noText)
        } else {
            reasons.append(PdfOcrReason.scanned)
        }
    }
    return reasons
}
