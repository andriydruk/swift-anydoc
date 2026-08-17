import Foundation
import Testing

@testable import AnyDoc

/// The detector's effect on the pipeline: a scanned or image-based document
/// converts to nothing at all.
///
/// This is a behaviour worth a test of its own rather than only a corpus
/// entry, because the failure it prevents looks like success. Without the
/// short-circuit a scanned page yields whatever stray caption or page number
/// the extractor can scrape off it — a short, well-formed, entirely
/// misleading document. Emitting nothing says "this needs OCR"; emitting a
/// fragment says "here is your document".
@Suite struct PdfDetectorPipelineTests {
    /// A one-page document holding a single image of the given size and no
    /// text at all.
    private func imageOnlyDocument(width: Int, height: Int) -> [UInt8] {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]"
                + " /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height)"
                + " /ColorSpace /DeviceGray /BitsPerComponent 8 /Length 0 >>\nstream\n\nendstream",
        ]
        let content = "q 400 0 0 300 72 300 cm /Im0 Do Q\n"
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")

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
        return Array(out.utf8)
    }

    /// A page with an image and **no text operator at all** is `scanned`,
    /// not `imageBased`. The two differ by exactly that: `imageBased` means
    /// some text was drawn but not enough of it to read the document by.
    /// A first draft of this test asserted `imageBased` and was wrong about
    /// the reference — the corpus's `image-small.pdf` carries a caption,
    /// which is what puts it in the other class.
    @Test func anImageOnlyDocumentIsScannedAndConvertsToNothing() throws {
        let bytes = imageOnlyDocument(width: 1000, height: 800)

        var document = try PdfDocument(bytes: bytes)
        let detection = pdfDetectDocumentType(&document)
        #expect(detection.pdfType == .scanned)
        #expect(detection.confidence == 0.95)
        #expect(detection.ocrRecommended)
        #expect(detection.pagesNeedingOcr == [1])
        #expect(detection.ocrReasonsByPage[1] == [PdfOcrReason.scanned])

        // Both classes short-circuit, which is the behaviour under test.
        #expect(try pdfMarkdown(bytes).isEmpty)
    }

    /// The complement: a document with real text still converts. Without
    /// this, a short-circuit that fired on everything would pass the test
    /// above.
    @Test func aTextDocumentStillConverts() throws {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]"
                + " /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var content = ""
        for index in 0..<12 {
            content += "BT /F1 10 Tf 72 \(700 - index * 16) Td (Readable line \(index).) Tj ET\n"
        }
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")

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
        let bytes = Array(out.utf8)

        var document = try PdfDocument(bytes: bytes)
        #expect(pdfDetectDocumentType(&document).pdfType == .textBased)
        #expect(try pdfMarkdown(bytes).contains("Readable line 0."))
    }
}
