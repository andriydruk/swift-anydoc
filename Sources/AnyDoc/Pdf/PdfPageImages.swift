/// A page's images, measured rather than merely counted — ported from
/// `analyze_page_images` and `collect_images_from_resources` in
/// `detector.rs`.
///
/// The detector needs image *area*, not an image count, because the question
/// it answers is "is this page a picture of a document?". One image covering
/// half the page is a scan; a dozen small ones are illustrations. The
/// threshold is 500,000 pixels — about half a US Letter page at 150 DPI.
///
/// **Tiled scans are the case that makes area the right measure.** A JBIG2
/// scanner emits the page as horizontal strips, none of them individually
/// large enough to look like a template. Their total is unmistakable, so
/// four times the threshold in aggregate counts as one too.

/// Half a page at 150 DPI, roughly: `612 × 792 / 2 × (150/72)²` is about a
/// million pixels, and this is deliberately well under that.
private let pdfTemplateImageThreshold: UInt64 = 500_000

/// What a page's images amount to.
struct PdfPageImageAnalysis: Equatable {
    var hasImages = false
    var totalArea: UInt64 = 0
    var hasTemplateImage = false
}

/// Walk a resource dictionary's XObjects, adding up image area.
///
/// Recurses into Form XObjects, which have resources of their own, and keeps
/// a `visited` set — a form may legally reference itself, and a document
/// built to be hostile will.
func pdfCollectImagesFromResources(
    _ document: inout PdfDocument, _ resources: PdfDictionary,
    into analysis: inout PdfPageImageAnalysis, visited: inout Set<PdfObjectId>
) {
    guard let xobjects = document.value(resources, "XObject")?.asDictionary else { return }

    for key in xobjects.keys {
        guard let id = xobjects[key]?.asReference else { continue }
        if !visited.insert(id).inserted { continue }
        guard let stream = document.object(id).asStream,
            let subtype = document.value(stream.dict, "Subtype")?.asName
        else { continue }

        switch String(decoding: subtype, as: UTF8.self) {
        case "Image":
            analysis.hasImages = true
            // A missing dimension counts as zero rather than skipping the
            // image: the reference reads it as 0 and still marks the page as
            // having images, which is the part that matters downstream.
            let width = UInt64(max(0, document.value(stream.dict, "Width")?.asInteger ?? 0))
            let height = UInt64(max(0, document.value(stream.dict, "Height")?.asInteger ?? 0))
            let area = width * height
            analysis.totalArea += area
            if area >= pdfTemplateImageThreshold { analysis.hasTemplateImage = true }

        case "Form":
            if let formResources = document.value(stream.dict, "Resources")?.asDictionary {
                pdfCollectImagesFromResources(
                    &document, formResources, into: &analysis, visited: &visited)
            }

        default:
            break
        }
    }
}

/// Measure one page's images.
///
/// Only the page's **own** `/Resources` is read — no inheritance walk. That
/// differs from the font path deliberately: the reference reads
/// `page_dict.get(b"Resources")` directly here while using
/// `get_page_resources` there, and reproducing the asymmetry matters for a
/// page that inherits its XObjects from a `/Pages` node.
func pdfAnalyzePageImages(_ document: inout PdfDocument, _ page: PdfDictionary)
    -> PdfPageImageAnalysis
{
    var analysis = PdfPageImageAnalysis()
    var visited: Set<PdfObjectId> = []

    guard let resources = document.value(page, "Resources")?.asDictionary else {
        return analysis
    }
    pdfCollectImagesFromResources(&document, resources, into: &analysis, visited: &visited)

    // Tiling patterns hold XObjects too. Chrome's "Save as PDF" pastes a
    // screenshot this way, so a page that is visibly one big image can carry
    // no XObject at all at the top level.
    if let patterns = document.value(resources, "Pattern")?.asDictionary {
        for key in patterns.keys {
            guard let id = patterns[key]?.asReference else { continue }
            if !visited.insert(id).inserted { continue }
            guard let stream = document.object(id).asStream,
                let patternResources = document.value(stream.dict, "Resources")?.asDictionary
            else { continue }
            pdfCollectImagesFromResources(
                &document, patternResources, into: &analysis, visited: &visited)
        }
    }

    // The tiled-scan rule: no single tile is a template, but their total is.
    if !analysis.hasTemplateImage && analysis.totalArea >= pdfTemplateImageThreshold * 4 {
        analysis.hasTemplateImage = true
    }
    return analysis
}
