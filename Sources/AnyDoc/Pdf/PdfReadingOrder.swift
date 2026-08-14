/// The leaves of image-anchored reading order, ported from
/// `extractor/reading_order.rs`: `page_x_bounds`, `group_rows`,
/// `side_is_prose` and `aligned_row_split`.
///
/// Column detection asks one question of the whole page. That fails on a page
/// where the flow changes partway down — two columns beside a figure, then
/// full-width text below it — because the whole-page projection sees both
/// shapes at once and resolves neither. Reading order answers it locally
/// instead, by finding rows that *individually* look like two columns.
///
/// These four are what "individually looks like two columns" is built from.

/// A gutter inside a row must be at least this wide.
private let pdfMinRowGutter: Float = 8

/// An image's extent on the page, as the reference's `(x0, y0, x1, y1)`.
struct PdfImageRegion: Equatable {
    var x0: Float
    var y0: Float
    var x1: Float
    var y1: Float
}

/// Runs sharing a baseline, in a form the row splitter can work on.
struct PdfRow {
    /// The mean baseline of the runs on it — which moves as runs join.
    var y: Float
    var items: [PdfLayoutItem]
}

/// The horizontal extent of everything on the page, text and images alike.
///
/// Returns nothing when there is nothing to measure, or when the extent is
/// degenerate — an empty page folds to infinities, which the finite check
/// then rejects rather than propagating.
func pdfPageXBounds(
    _ items: [PdfLayoutItem], _ images: [PdfImageRegion]
) -> (xMin: Float, xMax: Float)? {
    var xMin = Float.infinity
    var xMax = -Float.infinity
    for item in items {
        xMin = min(xMin, item.x)
        xMax = max(xMax, item.x + pdfEffectiveItemWidth(item))
    }
    // An image's corners are not ordered, so both are consulted for each end.
    for image in images {
        xMin = min(xMin, min(image.x0, image.x1))
        xMax = max(xMax, max(image.x0, image.x1))
    }
    guard xMin.isFinite, xMax.isFinite, xMax > xMin else { return nil }
    return (xMin, xMax)
}

/// Group runs into rows by baseline.
///
/// Unlike the line grouper of wave 66, a row's baseline is the **running
/// mean** of the runs on it, recomputed each time one joins. So the tolerance
/// is measured against a point that moves — a row of gently rising text can
/// therefore chain further than three points in total, which the fixed
/// baseline elsewhere would not allow.
func pdfGroupRows(_ items: [PdfLayoutItem]) -> [PdfRow] {
    let yTolerance: Float = 3
    // Descending baseline, stably, as the reference's sort is.
    let sorted = items.enumerated().sorted { left, right in
        if left.element.y != right.element.y { return left.element.y > right.element.y }
        return left.offset < right.offset
    }.map(\.element)

    var rows: [PdfRow] = []
    for item in sorted {
        if var last = rows.last, abs(last.y - item.y) <= yTolerance {
            last.items.append(item)
            last.y = last.items.reduce(0) { $0 + $1.y } / Float(last.items.count)
            rows[rows.count - 1] = last
        } else {
            rows.append(PdfRow(y: item.y, items: [item]))
        }
    }

    for index in rows.indices {
        rows[index].items = rows[index].items.enumerated().sorted { left, right in
            if left.element.x != right.element.x { return left.element.x < right.element.x }
            return left.offset < right.offset
        }.map(\.element)
    }
    return rows
}

/// Whether one side of a proposed row split reads like prose.
///
/// Three words or ten CJK characters, and ten letters either way. The CJK
/// alternative exists because Japanese and Chinese are set without spaces, so
/// a whole sentence counts as one word.
func pdfSideIsProse(_ items: [PdfLayoutItem]) -> Bool {
    let text = items.map { $0.text.rustTrim() }.joined(separator: " ")
    var alphabetic = 0
    var cjk = 0
    for scalar in text.unicodeScalars {
        if scalar.properties.isAlphabetic { alphabetic += 1 }
        if pdfIsCjkScalarValue(scalar) { cjk += 1 }
    }
    return (text.rustSplitWhitespace().count >= 3 || cjk >= 10) && alphabetic >= 10
}

/// Where a single row divides into two columns, if it does.
///
/// Every adjacent pair is a candidate; the gap must be wide enough, the
/// split must fall in the middle half of the page, and both sides must read
/// as prose. Of the candidates that survive, the one with the **widest gap**
/// wins.
///
/// Note the sides are recomputed from the whole row against the candidate
/// split rather than taken as the pair's neighbours, so a row of four runs
/// splitting two-and-two is judged on all four.
func pdfAlignedRowSplit(_ row: PdfRow, xMin: Float, xMax: Float) -> Float? {
    if row.items.count < 2 { return nil }
    let pageWidth = xMax - xMin
    let centreLow = xMin + pageWidth * 0.25
    let centreHigh = xMin + pageWidth * 0.75

    var best: (splitX: Float, gap: Float)?
    for index in 0..<(row.items.count - 1) {
        let left = row.items[index]
        let leftEnd = left.x + pdfEffectiveItemWidth(left)
        let rightStart = row.items[index + 1].x
        let gap = rightStart - leftEnd
        let splitX = (leftEnd + rightStart) / 2
        if gap < pdfMinRowGutter || splitX < centreLow || splitX > centreHigh { continue }

        let leftSide = row.items.filter { $0.x + pdfEffectiveItemWidth($0) / 2 < splitX }
        let rightSide = row.items.filter { $0.x + pdfEffectiveItemWidth($0) / 2 >= splitX }
        guard pdfSideIsProse(leftSide), pdfSideIsProse(rightSide) else { continue }

        // Rust's `max_by` keeps the **last** maximum, so a later candidate
        // with an equal gap replaces an earlier one. `>=` rather than `>`.
        if best == nil || gap >= (best?.gap ?? 0) { best = (splitX, gap) }
    }
    return best?.splitX
}
