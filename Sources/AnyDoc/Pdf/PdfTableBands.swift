/// Splitting a page into vertical bands before detecting tables, ported from
/// the `band_specs` construction, `filter_rects_to_band`,
/// `filter_lines_to_band` and the merged-band retry in `markdown/mod.rs`.
///
/// **Why the cascade is not a page-level thing.** A two-column page has two
/// independent layouts side by side, and a detector shown both at once reads
/// across the gutter: the left column's rows line up with the right column's
/// rows, so the alignment heuristic sees a two-column table where there is
/// only prose. `split_side_by_side` finds the gutters; everything below runs
/// once per band.
///
/// `pdfSplitSideBySide` was ported long ago and had exactly one caller, the
/// complexity scorer. The table cascade never saw it — the ninth connection
/// gap, and the second in three waves found by reading a call site rather
/// than a function.
///
/// **The retry is the interesting half.** Band-splitting is a guess, and it
/// is wrong in one specific way: a genuinely borderless table's columns look
/// exactly like page-layout columns. So when a page was split and *no* band
/// found a table, the whole page is retried as one band — the table that was
/// invisible in the pieces reappears in the whole.

/// The rectangles overlapping a band.
///
/// A small rectangle needs only to touch the band, because a cell border
/// legitimately sits on a boundary. A rectangle as wide as the band itself —
/// a page-wide rule, a background fill — has to be **mostly** inside it, or
/// every band on the page would claim it.
func pdfRectsInBand(_ rects: [PdfRect], low: Float, high: Float) -> [PdfRect] {
    let bandWidth = high - low
    return rects.filter { rect in
        // A negative width is a rectangle drawn right-to-left, which is legal
        // and which producers emit.
        let xMinimum = rect.width >= 0 ? rect.x : rect.x + rect.width
        let xMaximum = rect.width >= 0 ? rect.x + rect.width : rect.x
        let width = xMaximum - xMinimum
        let overlap = min(xMaximum, high) - max(xMinimum, low)
        if overlap <= 0 { return false }
        return width < bandWidth * 0.7 ? true : overlap >= width * 0.7
    }
}

/// The line segments overlapping a band, which need only touch it — a rule is
/// one-dimensional and has no area to share out.
func pdfLinesInBand(_ lines: [PdfLineSegment], low: Float, high: Float) -> [PdfLineSegment] {
    lines.filter { min($0.x1, $0.x2) < high && max($0.x1, $0.x2) > low }
}

/// One band's inputs, and where its items came from on the page.
struct PdfTableBand {
    var items: [PdfLayoutItem]
    /// `indexMap[bandIndex]` is the page index of that item.
    var indexMap: [Int]
    var rects: [PdfRect]
    var lines: [PdfLineSegment]
}

/// Split a page into bands, or return the single whole-page band.
///
/// The 2pt margin keeps an item sitting exactly on a boundary from falling
/// out of both bands. The upper bound is exclusive and the lower inclusive,
/// so an item on an interior gutter lands in the band to its right — the
/// reference's asymmetry, and reproducing it matters where a column starts
/// precisely at the split.
func pdfTableBands(items: [PdfLayoutItem], rects: [PdfRect], lines: [PdfLineSegment])
    -> [PdfTableBand]
{
    let bands = pdfSplitSideBySide(items)
    if bands.isEmpty {
        return [
            PdfTableBand(items: items, indexMap: Array(items.indices), rects: rects, lines: lines)
        ]
    }
    let margin: Float = 2
    return bands.map { band in
        var subset: [PdfLayoutItem] = []
        var map: [Int] = []
        for (index, item) in items.enumerated()
        where item.x >= band.low - margin && item.x < band.high + margin {
            subset.append(item)
            map.append(index)
        }
        return PdfTableBand(
            items: subset, indexMap: map,
            rects: pdfRectsInBand(rects, low: band.low, high: band.high),
            lines: pdfLinesInBand(lines, low: band.low, high: band.high))
    }
}
