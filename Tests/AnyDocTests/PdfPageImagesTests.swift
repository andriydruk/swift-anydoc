import Testing

@testable import AnyDoc

/// The image thresholds, pinned at their exact boundaries.
///
/// The differential probe covers these against five real documents; these
/// pin the values either side of each threshold, which five documents
/// cannot. Both rules were measured load-bearing in wave 121 by removing
/// them and watching `image-tiled.pdf` and `image-in-form.pdf` diverge.
///
/// A first draft of this file asserted arithmetic on constants
/// (`threshold >= threshold`) and exercised none of the code. These build
/// real documents and run the real walker.
@Suite struct PdfPageImagesTests {
    /// A one-page document whose `/XObject` dictionary holds the given
    /// entries, written as raw PDF so the walker sees a genuine object graph.
    private func document(xobjects: [String], extraObjects: [String] = [])
        throws -> PdfDocument
    {
        let entries = xobjects.enumerated()
            .map { "/Im\($0.offset) \($0.offset + 4) 0 R" }.joined()
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]"
                + " /Resources << /XObject << \(entries) >> >> >>",
        ]
        objects.append(contentsOf: xobjects)
        objects.append(contentsOf: extraObjects)

        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        out += "startxref\n\(xref)\n%%EOF\n"
        return try PdfDocument(bytes: Array(out.utf8))
    }

    /// An image XObject of the given size. The stream is empty — the
    /// detector reads dimensions from the dictionary and never the pixels.
    private func image(_ width: Int, _ height: Int) -> String {
        "<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height)"
            + " /ColorSpace /DeviceGray /BitsPerComponent 8 /Length 0 >>\nstream\n\nendstream"
    }

    private func analyse(_ document: inout PdfDocument) -> PdfPageImageAnalysis {
        guard let page = pdfDocumentPages(&document).first else { return PdfPageImageAnalysis() }
        return pdfAnalyzePageImages(&document, page)
    }

    @Test func anImageAtExactlyTheThresholdIsATemplate() throws {
        // 1000 × 500 is 500,000 — the threshold itself, and the comparison
        // is `>=`, so this counts.
        var document = try document(xobjects: [image(1000, 500)])
        let analysis = analyse(&document)
        #expect(analysis.hasImages)
        #expect(analysis.totalArea == 500_000)
        #expect(analysis.hasTemplateImage)
    }

    @Test func oneShortOfTheThresholdIsNot() throws {
        var document = try document(xobjects: [image(1000, 499)])
        let analysis = analyse(&document)
        #expect(analysis.hasImages)
        #expect(analysis.totalArea == 499_000)
        #expect(!analysis.hasTemplateImage)
    }

    /// The tiled-scan rule. No tile is a template; four times the threshold
    /// in aggregate is. A JBIG2 scanner emits pages exactly this way.
    @Test func manySmallTilesBecomeATemplateInAggregate() throws {
        // Ten 500 × 400 tiles: 200,000 each, 2,000,000 together — exactly 4×.
        var document = try document(
            xobjects: Array(repeating: image(500, 400), count: 10))
        let analysis = analyse(&document)
        #expect(analysis.totalArea == 2_000_000)
        #expect(analysis.hasTemplateImage)
    }

    @Test func justUnderTheAggregateStaysUntriggered() throws {
        // Nine of the same tiles: 1,800,000, short of 2,000,000.
        var document = try document(
            xobjects: Array(repeating: image(500, 400), count: 9))
        let analysis = analyse(&document)
        #expect(analysis.totalArea == 1_800_000)
        #expect(!analysis.hasTemplateImage)
    }

    @Test func aPageWithNoXObjectsHasNoImages() throws {
        var document = try document(xobjects: [])
        let analysis = analyse(&document)
        #expect(!analysis.hasImages)
        #expect(analysis.totalArea == 0)
        #expect(!analysis.hasTemplateImage)
    }

    /// A missing `/Width` reads as zero rather than skipping the image: the
    /// page still counts as having one, which is what the detector acts on.
    @Test func anImageWithNoDimensionsStillCountsAsAnImage() throws {
        var document = try document(
            xobjects: ["<< /Type /XObject /Subtype /Image /Length 0 >>\nstream\n\nendstream"])
        let analysis = analyse(&document)
        #expect(analysis.hasImages)
        #expect(analysis.totalArea == 0)
    }
}
