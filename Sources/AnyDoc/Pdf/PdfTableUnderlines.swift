/// Underlines inside tables, ported from `suppress_table_underlines` in
/// `extractor/mod.rs`.
///
/// A ruled table's cell borders are strokes and fills like any other, so the
/// geometric underline detector reads the rule *under* a cell as an
/// underline *on* its text. Every cell of a bordered table comes out
/// `<u>`-wrapped. This runs after detection and clears the flags on any item
/// a table detector claims.
///
/// It is not free to apply: erasing the flag wherever a table is detected
/// erases legitimate underlines too, whenever the detector is wrong. So the
/// suppression is gated on the table being *plausible* — see below.

/// Whether a detected table looks like a real one rather than a detection
/// artifact.
///
/// A prose page with boxed callouts and stacked rules can detect as a
/// structurally rich table that swallows every item on the page — the
/// reference's own note records a 4×8 grid claiming 52 of 52 items, one
/// "cell" holding 806 characters of body text. Suppressing there erased
/// every underline on the page.
///
/// The gate is cell length: a real data cell is a short value, so a grid
/// where **30% or more** of its non-empty cells exceed a hundred characters
/// has captured flowing prose and is not believed. A table with no non-empty
/// cells at all is not believed either.
func pdfTableIsPlausible(_ table: PdfTable) -> Bool {
    // Characters, not bytes — the reference counts `chars()`.
    let lengths = table.cells.flatMap { $0 }
        .filter { !$0.rustTrim().isEmpty }
        .map { $0.unicodeScalars.count }
    if lengths.isEmpty { return false }
    let long = lengths.filter { $0 > 100 }.count
    return Float(long) < Float(lengths.count) * 0.3
}

/// Clear underline and strikeout flags on every item a plausible table
/// claims.
///
/// - Parameters:
///   - rects: the page's filled rectangles, for the rect detector.
///   - lines: the page's stroked segments, for the line detector.
func pdfSuppressTableUnderlines(
    _ items: inout [PdfLayoutItem], rects: [PdfRect], lines: [PdfLineSegment]
) {
    // Nothing to clear, and both detectors are expensive — so the common
    // page pays nothing.
    guard items.contains(where: { $0.isUnderline || $0.isStrikeout }) else { return }

    var claimed: Set<Int> = []
    if !rects.isEmpty {
        let detected = pdfDetectTablesFromRects(
            items: items,
            rects: rects.map { (x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        ).tables
        for table in detected where pdfTableIsPlausible(table) {
            claimed.formUnion(table.itemIndices)
        }
    }
    if !lines.isEmpty {
        for table in pdfDetectTablesFromLines(items: items, lines: lines)
        where pdfTableIsPlausible(table) {
            claimed.formUnion(table.itemIndices)
        }
    }

    for index in claimed where index < items.count {
        items[index].isUnderline = false
        items[index].isStrikeout = false
    }
}
