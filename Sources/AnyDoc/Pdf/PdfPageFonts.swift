/// Which fonts a page actually uses, and what that says about its text —
/// the font half of `analyze_page_content` in `detector.rs`.
///
/// This is the piece that turns `PdfDetectorFonts.swift`'s predicates into an
/// answer about a real page. It walks the page's content streams, collects
/// the names its `Tf` operators select, resolves those against the page's
/// resource chain, and asks the three questions.

/// A page's decoded content streams, kept **separate**.
///
/// The reference scans each stream on its own rather than concatenating, and
/// that difference is observable: an operator split across a stream boundary
/// is seen by neither side when the streams are scanned apart, and by a
/// concatenating scanner when they are joined. Producers do split streams
/// mid-operator, so this follows the reference.
func pdfPageContentStreams(_ document: inout PdfDocument, _ page: PdfDictionary) -> [[UInt8]] {
    if let single = document.value(page, "Contents")?.asStream {
        return document.decodedStream(single).map { [$0] } ?? []
    }
    guard let array = document.value(page, "Contents")?.asArray else { return [] }
    var streams: [[UInt8]] = []
    for entry in array {
        guard let stream = document.resolve(entry).asStream,
            let decoded = document.decodedStream(stream)
        else { continue }
        streams.append(decoded)
    }
    return streams
}

/// What a page's fonts say about whether its text can be read.
struct PdfPageFontVerdicts: Equatable {
    /// How many distinct font objects the page's `Tf` operators selected.
    var usedFontCount: Int = 0
    /// Every used font is Identity-H/V with no `/ToUnicode` and no fallback.
    var hasIdentityHNoToUnicode = false
    /// Every used font is a Type 3 without `/ToUnicode`.
    var hasOnlyType3Fonts = false
    /// At least one used font can produce Unicode.
    var hasDecodableTextFonts = false
}

/// Judge one page's fonts.
///
/// The three verdicts are **not** exclusive and are not a classification —
/// they are three separate questions the document-level detector weighs
/// against the page's text and image statistics. A page can have decodable
/// fonts and still need OCR, and a page with none may still be fine if it
/// draws no text at all.
func pdfPageFontVerdicts(_ document: inout PdfDocument, _ page: PdfDictionary)
    -> PdfPageFontVerdicts
{
    let chain = pdfPageResourceChain(&document, page)

    var used: Set<PdfObjectId> = []
    var characters: Set<UInt8> = []
    for stream in pdfPageContentStreams(&document, page) {
        var names: Set<[UInt8]> = []
        _ = pdfScanContentForTextOperators(
            stream, uniqueCharacters: &characters, usedFontNames: &names)
        pdfResolveFontNames(&document, chain: chain, names: names, into: &used)
    }

    var fonts: [PdfObjectId: PdfDetectorFontInfo] = [:]
    for resources in chain {
        pdfCollectFontsFromResources(&document, resources, into: &fonts)
    }

    return PdfPageFontVerdicts(
        usedFontCount: used.count,
        hasIdentityHNoToUnicode: pdfUsedFontsHaveIdentityHNoToUnicode(
            &document, used: used, fonts: fonts),
        hasOnlyType3Fonts: pdfUsedFontsAreOnlyType3(used: used, fonts: fonts),
        hasDecodableTextFonts: pdfUsedFontsHaveDecodableText(&document, used: used, fonts: fonts))
}
