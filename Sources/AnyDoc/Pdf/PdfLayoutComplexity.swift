/// How complicated a document's layout is, ported from
/// `compute_layout_complexity` in `lib.rs` together with
/// `filter_rects_to_band` and `filter_lines_to_band` from `markdown/mod.rs`.
///
/// This is the summary the pipeline reports alongside the Markdown: which
/// pages hold tables, which hold columns, and whether either is true
/// anywhere. Callers use it to decide whether a document needs a
/// layout-aware path at all.
///
/// It is also the first thing in `lib.rs` this port reaches, and it runs
/// every table detector the project has: rect-based, line-based, and the
/// borderless heuristic, in that order, per band of a side-by-side page.

/// Which pages hold tables and which hold columns.
struct PdfLayoutComplexity: Equatable {
    /// True when any page has a table or more than one column.
    var isComplex = false
    /// Pages where a *data* table was found, in ascending order.
    var pagesWithTables: [Int] = []
    /// Pages where two or more text columns were detected.
    var pagesWithColumns: [Int] = []
}

/// Rectangles overlapping an x band.
///
/// A rectangle narrower than 70% of the band needs only to touch it — cell
/// borders and rules belong to whichever band they reach. A rectangle as
/// wide as the band or wider must be **mostly** inside it, so a page-spanning
/// frame is not claimed by both bands at once.
///
/// A negative width is normalised first, since a path may be drawn
/// right-to-left.
func pdfFilterRectsToBand(_ rects: [PdfRect], xLow: Float, xHigh: Float) -> [PdfRect] {
    let bandWidth = xHigh - xLow
    return rects.filter { rect in
        let minX = rect.width >= 0 ? rect.x : rect.x + rect.width
        let maxX = rect.width >= 0 ? rect.x + rect.width : rect.x
        let width = maxX - minX
        let overlap = min(maxX, xHigh) - max(minX, xLow)
        if overlap <= 0 { return false }
        if width < bandWidth * 0.7 { return true }
        return overlap >= width * 0.7
    }
}

/// Line segments overlapping an x band, by any amount at all.
///
/// Note this is the plain overlap test — no proportional rule as for
/// rectangles, so a full-width rule is claimed by every band it crosses.
func pdfFilterLinesToBand(_ lines: [PdfLineSegment], xLow: Float, xHigh: Float)
    -> [PdfLineSegment]
{
    lines.filter { min($0.x1, $0.x2) < xHigh && max($0.x1, $0.x2) > xLow }
}

/// Measure a document's layout.
///
/// The reference holds one flat array of items carrying page numbers; this
/// port takes them already grouped, which is the same thing with the filter
/// lifted out. Font statistics are still measured across *every* page, since
/// the body size is a document-wide property.
///
/// - Parameters:
///   - itemsByPage: text items, keyed by page.
///   - rectsByPage: filled rectangles from the page's paths.
///   - linesByPage: stroked segments from the page's paths.
func pdfLayoutComplexity(
    itemsByPage: [Int: [PdfLayoutItem]],
    rectsByPage: [Int: [PdfRect]] = [:],
    linesByPage: [Int: [PdfLineSegment]] = [:]
) -> PdfLayoutComplexity {
    let pages = itemsByPage.keys.sorted()
    var allItems: [PdfLayoutItem] = []
    for page in pages { allItems.append(contentsOf: itemsByPage[page] ?? []) }
    let baseSize = pdfFontStatsFromItems(allItems).mostCommonSize

    var pagesWithTables: [Int] = []
    for page in pages {
        let pageItems = itemsByPage[page] ?? []
        let pageRects = rectsByPage[page] ?? []
        let pageLines = linesByPage[page] ?? []

        // A side-by-side page is searched band by band, because a table in
        // one half is invisible to a detector reading the whole width.
        let bands = pdfSplitSideBySide(pageItems)
        // No bands means one region — the sentinel range that includes
        // everything, which the filters below are bypassed for entirely.
        let wholePage = bands.isEmpty

        var foundTable = false
        for band in (wholePage ? [(low: Float(0), high: Float(0))] : bands) {
            let bandItems: [PdfLayoutItem]
            let bandRects: [PdfRect]
            let bandLines: [PdfLineSegment]
            if wholePage {
                bandItems = pageItems
                bandRects = pageRects
                bandLines = pageLines
            } else {
                // Two points of slack on each side, matching the reference.
                let margin: Float = 2
                bandItems = pageItems.filter {
                    $0.x >= band.low - margin && $0.x < band.high + margin
                }
                bandRects = pdfFilterRectsToBand(pageRects, xLow: band.low, xHigh: band.high)
                bandLines = pdfFilterLinesToBand(pageLines, xLow: band.low, xHigh: band.high)
            }

            // Only a *data* table counts. A table of contents routes through
            // the same detector and renders as a flat list, so counting it
            // would both misreport the layout and trip the table guard in
            // column detection below.
            func hasDataTable(_ tables: [PdfTable]) -> Bool {
                tables.contains { $0.kind == .data }
            }

            let rectTables = pdfDetectTablesFromRects(
                items: bandItems,
                rects: bandRects.map { (x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            ).tables
            if hasDataTable(rectTables) {
                foundTable = true
                break
            }
            if hasDataTable(pdfDetectTablesFromLines(items: bandItems, lines: bandLines)) {
                foundTable = true
                break
            }
            // The borderless fallback, last because it is the guessiest.
            if hasDataTable(pdfDetectTables(bandItems, baseFontSize: baseSize)) {
                foundTable = true
                break
            }
        }
        if foundTable { pagesWithTables.append(page) }
    }

    // Column detection is told whether the page has a table, because a
    // table's columns are not the page's columns.
    var pagesWithColumns: [Int] = []
    for page in pages {
        let columns = pdfDetectColumns(
            itemsByPage[page] ?? [], pageHasTable: pagesWithTables.contains(page))
        if columns.count >= 2 { pagesWithColumns.append(page) }
    }

    return PdfLayoutComplexity(
        isComplex: !pagesWithTables.isEmpty || !pagesWithColumns.isEmpty,
        pagesWithTables: pagesWithTables,
        pagesWithColumns: pagesWithColumns)
}
