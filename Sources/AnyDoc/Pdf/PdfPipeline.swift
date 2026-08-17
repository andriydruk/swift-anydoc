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
    var pageTables: [Int: [PdfPositionedMarkdown]] = [:]

    // A link is a rectangle plus an action and a field value lives off the
    // trailer, so neither is drawn by any content stream — they need their
    // own extraction and are folded in as items positioned at their
    // rectangles, exactly as the reference does.
    let pageNumbers = pdfPageNumbers(&document)
    let formFields = pdfFormFields(&document, pageNumbers: pageNumbers)

    // A tagged document says what its content means, and the writer prefers
    // those declarations to any geometric guess. An **empty** map becomes
    // nothing at all rather than an empty dictionary: the two differ
    // downstream, where the overuse audit returns before counting when there
    // are no roles but counts nothing when there is an empty map.
    let structRoles: PdfStructRoleMap? = pdfParseStructTree(&document)
        .map { pdfStructRoleMap($0, pageNumbers: pageNumbers) }
        .flatMap { $0.isEmpty ? nil : $0 }

    for (index, page) in pdfDocumentPages(&document).enumerated() {
        let number = index + 1
        var styles = pdfPageFontStyles(&document, page)
        let (pageOperations, formFonts) = pdfPageOperationsWithForms(&document, page)
        for (name, font) in formFonts { styles[name] = pdfFontStyle(&document, font) }
        let graphics = pdfExtractGraphics(pageOperations)

        // Letter-spaced runs are repaired before grouping, and the
        // threshold that repair measures becomes the page's join threshold —
        // a page set with wide tracking needs a wider gap to count as a word
        // break. The reference keeps the threshold only when it exceeds the
        // 0.10 default, and so does this.
        // Every pass below works on the **whole page**, before grouping,
        // and in the reference's order — which matters twice over. The table
        // detectors need every item on the page to find a grid at all; and
        // the letter-spacing measurement has to see merged words, not the
        // fragments a PDF draws them as.
        var items = pdfLayoutItems(pdfPageTextRuns(&document, page))
        pdfApplyFontStyles(&items, styles)
        pdfMarkUnderlines(
            &items, rectangles: pdfUnderlineInk(graphics), lines: graphics.lines)

        // A PDF does not draw words. `Hel`/`lo`/`wor`/`ld` at four explicit
        // positions is one word, and putting it back together is what these
        // two passes do — the second for the raised and lowered runs that
        // carry subscripts and footnote marks.
        items = pdfMergeTextItems(items)
        items = pdfMergeSubscriptItems(items)

        let measured = pdfFixLetterspacedItems(&items)
        let threshold = measured > 0.10 ? measured : 0.10

        // A ruled table's cell borders read as underlines on the text above
        // them, so the flags are cleared wherever a plausible table claims
        // the item.
        pdfSuppressTableUnderlines(
            &items, rects: graphics.rectangles, lines: graphics.lines)

        // Form-field values join *after* the passes above, which is the
        // reference's order — they are not text the page drew, so merging
        // and letter-spacing must not see them.
        //
        // **Links do not join at all.** The reference sorts them into a
        // separate stream and uses them to decorate matching text as
        // `[text](url)`; they never contribute text of their own, so
        // appending them here emitted a bare URL the reference never
        // prints. That decoration pass is unported, so a hyperlink
        // currently survives as plain text.
        items += formFields.filter { $0.page == number }.map(pdfAnnotationLayoutItem)

        // Tables are detected on the page's items and their cells are then
        // **withheld** from the text stream, so a table's contents do not
        // also appear as prose. The body size the heuristic detector
        // measures against is the document's, but nothing has read the
        // document yet at this point — so the page's own is used, which is
        // a divergence noted in PLAN.md and revisited when the analysis
        // moves ahead of the page loop.
        let pageBaseSize = pdfFontStatsFromItems(items).mostCommonSize
        let detected = pdfDetectPageTables(
            items: items, rects: graphics.rectangles, lines: graphics.lines,
            baseSize: pageBaseSize)
        if !detected.tables.isEmpty { pageTables[number] = detected.tables }
        let textItems = items.enumerated()
            .filter { !detected.claimed.contains($0.offset) }.map(\.element)

        // No chart regions: those need a detector this port has not wired to
        // a document yet. `pdfGroupPageIntoLines` accepts them the moment it
        // is available.
        lines.append(
            contentsOf: pdfGroupPageIntoLines(
                textItems, page: number, adaptiveThreshold: threshold,
                hasTable: !detected.tables.isEmpty))
    }

    // Running headers and footers, which the reference strips before
    // anything else when the option is on.
    if options.stripHeadersFooters {
        lines = pdfStripRepeatedLines(lines, pageCount: pdfDocumentPageCount(&document))
    }

    let analysis = pdfAnalyseDocument(lines, options: options, structRoles: structRoles)
    // No images and no band-split pages: image extraction and
    // `split_side_by_side`'s per-page wiring are still to come.
    return pdfWriteMarkdown(
        analysis, options: options, pageTables: pageTables, structRoles: structRoles)
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

/// A page's operations with every form XObject spliced in, and the fonts
/// those forms name.
///
/// A `Do` that invokes a form is replaced by the form's own content, so the
/// one content-stream walker sees everything the page draws — including the
/// text a producer factored out into a letterhead or a repeated block, which
/// is otherwise lost without a trace.
func pdfPageOperationsWithForms(
    _ document: inout PdfDocument, _ page: PdfDictionary
) -> (operations: [PdfOperation], fonts: [String: PdfDictionary]) {
    let resources = document.value(page, "Resources")?.asDictionary
    var formFonts: [String: PdfDictionary] = [:]
    let operations = pdfInlineFormXObjects(
        pdfPageOperations(&document, page), &document, resources: resources
    ) { name, font in formFonts[name] = font }
    return (operations, formFonts)
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

/// The `/Differences` encodings of a page's fonts, by resource name.
///
/// A simple font may say that code 65 draws `bullet` rather than `A`.
/// Without this the byte is taken at face value and the document reads as
/// whatever the codes happen to spell — `ABC` for `•—“`.
///
/// Only a dictionary `/Encoding` carries differences. A *named* one
/// (`/WinAnsiEncoding`) selects a standard table, which the reference leaves
/// to lopdf and this port does not implement — noted rather than silently
/// treated as Latin-1.
func pdfPageFontEncodings(_ document: inout PdfDocument, _ page: PdfDictionary)
    -> [String: PdfEncodingDifferences]
{
    pdfPageFontProperty(&document, page) { document, font in
        guard let encoding = document.value(font, "Encoding")?.asDictionary,
            let differences = document.value(encoding, "Differences")?.asArray
        else { return nil }
        let baseFont = document.value(font, "BaseFont")?.asName
            .map { String(decoding: $0, as: UTF8.self) }
        return pdfParseEncodingDifferences(differences, baseFontName: baseFont)
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
    var cmaps = pdfPageFontCMaps(&document, page)
    var metrics = pdfPageFontMetrics(&document, page)
    var encodings = pdfPageFontEncodings(&document, page)
    let (operations, formFonts) = pdfPageOperationsWithForms(&document, page)
    // A form's fonts join under the namespaced names its `Tf` operators were
    // rewritten to, so a `/F1` inside a form cannot pick up the page's `/F1`.
    for (name, font) in formFonts {
        if let toUnicode = document.value(font, "ToUnicode")?.asStream,
            let data = document.decodedStream(toUnicode)
        {
            cmaps[name] = parsePdfToUnicode(data)
        }
        if let widths = pdfParseFontWidths(&document, font) { metrics[name] = widths }
        if let encoding = document.value(font, "Encoding")?.asDictionary,
            let differences = document.value(encoding, "Differences")?.asArray
        {
            let baseFont = document.value(font, "BaseFont")?.asName
                .map { String(decoding: $0, as: UTF8.self) }
            encodings[name] = pdfParseEncodingDifferences(differences, baseFontName: baseFont)
        }
    }
    return pdfExtractTextRuns(operations, metrics: { metrics[$0] }) { fontName, bytes in
        guard let cmap = cmaps[fontName], !cmap.isEmpty else {
            // No usable `ToUnicode`. A `/Differences` encoding is the next
            // authority: it says what glyph each code draws, which is the
            // only thing that makes a re-encoded font readable.
            if let encoding = encodings[fontName], !encoding.map.isEmpty {
                var out = ""
                for byte in bytes {
                    if let scalar = encoding.map[byte] {
                        out.unicodeScalars.append(scalar)
                    } else {
                        out.unicodeScalars.append(Unicode.Scalar(byte))
                    }
                }
                return out
            }
            // Failing both, the bytes are their own code points — right for
            // the ASCII a simple font shows and wrong for anything else.
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

/// An annotation as a layout item, positioned at its rectangle.
///
/// Font size zero and an empty font name, as the reference sets them: these
/// are not glyphs anyone drew, and giving them a size would let them vote in
/// the document's body-size statistics.
func pdfAnnotationLayoutItem(_ annotation: PdfAnnotationItem) -> PdfLayoutItem {
    var item = PdfLayoutItem(
        text: annotation.text, x: annotation.x, y: annotation.y,
        width: annotation.width, fontSize: 0, fontName: "")
    item.height = annotation.height
    return item
}
