// Inherited `/Resources`, and the one form of it the reference cannot see.
//
// A page inherits `/Resources` from its `/Pages` ancestors (ISO 32000-1
// §7.7.3.4), however the attribute is written. The reference inherits it only
// when it is an **indirect reference**: lopdf's `get_page_resources` collects
// ancestors through `Object::as_reference`, so a dictionary spelled inline in
// the `/Pages` node yields nothing. Every reference path — page fonts, page
// analysis, the extractor — inherits through that one function, so the
// blindness is uniform, and `pdfPageResourceChain` reproduces it.
//
// The two documents here differ in exactly one byte range: whether the root's
// `/Resources` is `<< /Font ... >>` or `5 0 R`. Everything else — the tree
// depth, the content stream, the font — is identical, so a chain that ignored
// the distinction would fail one of these.
import Testing

@testable import AnyDoc

/// A three-level page tree whose *root* carries the only `/Resources`.
///
/// - Parameter referenced: whether the root writes it as `5 0 R` rather than
///   inline. This is the whole of the difference under test.
private func inheritedResourceDocument(referenced: Bool) -> [UInt8] {
    let rootResources = referenced ? "5 0 R" : "<< /Font << /F1 6 0 R >> >>"
    let content = "BT /F1 24 Tf 72 700 Td (Inherited.) Tj ET\n"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [7 0 R] /Count 1 /MediaBox [0 0 612 792]"
            + " /Resources \(rootResources) >>",
        "<< /Type /Page /Parent 7 0 R /Contents 4 0 R >>",
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
        "<< /Font << /F1 6 0 R >> >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        // The middle node, holding nothing of its own: the page's resources
        // are two levels up, so a walk that stopped at the parent would miss
        // them even in the referenced case.
        "<< /Type /Pages /Parent 2 0 R /Kids [3 0 R] /Count 1 >>",
    ]

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

@Suite struct PdfInheritedResourceTests {
    /// Written as a reference, the ancestor's resources are inherited — the
    /// page finds its font two levels up.
    @Test func aReferencedAncestorResourceDictionaryIsInherited() throws {
        var document = try PdfDocument(bytes: inheritedResourceDocument(referenced: true))
        let pages = pdfDocumentPages(&document)
        #expect(pages.count == 1)

        #expect(pdfPageResourceChain(&document, pages[0]).count == 1)
        #expect(pdfPageFontVerdicts(&document, pages[0]).usedFontCount == 1)
    }

    /// Written inline, it is invisible. Not the specification — deliberate
    /// agreement with the reference, and the reason `inherited-page-tree.pdf`
    /// is in the corpus.
    @Test func anInlineAncestorResourceDictionaryIsNotInherited() throws {
        var document = try PdfDocument(bytes: inheritedResourceDocument(referenced: false))
        let pages = pdfDocumentPages(&document)
        #expect(pages.count == 1)

        #expect(pdfPageResourceChain(&document, pages[0]).isEmpty)
        #expect(pdfPageFontVerdicts(&document, pages[0]).usedFontCount == 0)
    }

    /// The page's own `/Resources` is read either way — lopdf takes an inline
    /// dictionary directly and picks a reference up in the same walk. Without
    /// this, narrowing the ancestor rule to "references only" could have been
    /// applied to the page itself and gone unnoticed.
    @Test func aPageOwnResourceDictionaryIsReadInEitherForm() throws {
        for inline in [true, false] {
            let resources = inline ? "<< /Font << /F1 4 0 R >> >>" : "5 0 R"
            let content = "BT /F1 24 Tf 72 700 Td (Own.) Tj ET\n"
            let objects = [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]"
                    + " /Resources \(resources) /Contents 6 0 R >>",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                "<< /Font << /F1 4 0 R >> >>",
                "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            ]
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

            var document = try PdfDocument(bytes: Array(out.utf8))
            let pages = pdfDocumentPages(&document)
            #expect(pdfPageResourceChain(&document, pages[0]).count == 1)
            #expect(pdfPageFontVerdicts(&document, pages[0]).usedFontCount == 1)
        }
    }
}
