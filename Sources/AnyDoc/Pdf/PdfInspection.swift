/// What a PDF turned out to be, alongside the Markdown it converted to.
///
/// The reference returns a `PdfProcessResult` from every conversion; this
/// port returned a bare `String`, and once wave 123 wired the detector in
/// that became a real gap rather than a cosmetic one. A scanned document and
/// an empty one both convert to `""`, and a caller with only the string
/// cannot tell "this needs OCR" from "there was nothing here" — which is the
/// single most useful thing the detector knows.

/// A PDF's kind and what it would take to read it.
public struct PdfInspection: Sendable, Hashable {
    /// What kind of document this is.
    public enum Kind: String, Sendable, Hashable {
        /// Extractable text throughout.
        case textBased
        /// Images only — a scan, with no text layer at all.
        case scanned
        /// Some text, but not enough to read the document by.
        case imageBased
        /// Text pages and image pages together, or text over meaningful
        /// backgrounds.
        case mixed
    }

    public var kind: Kind
    public var pageCount: Int
    /// How sure the classification is, from 0 to 1.
    public var confidence: Float
    /// The `/Title` from the document information dictionary.
    public var title: String?
    /// Whether running OCR would recover something the text layer does not
    /// already give. True for scans, and also for documents that extract
    /// cleanly but read badly — a newspaper's interleaved columns, say.
    public var ocrRecommended: Bool
    /// 1-indexed pages that need OCR. Empty for a text-based document, every
    /// page for a scan, and a specific list for a mixed one.
    public var pagesNeedingOcr: [Int]
    /// Why each of those pages needs it: `scanned`, `no_text`,
    /// `vector_text`, or `suspected_garbled_text`.
    public var ocrReasonsByPage: [Int: [String]]

    /// Whether the conversion produced no Markdown *because* the document
    /// has no text layer, rather than because it was empty.
    ///
    /// This is the question the bare string could not answer.
    public var isUnreadableWithoutOcr: Bool { kind == .scanned || kind == .imageBased }
}

extension AnyDoc {
    /// Inspect a PDF without converting it.
    ///
    /// Cheap by design: the detector scans content streams for operator
    /// names and reads image dimensions from dictionaries, without decoding
    /// glyphs or pixels. The reference runs exactly this before deciding
    /// whether extraction is worth attempting.
    ///
    /// **This is the detector's view, taken before any text is decoded**, so
    /// it cannot see a document whose text extracts to rubbish — that is
    /// only knowable after extraction, and `markdownInspectingPdf` reports
    /// it. A document of undecodable fonts is `textBased` here and flagged
    /// for OCR there, and the difference is information rather than
    /// disagreement.
    public static func inspectPdf(_ bytes: [UInt8]) throws -> PdfInspection {
        var document = try PdfDocument(bytes: bytes)
        return pdfInspection(pdfDetectDocumentType(&document))
    }

    /// Convert a PDF and report what it was.
    ///
    /// The Markdown is empty for a scanned or image-based document — the
    /// same value `markdown(_:format:)` returns — but the inspection says
    /// why, so a caller can route the document to OCR instead of treating
    /// the empty string as a successful conversion.
    public static func markdownInspectingPdf(_ bytes: [UInt8]) throws
        -> (markdown: String, inspection: PdfInspection)
    {
        let converted = try pdfConvert(bytes)
        return (converted.markdown, pdfInspection(converted.detection))
    }
}

/// Map the internal detector result onto the public shape.
func pdfInspection(_ result: PdfTypeResult) -> PdfInspection {
    var reasons: [Int: [String]] = [:]
    for (page, list) in result.ocrReasonsByPage { reasons[Int(page)] = list }
    return PdfInspection(
        kind: PdfInspection.Kind(rawValue: result.pdfType.rawValue) ?? .textBased,
        pageCount: Int(result.pageCount),
        confidence: result.confidence,
        title: result.title,
        ocrRecommended: result.ocrRecommended,
        pagesNeedingOcr: result.pagesNeedingOcr.map(Int.init),
        ocrReasonsByPage: reasons)
}
