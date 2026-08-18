// Run widths are absolute.
//
// A negative font size, or a transform that mirrors the x-axis, makes the
// advance run backwards. The run still covers that much of the page, and a
// negative width reaches column and table detection as a box whose edges are
// swapped.
//
// The Markdown for such a page is usually correct anyway, which is why this
// needed the `--underline` probe to find: one line of text does not care how
// wide it is.
import Testing

@testable import AnyDoc

@Suite struct PdfNegativeWidthTests {
    private func document(fontSize: String) -> [UInt8] {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]"
                + " /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            // Widths matter: without them the advance is zero and the test
            // would pass on both sides while measuring nothing.
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 32"
                + " /LastChar 126 /Widths [\(Array(repeating: "500", count: 95).joined(separator: " "))] >>",
        ]
        let content = "BT /F1 \(fontSize) Tf 72 700 Td (Negative size text.) Tj ET\n"
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")

        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        out += "startxref\n\(xref)\n%%EOF\n"
        return Array(out.utf8)
    }

    /// The same text at `-12` and `12` occupies the same width.
    @Test func aNegativeFontSizeStillYieldsAPositiveWidth() throws {
        var negative = try PdfDocument(bytes: document(fontSize: "-12"))
        let negativeRuns = pdfPageTextRuns(&negative, pdfDocumentPages(&negative)[0])
        #expect(negativeRuns.count == 1)
        #expect(negativeRuns[0].width > 0)

        var positive = try PdfDocument(bytes: document(fontSize: "12"))
        let positiveRuns = pdfPageTextRuns(&positive, pdfDocumentPages(&positive)[0])
        #expect(positiveRuns[0].width == negativeRuns[0].width)
    }
}
