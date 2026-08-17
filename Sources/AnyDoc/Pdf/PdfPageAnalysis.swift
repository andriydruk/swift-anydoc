/// The whole of `analyze_page_content` from `detector.rs`: what a page
/// contains, and whether any of it can be read.
///
/// `PdfPageAnalysis` had no producer until wave 119 filled its font fields;
/// this completes it. The struct is the detector's per-page evidence, and
/// `pdfPageOcrReasons` — ported long before anything built one — is what
/// turns it into a verdict.
///
/// **Everything here is deliberately cheap.** The detector runs before
/// extraction to decide whether extraction is worth attempting, so it scans
/// content bytes for operator names rather than parsing them, and reads
/// image dimensions from dictionaries rather than decoding pixels.

/// Scan a resource dictionary's Form XObjects for text, recursively.
///
/// A form is a content stream with its own resources, so its `Tf` names
/// resolve in **its** scope, not the page's. Resolving them globally is the
/// bug the reference's comments call the P1/P2 fixes, and getting it wrong
/// makes a form's fonts either invisible or attributed to the wrong object.
func pdfScanXObjectsInResources(
    _ document: inout PdfDocument, _ resources: PdfDictionary,
    visited: inout Set<PdfObjectId>, characters: inout Set<UInt8>,
    used: inout Set<PdfObjectId>, fonts: inout [PdfObjectId: PdfDetectorFontInfo]
) -> PdfContentScan {
    var total = PdfContentScan()
    guard let xobjects = document.value(resources, "XObject")?.asDictionary else { return total }

    for key in xobjects.keys {
        guard let id = xobjects[key]?.asReference else { continue }
        if !visited.insert(id).inserted { continue }
        guard let stream = document.object(id).asStream,
            let subtype = document.value(stream.dict, "Subtype")?.asName
        else { continue }

        switch String(decoding: subtype, as: UTF8.self) {
        case "Form":
            guard let content = document.decodedStream(stream) else { continue }
            var names: Set<[UInt8]> = []
            let scan = pdfScanContentForTextOperators(
                content, uniqueCharacters: &characters, usedFontNames: &names)
            total.textOperators += scan.textOperators
            total.imageCount += scan.imageCount
            total.pathOperators += scan.pathOperators
            total.fontChanges += scan.fontChanges

            guard let formResources = document.value(stream.dict, "Resources")?.asDictionary
            else { continue }
            // Scoped to this form's own dictionary — one lookup, no chain,
            // because a form does not inherit the page's resources.
            for name in names {
                if let fontId = pdfLookupFontId(&document, formResources, name) {
                    used.insert(fontId)
                }
            }
            pdfCollectFontsFromResources(&document, formResources, into: &fonts)

            let nested = pdfScanXObjectsInResources(
                &document, formResources, visited: &visited, characters: &characters,
                used: &used, fonts: &fonts)
            total.textOperators += nested.textOperators
            total.imageCount += nested.imageCount
            total.pathOperators += nested.pathOperators
            total.fontChanges += nested.fontChanges

        case "Image":
            total.imageCount += 1

        default:
            break
        }
    }
    return total
}

/// Analyse one page.
func pdfAnalyzePageContent(_ document: inout PdfDocument, _ page: PdfDictionary)
    -> PdfPageAnalysis
{
    var scan = PdfContentScan()
    var characters: Set<UInt8> = []
    var used: Set<PdfObjectId> = []
    var fonts: [PdfObjectId: PdfDetectorFontInfo] = [:]

    let chain = pdfPageResourceChain(&document, page)

    for content in pdfPageContentStreams(&document, page) {
        var names: Set<[UInt8]> = []
        let one = pdfScanContentForTextOperators(
            content, uniqueCharacters: &characters, usedFontNames: &names)
        scan.textOperators += one.textOperators
        scan.imageCount += one.imageCount
        scan.pathOperators += one.pathOperators
        scan.fontChanges += one.fontChanges
        // Page content resolves against the whole chain, shadowing included.
        pdfResolveFontNames(&document, chain: chain, names: names, into: &used)
    }

    var visited: Set<PdfObjectId> = []
    for resources in chain {
        pdfCollectFontsFromResources(&document, resources, into: &fonts)
        let nested = pdfScanXObjectsInResources(
            &document, resources, visited: &visited, characters: &characters,
            used: &used, fonts: &fonts)
        scan.textOperators += nested.textOperators
        scan.imageCount += nested.imageCount
        scan.pathOperators += nested.pathOperators
        scan.fontChanges += nested.fontChanges
    }

    let images = pdfAnalyzePageImages(&document, page)
    let alphanumeric = UInt32(
        characters.filter {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
        }.count)

    // Text drawn as outlines. Each glyph costs ten to thirty path commands,
    // so a page of them runs to thousands with almost no text operators.
    //
    // The character count is the guard that makes this safe. A page with
    // real text *and* heavy decoration — rules, borders, charts — also has
    // many path operators, and only the outlined page has almost no distinct
    // letters to show for them.
    // `saturating_mul`: at overflow the bound becomes `UInt32.max`, which no
    // path count can exceed — so a page with absurdly many text operators is
    // never called vector text, which is the right way for it to fail.
    let product = scan.textOperators.multipliedReportingOverflow(by: 200)
    let textBound = product.overflow ? UInt32.max : product.partialValue
    let hasVectorText =
        scan.pathOperators >= 1000 && scan.pathOperators > textBound && alphanumeric < 30

    // Each font verdict is gated on the page drawing text at all: a page
    // with no `Tj` has no undecodable text, however bad its fonts look.
    let drawsText = scan.textOperators > 0

    return PdfPageAnalysis(
        textOperatorCount: scan.textOperators,
        hasImages: images.hasImages,
        hasTemplateImage: images.hasTemplateImage,
        uniqueTextCharacters: UInt32(characters.count),
        hasVectorText: hasVectorText,
        hasIdentityHNoToUnicode: drawsText
            && pdfUsedFontsHaveIdentityHNoToUnicode(&document, used: used, fonts: fonts),
        hasOnlyType3Fonts: drawsText && pdfUsedFontsAreOnlyType3(used: used, fonts: fonts),
        totalImageArea: images.totalArea,
        imageCount: scan.imageCount,
        uniqueAlphanumericCharacters: alphanumeric,
        pathOperatorCount: scan.pathOperators,
        fontChangeCount: scan.fontChanges,
        hasDecodableTextFonts: drawsText
            && pdfUsedFontsHaveDecodableText(&document, used: used, fonts: fonts))
}
