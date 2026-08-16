/// The pipeline: a PDF's bytes to Markdown.
///
/// This is the assembly the previous ninety-eight waves were building
/// towards. Everything it calls was ported and probed separately; what was
/// missing was the wiring, which until now lived in the test target as
/// scaffolding for the corpus suite.
///
/// **It is not `process_document` yet, and the difference is worth naming.**
/// The reference's pipeline classifies the document first (scanned, mixed or
/// text), retries extraction with invisible text when a mixed document
/// yields garbage, detects tables and images per page and interleaves them,
/// and reads the structure tree for tagged headings. None of that is here:
/// `detector.rs`'s document half, the table detectors' per-page wiring, and
/// `structure_tree.rs`'s `from_doc` are unported. What is here is the path a
/// plain text PDF takes, which is the majority of documents and the whole of
/// the byte-diff that can currently be run.
///
/// The unported stages are listed at their call sites below rather than
/// summarised, so that adding one is a local edit.

/// Convert a PDF to Markdown.
///
/// Returns an empty string for a document with no extractable text, which is
/// what a scanned page produces — the reference distinguishes that case with
/// its detector and reports it; this port cannot yet.
func pdfMarkdown(_ bytes: [UInt8], options: PdfMarkdownOptions = PdfMarkdownOptions())
    throws -> String
{
    var document = try PdfDocument(bytes: bytes)
    var lines: [PdfTextLine] = []

    for (index, page) in pdfDocumentPages(&document).enumerated() {
        let number = index + 1
        let styles = pdfPageFontStyles(&document, page)
        let graphics = pdfExtractGraphics(pdfPageOperations(&document, page))

        // Letter-spaced runs are repaired before grouping, and the
        // threshold that repair measures becomes the page's join threshold —
        // a page set with wide tracking needs a wider gap to count as a word
        // break. The reference keeps the threshold only when it exceeds the
        // 0.10 default, and so does this.
        var items = pdfLayoutItems(pdfPageTextRuns(&document, page))
        let measured = pdfFixLetterspacedItems(&items)
        let threshold = measured > 0.10 ? measured : 0.10

        // Emphasis and decoration are decided for the **whole page**, before
        // grouping. The table detectors need every item on the page to find
        // a grid at all — run per line, each sees one or two items and finds
        // nothing, which is how the first attempt at this silently did
        // nothing.
        pdfApplyFontStyles(&items, styles)
        pdfMarkUnderlines(
            &items, rectangles: pdfUnderlineInk(graphics), lines: graphics.lines)
        // A ruled table's cell borders read as underlines on the text above
        // them, so the flags are cleared wherever a plausible table claims
        // the item.
        pdfSuppressTableUnderlines(
            &items, rects: graphics.rectangles, lines: graphics.lines)

        // No chart regions and no table regions: both need detectors this
        // port has not wired to a document yet, so every page groups as
        // plain prose. `pdfGroupPageIntoLines` accepts them the moment they
        // are available.
        lines.append(
            contentsOf: pdfGroupPageIntoLines(
                items, page: number, adaptiveThreshold: threshold))
    }

    // Running headers and footers, which the reference strips before
    // anything else when the option is on.
    if options.stripHeadersFooters {
        lines = pdfStripRepeatedLines(lines, pageCount: pdfDocumentPageCount(&document))
    }

    // No structure roles: `structure_tree.rs`'s `from_doc` is unported, so a
    // tagged PDF is read as an untagged one — its headings come from the
    // visual heuristics rather than from its own declarations.
    let analysis = pdfAnalyseDocument(lines, options: options, structRoles: nil)
    // No tables, no images, no band-split pages, for the same reason.
    return pdfWriteMarkdown(analysis, options: options)
}

/// The pages of a document, in tree order.
///
/// Breadth-first with the children pushed at the front, which is depth-first
/// order in effect — the order the pages appear in the tree. The visit cap
/// is this port's own: a `/Kids` cycle would otherwise not terminate.
func pdfDocumentPages(_ document: inout PdfDocument) -> [PdfDictionary] {
    guard let catalog = document.catalog,
        let root = document.value(catalog, "Pages")?.asDictionary
    else { return [] }
    var out: [PdfDictionary] = []
    var queue: [PdfDictionary] = [root]
    var visited = 0
    while !queue.isEmpty, visited < 10_000 {
        let node = queue.removeFirst()
        visited += 1
        if node["Type"]?.asName == Array("Page".utf8) {
            out.append(node)
            continue
        }
        guard let kids = document.value(node, "Kids")?.asArray else { continue }
        var children: [PdfDictionary] = []
        for kid in kids {
            if let dictionary = document.resolve(kid).asDictionary { children.append(dictionary) }
        }
        queue.insert(contentsOf: children, at: 0)
    }
    return out
}

/// How many pages the document has.
func pdfDocumentPageCount(_ document: inout PdfDocument) -> Int {
    pdfDocumentPages(&document).count
}

/// A page's content operations, with a `/Contents` array concatenated.
///
/// The streams are joined with a newline, because two streams may split an
/// operator's operands from its name and running them together would fuse
/// the last token of one with the first of the next.
func pdfPageOperations(_ document: inout PdfDocument, _ page: PdfDictionary) -> [PdfOperation] {
    var data: [UInt8] = []
    if let single = document.value(page, "Contents")?.asStream {
        data = document.decodedStream(single) ?? []
    } else if let array = document.value(page, "Contents")?.asArray {
        for entry in array {
            guard let stream = document.resolve(entry).asStream,
                let decoded = document.decodedStream(stream)
            else { continue }
            data.append(contentsOf: decoded)
            data.append(0x0A)
        }
    }
    return pdfParseContentStream(data)
}

/// A page's fonts, by resource name, as some property of each.
private func pdfPageFontProperty<Value>(
    _ document: inout PdfDocument, _ page: PdfDictionary,
    _ property: (inout PdfDocument, PdfDictionary) -> Value?
) -> [String: Value] {
    var out: [String: Value] = [:]
    guard let resources = document.value(page, "Resources")?.asDictionary,
        let fonts = document.value(resources, "Font")?.asDictionary
    else { return out }
    for key in fonts.keys {
        let name = String(decoding: key, as: UTF8.self)
        guard let font = document.value(fonts, name)?.asDictionary else { continue }
        if let value = property(&document, font) { out[name] = value }
    }
    return out
}

/// The `ToUnicode` CMaps of a page's fonts, by resource name.
func pdfPageFontCMaps(_ document: inout PdfDocument, _ page: PdfDictionary)
    -> [String: PdfToUnicodeCMap]
{
    pdfPageFontProperty(&document, page) { document, font in
        guard let toUnicode = document.value(font, "ToUnicode")?.asStream,
            let data = document.decodedStream(toUnicode)
        else { return nil }
        return parsePdfToUnicode(data)
    }
}

/// The glyph metrics of a page's fonts, by resource name.
func pdfPageFontMetrics(_ document: inout PdfDocument, _ page: PdfDictionary)
    -> [String: PdfFontWidths]
{
    pdfPageFontProperty(&document, page) { document, font in
        pdfParseFontWidths(&document, font)
    }
}

/// The emphasis of a page's fonts, by resource name.
func pdfPageFontStyles(_ document: inout PdfDocument, _ page: PdfDictionary)
    -> [String: PdfFontStyle]
{
    pdfPageFontProperty(&document, page) { document, font in
        pdfFontStyle(&document, font)
    }
}

/// Every text run of a page, decoded through its fonts' `ToUnicode` CMaps.
func pdfPageTextRuns(_ document: inout PdfDocument, _ page: PdfDictionary) -> [PdfTextRun] {
    let cmaps = pdfPageFontCMaps(&document, page)
    let metrics = pdfPageFontMetrics(&document, page)
    let operations = pdfPageOperations(&document, page)
    return pdfExtractTextRuns(operations, metrics: { metrics[$0] }) { fontName, bytes in
        guard let cmap = cmaps[fontName] else {
            // With no CMap the bytes are their own code points, which is
            // right for the ASCII a simple font shows and wrong for
            // anything else — the reference's font fallbacks, which would
            // do better here, are unported.
            return String(decoding: bytes, as: UTF8.self)
        }
        var out = ""
        let width = cmap.codeByteLength
        var index = 0
        while index < bytes.count {
            var code: UInt32 = 0
            for offset in 0..<width where index + offset < bytes.count {
                code = (code << 8) | UInt32(bytes[index + offset])
            }
            out += cmap.lookup(code) ?? ""
            index += width
        }
        return out
    }
}
