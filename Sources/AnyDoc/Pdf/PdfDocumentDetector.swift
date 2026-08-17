/// What kind of PDF this is, and which of its pages need OCR — ported from
/// `detect_from_document` in `detector.rs`.
///
/// This is the spine `PLAN.md` names: everything since wave 119 has been
/// building the per-page evidence this weighs. The reference runs it *before*
/// extraction to decide whether extraction is worth attempting at all, and a
/// port without it converts every document as though it were text, including
/// the scans where there is no text to convert.
///
/// **The classification is deliberately not a majority vote.** Four phases
/// run in order: classify the document, then list the pages needing OCR, then
/// add pages whose fonts cannot decode whatever they draw, then explain each
/// one. A page can be flagged by the third phase after the first called the
/// document text-based, which is the case that matters — a mostly-fine
/// document with two unreadable pages.

/// The four kinds.
enum PdfType: String, Equatable {
    case textBased
    case scanned
    case imageBased
    case mixed
}

/// Which pages to look at.
enum PdfScanStrategy: Equatable {
    /// Every page, stopping at the first non-text one.
    case earlyExit
    /// Every page, no early exit — the accurate choice for telling mixed
    /// documents from scanned ones.
    case full
    /// Up to `n` pages spread evenly, first and last always included.
    case sample(UInt32)
    /// These 1-indexed pages and no others.
    case pages([UInt32])
}

/// How the detector is tuned.
struct PdfDetectionConfig {
    var strategy: PdfScanStrategy = .sample(8)
    var minimumTextOperatorsPerPage: UInt32 = 3
    var textPageRatioThreshold: Float = 0.6

    /// The reference's default. Sampling eight beats early exit because a
    /// report with an image-only cover would otherwise be judged on its
    /// cover alone.
    init() {}
}

/// What the detector concluded.
struct PdfTypeResult: Equatable {
    var pdfType: PdfType = .textBased
    var pageCount: UInt32 = 0
    var pagesSampled: UInt32 = 0
    var pagesWithText: UInt32 = 0
    var confidence: Float = 0
    var title: String?
    /// Whether the images carry meaning the text alone does not.
    var ocrRecommended = false
    /// 1-indexed pages needing OCR: empty when text-based, every page when
    /// scanned, and a specific list when mixed.
    var pagesNeedingOcr: [UInt32] = []
    /// Why each of those pages needs it.
    var ocrReasonsByPage: [UInt32: [String]] = [:]
}

/// The document's `/Title`, if it has one.
///
/// A UTF-16BE byte-order mark is honoured; anything else is read as UTF-8
/// lossily, which is what the reference does and what most producers write.
func pdfDocumentTitle(_ document: inout PdfDocument) -> String? {
    guard let entry = document.trailer["Info"],
        let info = document.resolve(entry).asDictionary,
        let bytes = document.value(info, "Title")?.asStringBytes
    else { return nil }

    if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
        var scalars = String.UnicodeScalarView()
        var index = 2
        while index + 1 < bytes.count {
            let unit = UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            scalars.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
            index += 2
        }
        return String(scalars)
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Classify a document and say which pages need OCR.
func pdfDetectDocumentType(
    _ document: inout PdfDocument, config: PdfDetectionConfig = PdfDetectionConfig()
) -> PdfTypeResult {
    let pages = pdfDocumentPages(&document)
    let totalPages = UInt32(pages.count)

    let sampleIndices: [UInt32]
    let allowEarlyExit: Bool
    switch config.strategy {
    case .earlyExit:
        sampleIndices = totalPages == 0 ? [] : Array(1...totalPages)
        allowEarlyExit = true
    case .full:
        sampleIndices = totalPages == 0 ? [] : Array(1...totalPages)
        allowEarlyExit = false
    case .sample(let maximum):
        sampleIndices = pdfDistributePages(min(maximum, totalPages), total: totalPages)
        allowEarlyExit = false
    case .pages(let requested):
        sampleIndices = Array(Set(requested.filter { $0 >= 1 && $0 <= totalPages })).sorted()
        allowEarlyExit = false
    }

    var pagesWithText: UInt32 = 0
    var pagesWithImages: UInt32 = 0
    var pagesWithTemplateImages: UInt32 = 0
    var pagesWithVectorText: UInt32 = 0
    var totalTextOperators: UInt32 = 0
    var cache: [UInt32: PdfPageAnalysis] = [:]
    var pagesSampled: UInt32 = 0

    /// A page is a scan rather than a page with figures when there is one
    /// image, little text, and few distinct letters — unless its fonts are
    /// decodable CID fonts, which produce almost no recognisable raw bytes
    /// while extracting perfectly.
    func looksLikeAScan(_ analysis: PdfPageAnalysis) -> Bool {
        let alphanumericLow =
            analysis.uniqueAlphanumericCharacters < 10
            && !(analysis.hasDecodableTextFonts && analysis.textOperatorCount >= 10)
        return analysis.imageCount <= 1 && analysis.textOperatorCount < 50 && alphanumericLow
    }

    for number in sampleIndices {
        guard Int(number) - 1 < pages.count else { continue }
        let analysis = pdfAnalyzePageContent(&document, pages[Int(number) - 1])
        pagesSampled += 1

        let imageDominated =
            analysis.imageCount > 10
            && analysis.imageCount > analysis.textOperatorCount.multipliedReportingOverflow(by: 3)
                .partialValue
        // A page carrying images has to show more text before it counts as a
        // text page: a scan with an OCR overlay has a little text on it too.
        let minimumOperators =
            (analysis.hasImages || analysis.imageCount > 0)
            ? max(config.minimumTextOperatorsPerPage, 10) : config.minimumTextOperatorsPerPage

        if analysis.textOperatorCount >= minimumOperators && !imageDominated
            && analysis.uniqueTextCharacters >= 5 && !analysis.hasVectorText
            && !analysis.hasOnlyType3Fonts
        {
            pagesWithText += 1
        }
        if analysis.hasImages { pagesWithImages += 1 }
        if analysis.hasTemplateImage && looksLikeAScan(analysis) { pagesWithTemplateImages += 1 }
        if analysis.hasVectorText { pagesWithVectorText += 1 }
        totalTextOperators += analysis.textOperatorCount
        cache[number] = analysis

        if allowEarlyExit
            && (analysis.textOperatorCount < config.minimumTextOperatorsPerPage || imageDominated
                || analysis.uniqueTextCharacters < 5)
            && (analysis.hasImages || analysis.hasTemplateImage)
        {
            break
        }
    }

    let textRatio = pagesSampled > 0 ? Float(pagesWithText) / Float(pagesSampled) : 0
    let templateRatio =
        pagesSampled > 0 ? Float(pagesWithTemplateImages) / Float(pagesSampled) : 0
    let hasTemplateImages = pagesWithTemplateImages > 0

    var pdfType: PdfType
    var confidence: Float
    var ocrRecommended: Bool

    if hasTemplateImages && pagesWithText > 0 {
        // A template document: real text over a background that carries
        // meaning of its own, so the text alone is not the document.
        pdfType = .mixed
        confidence = 0.5 + 0.3 * (1 - templateRatio)
        ocrRecommended = true
    } else if textRatio >= config.textPageRatioThreshold {
        pdfType = .textBased
        confidence = textRatio
        ocrRecommended = false
    } else if pagesWithText == 0 && (pagesWithImages > 0 || pagesWithVectorText > 0) {
        ocrRecommended = true
        if totalTextOperators == 0 && pagesWithVectorText == 0 {
            pdfType = .scanned
            confidence = 0.95
        } else {
            pdfType = .imageBased
            confidence = 0.8
        }
    } else if pagesWithText > 0 && (pagesWithImages > 0 || pagesWithVectorText > 0) {
        pdfType = .mixed
        confidence = 0.7
        ocrRecommended = true
    } else if totalTextOperators == 0 {
        pdfType = .scanned
        confidence = 0.9
        ocrRecommended = true
    } else {
        pdfType = .textBased
        confidence = max(textRatio, 0.5)
        ocrRecommended = false
    }

    // A newspaper extracts fine and reads terribly: dense interleaved columns
    // that come out as spliced sentences. Density alone would also catch a
    // heavily styled contract, so the discriminator is the ratio of font
    // changes to text operators — a newspaper switches font rarely per unit
    // of prose, a styled document switches constantly.
    if pdfType == .textBased && pagesSampled >= 3 {
        var newspaperPages: UInt32 = 0
        for analysis in cache.values {
            let ratio =
                analysis.textOperatorCount > 0
                ? Float(analysis.fontChangeCount) / Float(analysis.textOperatorCount) : 1
            if analysis.textOperatorCount >= 1500 && analysis.fontChangeCount >= 50
                && ratio < 0.15
            {
                newspaperPages += 1
            }
        }
        if Float(newspaperPages) / Float(pagesSampled) >= 0.5 { ocrRecommended = true }
    }

    // Phase 2: which pages need OCR.
    var needingOcr: [UInt32] = []
    switch pdfType {
    case .textBased:
        break
    case .scanned, .imageBased:
        if totalPages > 0 { needingOcr = Array(1...totalPages) }
    case .mixed:
        for number in 1...max(totalPages, 1) where totalPages > 0 {
            let analysis: PdfPageAnalysis
            if let cached = cache[number] {
                analysis = cached
            } else if Int(number) - 1 < pages.count {
                // Cached so the explanation phase sees the real signals
                // rather than defaulting to `scanned`.
                analysis = pdfAnalyzePageContent(&document, pages[Int(number) - 1])
                cache[number] = analysis
            } else {
                continue
            }
            if (analysis.hasTemplateImage && looksLikeAScan(analysis)) || analysis.hasVectorText
                || (analysis.textOperatorCount < config.minimumTextOperatorsPerPage
                    && analysis.hasImages)
            {
                needingOcr.append(number)
            }
        }
    }

    // Phase 3: pages whose fonts cannot decode what they draw, whatever the
    // document as a whole was called. This is the phase that catches two bad
    // pages in an otherwise readable file.
    for (number, analysis) in cache
    where
        (analysis.hasIdentityHNoToUnicode || analysis.hasOnlyType3Fonts)
        && !needingOcr.contains(number)
    {
        needingOcr.append(number)
    }
    if needingOcr.count < Int(totalPages) && totalPages > 0 {
        for number in 1...totalPages {
            if cache[number] != nil || needingOcr.contains(number) { continue }
            guard Int(number) - 1 < pages.count else { continue }
            let analysis = pdfAnalyzePageContent(&document, pages[Int(number) - 1])
            if analysis.hasIdentityHNoToUnicode || analysis.hasOnlyType3Fonts {
                needingOcr.append(number)
                cache[number] = analysis
            }
        }
    }
    needingOcr = Array(Set(needingOcr)).sorted()

    // Phase 4: explain each. A page flagged only by the whole-document
    // classification was never analysed, so `scanned` is all that can be said.
    var reasons: [UInt32: [String]] = [:]
    for number in needingOcr {
        reasons[number] = cache[number].map(pdfPageOcrReasons) ?? [PdfOcrReason.scanned]
    }

    return PdfTypeResult(
        pdfType: pdfType, pageCount: totalPages, pagesSampled: pagesSampled,
        pagesWithText: pagesWithText, confidence: confidence,
        title: pdfDocumentTitle(&document), ocrRecommended: ocrRecommended,
        pagesNeedingOcr: needingOcr, ocrReasonsByPage: reasons)
}
