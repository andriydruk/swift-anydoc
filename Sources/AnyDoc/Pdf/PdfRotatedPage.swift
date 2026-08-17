/// Reading a page whose text is drawn sideways, ported from
/// `correct_rotated_page` in `extractor/content_stream.rs`.
///
/// A landscape table, a rotated scan, a sideways appendix: the text matrix
/// turns 90°, so each line runs *up* the page. Every layout stage below —
/// line grouping, column detection, table geometry — assumes text runs left
/// to right, and reading rotated text without correcting it returns the
/// lines in column order, which is nonsense.
///
/// The fix is to swap the coordinate axes once, before any of that runs, so
/// the layout engine sees an ordinary landscape page.
///
/// **It is a vote, not a per-item test.** One rotated caption on an upright
/// page is a caption; a page is rotated only when about two thirds of its
/// text is. Swapping on a minority would scramble the majority.

/// Whether a page's text is rotated, from the per-run votes.
///
/// Two items minimum: a single run gives no evidence about a page.
func pdfPageTextIsRotated(_ items: [PdfLayoutItem]) -> Bool {
    guard items.count >= 2 else { return false }
    return items.count { $0.isRotated } * 3 >= items.count * 2
}

/// The same vote, on the runs as extraction produces them.
///
/// The correction happens **at the extraction layer**, as the reference
/// does it, so every consumer — the pipeline, the probes, anything added
/// later — sees squared-up coordinates. Applying it further downstream left
/// the lower-layer probes reading raw sideways items, which is how this was
/// caught.
func pdfRunsAreRotated(_ runs: [PdfTextRun]) -> Bool {
    guard runs.count >= 2 else { return false }
    return runs.count { $0.isRotated } * 3 >= runs.count * 2
}

/// Swap the axes of a rotated page's runs, in place.
func pdfCorrectRotatedRuns(_ runs: inout [PdfTextRun]) {
    for index in runs.indices {
        let newX = runs[index].y
        let newY = -runs[index].x
        runs[index].x = newX
        runs[index].y = newY
        if runs[index].width < 0.5 {
            let characters = Float(runs[index].text.unicodeScalars.count)
            runs[index].width = characters * runs[index].fontSize * 0.5
        }
    }
}

/// Swap the axes of a rotated page's text.
///
/// For the common 90° counter-clockwise case the device axes map to visual
/// ones as: increasing device *x* is visually **down**, increasing device
/// *y* is visually **right**. The layout engine sorts by descending y, so
/// the old x is negated to put the visual top first.
func pdfCorrectRotatedItems(_ items: inout [PdfLayoutItem]) {
    for index in items.indices {
        let newX = items[index].y
        let newY = -items[index].x
        items[index].x = newX
        items[index].y = newY
        // Rotated text loses its width: the advance is measured along the
        // matrix's x-axis, which now points down, so it scales to nothing.
        // Estimating it from the text matters more than it looks — without a
        // width the word joiner has no gap to reason about and runs the
        // page's lines together with no spaces at all.
        if items[index].width < 0.5 {
            let characters = Float(items[index].text.unicodeScalars.count)
            items[index].width = characters * items[index].fontSize * 0.5
        }
    }
}

/// The same swap for the page's rectangles.
///
/// A rectangle needs its far edge, not its origin: rotating the box moves
/// which corner is the anchor, and the extents exchange places.
func pdfCorrectRotatedRects(_ rects: inout [PdfRect]) {
    for index in rects.indices {
        let newX = rects[index].y
        let newY = -(rects[index].x + rects[index].width.magnitude)
        rects[index].x = newX
        rects[index].y = newY
        let width = rects[index].width
        rects[index].width = rects[index].height
        rects[index].height = width
    }
}

/// And for the stroked segments, which are two points and need no extent
/// bookkeeping.
func pdfCorrectRotatedLines(_ lines: inout [PdfLineSegment]) {
    for index in lines.indices {
        let x1 = lines[index].y1
        let y1 = -lines[index].x1
        let x2 = lines[index].y2
        let y2 = -lines[index].x2
        lines[index].x1 = x1
        lines[index].y1 = y1
        lines[index].x2 = x2
        lines[index].y2 = y2
    }
}
