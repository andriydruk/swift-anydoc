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

/// Rows must agree on a split before it is believed.
private let pdfMinAlignedRows = 4
/// Two rows' splits within this are the same split.
private let pdfSplitClusterTolerance: Float = 20

/// A band of two-column flow, found beneath a full-width figure.
struct PdfColumnFlowBand: Equatable {
    var splitX: Float
    var yBottom: Float
    var yTop: Float
}

/// Two columns running beneath a single square hero image.
///
/// The shape this recognises is narrow on purpose. A local column flow below
/// an image is only unambiguous for **one** nearly square figure: a wide
/// report banner or full-page artwork frequently sits above unrelated page
/// furniture whose aligned labels mimic prose columns perfectly well. So the
/// anchor has to be near-square and near-full-width, and there has to be
/// exactly one of it.
///
/// Everything after that is corroboration — four rows agreeing on where the
/// split falls, the band sitting a plausible distance below the image, and
/// the band being short enough to be a caption block rather than a page.
func pdfLocalFlowBelowFullWidthImage(
    _ items: [PdfLayoutItem], _ images: [PdfImageRegion], xMin: Float, xMax: Float
) -> PdfColumnFlowBand? {
    let pageWidth = xMax - xMin
    let fullWidth = images.filter { image in
        let width = abs(image.x1 - image.x0)
        let height = abs(image.y1 - image.y0)
        return width >= pageWidth * 0.65 && height >= 60
    }
    guard fullWidth.count == 1, let anchor = fullWidth.first else { return nil }

    let anchorWidth = abs(anchor.x1 - anchor.x0)
    let anchorHeight = abs(anchor.y1 - anchor.y0)
    guard anchorWidth >= pageWidth * 0.85,
        anchorHeight >= anchorWidth * 0.85,
        anchorHeight <= anchorWidth * 1.2
    else { return nil }

    let imageBottom = min(anchor.y0, anchor.y1)
    if !imageBottom.isFinite { return nil }

    // Only the 220 points immediately below the image are considered; text
    // further down belongs to the page's own flow.
    let below = items.filter { $0.y < imageBottom && $0.y >= imageBottom - 220 }
    var candidates: [(splitX: Float, y: Float)] = []
    for row in pdfGroupRows(below) {
        if let split = pdfAlignedRowSplit(row, xMin: xMin, xMax: xMax) {
            candidates.append((split, row.y))
        }
    }
    if candidates.count < pdfMinAlignedRows { return nil }

    // Cluster by split position. The first cluster whose *running mean* is
    // close enough takes the candidate, and that mean then moves — so the
    // clustering depends on the order the rows were found in.
    var clusters: [[(splitX: Float, y: Float)]] = []
    for candidate in candidates {
        var placed = false
        for index in clusters.indices {
            let mean = clusters[index].reduce(0) { $0 + $1.splitX } / Float(clusters[index].count)
            if abs(mean - candidate.splitX) <= pdfSplitClusterTolerance {
                clusters[index].append(candidate)
                placed = true
                break
            }
        }
        if !placed { clusters.append([candidate]) }
    }

    // Rust's `max_by_key` keeps the **last** maximum, so `>=` here.
    var dominant: [(splitX: Float, y: Float)] = []
    for cluster in clusters where cluster.count >= dominant.count { dominant = cluster }
    if dominant.isEmpty || dominant.count < pdfMinAlignedRows { return nil }

    let splitX = dominant.reduce(0) { $0 + $1.splitX } / Float(dominant.count)
    var yTop = -Float.infinity
    var yBottom = Float.infinity
    for entry in dominant {
        yTop = max(yTop, entry.y)
        yBottom = min(yBottom, entry.y)
    }
    yTop += 3
    yBottom -= 3

    // The band must sit a caption's distance below the image — closer and
    // it is part of the figure, further and it is unrelated text.
    let imageGap = imageBottom - yTop
    guard imageGap >= 60, imageGap <= 120 else { return nil }
    // And be short enough to be a block rather than a page of its own.
    if yTop - yBottom > 130 { return nil }

    return PdfColumnFlowBand(splitX: splitX, yBottom: yBottom, yTop: yTop)
}

/// An image narrower than this is a bullet or a rule, not a panel.
private let pdfMinImageWidth: Float = 60
/// And one shorter than this is a divider.
private let pdfMinImageHeight: Float = 40

/// Two columns of stacked figures either side of a known split.
///
/// The other half of image-anchored flow. Where
/// `pdfLocalFlowBelowFullWidthImage` reads a caption beneath one hero image,
/// this recognises a page *built* from paired panels — a catalogue or a
/// photo essay — where the images themselves mark the columns and the text
/// merely fills around them.
///
/// The demanding test is the vertical stack. Three logos in a row across a
/// page header would otherwise satisfy the image count and send an ordinary
/// asymmetric page through sequential column order, so at least one pair on
/// the *same side* must sit one above the other: centres far enough apart to
/// be separate panels, and close enough not to be unrelated.
func pdfPairedColumnImages(
    _ items: [PdfLayoutItem], _ images: [PdfImageRegion], splitX: Float, xMin: Float,
    xMax: Float
) -> PdfColumnFlowBand? {
    let pageWidth = xMax - xMin
    // Only a split near the middle can have paired columns either side.
    if splitX < xMin + pageWidth * 0.4 || splitX > xMin + pageWidth * 0.6 { return nil }

    let qualifying = images.filter { image in
        let left = min(image.x0, image.x1)
        let right = max(image.x0, image.x1)
        // An image straddling the split belongs to neither column.
        let confined = right <= splitX || left >= splitX
        return confined && abs(image.x1 - image.x0) >= pdfMinImageWidth
            && abs(image.y1 - image.y0) >= pdfMinImageHeight
    }
    let wide = qualifying.filter { abs($0.x1 - $0.x0) >= pageWidth * 0.35 }
    if qualifying.count < 3 || wide.count < 3 { return nil }

    let hasLeft = qualifying.contains { ($0.x0 + $0.x1) / 2 < splitX }
    let hasRight = qualifying.contains { ($0.x0 + $0.x1) / 2 >= splitX }
    guard hasLeft, hasRight else { return nil }

    var imageYMin = Float.infinity
    var imageYMax = -Float.infinity
    for image in wide {
        imageYMin = min(imageYMin, min(image.y0, image.y1))
        imageYMax = max(imageYMax, max(image.y0, image.y1))
    }

    var hasVerticalStack = false
    outer: for (index, left) in wide.enumerated() {
        for right in wide.dropFirst(index + 1) {
            let sameSide =
                ((left.x0 + left.x1) / 2 < splitX) == ((right.x0 + right.x1) / 2 < splitX)
            let leftCentre = (left.y0 + left.y1) / 2
            let rightCentre = (right.y0 + right.y1) / 2
            let leftHeight = abs(left.y1 - left.y0)
            let rightHeight = abs(right.y1 - right.y0)
            // Zero when they overlap vertically, which counts as adjacent.
            var verticalGap: Float = 0
            if max(left.y0, left.y1) < min(right.y0, right.y1) {
                verticalGap = min(right.y0, right.y1) - max(left.y0, left.y1)
            } else if max(right.y0, right.y1) < min(left.y0, left.y1) {
                verticalGap = min(left.y0, left.y1) - max(right.y0, right.y1)
            }
            if sameSide
                && abs(leftCentre - rightCentre) >= min(leftHeight, rightHeight) * 0.5
                && verticalGap <= max(leftHeight, rightHeight) * 0.5
            {
                hasVerticalStack = true
                break outer
            }
        }
    }
    if imageYMax - imageYMin < pageWidth * 0.45 || !hasVerticalStack { return nil }

    var yTop = -Float.infinity
    for image in qualifying { yTop = max(yTop, max(image.y0, image.y1)) }
    yTop += 3

    // Only column-confined text proves how far down the flow runs. A spanning
    // heading below the columns has to become the trailing full-width node
    // rather than stretching the band to the page foot.
    var yBottom = Float.infinity
    for item in items {
        let right = item.x + pdfEffectiveItemWidth(item)
        if item.y <= yTop && (right <= splitX || item.x >= splitX) {
            yBottom = min(yBottom, item.y)
        }
    }
    yBottom -= 3
    if !yBottom.isFinite { return nil }

    // Rows per side, counted by *distinct* baselines — runs within three
    // points of the last one kept are the same row.
    func distinctRows(right: Bool) -> Int {
        let ys = items.filter {
            $0.y <= yTop && (($0.x + pdfEffectiveItemWidth($0) / 2 >= splitX) == right)
        }.map(\.y).sorted { $0 < $1 }
        var kept: [Float] = []
        for y in ys {
            if let last = kept.last, abs(y - last) <= 3 { continue }
            kept.append(y)
        }
        return kept.count
    }
    let leftRows = distinctRows(right: false)
    let rightRows = distinctRows(right: true)
    let balance = Float(min(leftRows, rightRows)) / Float(max(max(leftRows, rightRows), 1))

    // Both sides substantial, and *unbalanced* — evenly matched columns are
    // ordinary two-column text, which the histogram already handles.
    guard leftRows >= 5, rightRows >= 5, balance < 0.55 else { return nil }
    return PdfColumnFlowBand(splitX: splitX, yBottom: yBottom, yTop: yTop)
}

/// Whether a region is read across the page or as one column of a pair.
enum PdfRegionKind: Equatable {
    case fullWidth
    case column
}

/// A partition of the page, in reading order.
struct PdfRegionNode {
    var kind: PdfRegionKind
    var items: [PdfLayoutItem]
}

/// The column-flow band a page's images imply, if any.
///
/// Two recognisers, tried in order of how much they are told. A split already
/// found by column detection lets `pdfPairedColumnImages` look for panels
/// either side of it; failing that — or with no split to work from —
/// `pdfLocalFlowBelowFullWidthImage` looks for a hero image to anchor on.
///
/// Note the paired recogniser is *only* reachable when a split was detected,
/// so a page whose columns the histogram could not find is judged solely on
/// its hero image.
func pdfInferImageAnchoredFlow(
    _ items: [PdfLayoutItem], _ images: [PdfImageRegion], detectedSplit: Float?
) -> PdfColumnFlowBand? {
    if items.isEmpty || images.isEmpty { return nil }
    guard let bounds = pdfPageXBounds(items, images) else { return nil }
    if let split = detectedSplit,
        let band = pdfPairedColumnImages(
            items, images, splitX: split, xMin: bounds.xMin, xMax: bounds.xMax)
    {
        return band
    }
    return pdfLocalFlowBelowFullWidthImage(
        items, images, xMin: bounds.xMin, xMax: bounds.xMax)
}

/// Partition a page into `above → left → right → below`.
///
/// These four are the reading-order graph: everything above the band, then
/// its two columns, then everything below. Expressing it as an ordered list
/// rather than a real DAG is enough because the shape is always this one —
/// the band is a horizontal slice, so nothing can be beside the material
/// above or below it.
///
/// Empty regions are dropped, so a page with nothing above its band starts at
/// the left column. Direction is decided from the **columns only**, ignoring
/// the full-width material — a right-to-left page reads its right column
/// first.
func pdfBuildRegionGraph(
    _ items: [PdfLayoutItem], band: PdfColumnFlowBand
) -> [PdfRegionNode] {
    var above: [PdfLayoutItem] = []
    var left: [PdfLayoutItem] = []
    var right: [PdfLayoutItem] = []
    var below: [PdfLayoutItem] = []
    for item in items {
        if item.y > band.yTop {
            above.append(item)
        } else if item.y < band.yBottom {
            below.append(item)
        } else if item.x + pdfEffectiveItemWidth(item) / 2 < band.splitX {
            left.append(item)
        } else {
            right.append(item)
        }
    }

    let rightToLeft = pdfIsRtlText((left + right).map(\.text))
    var ordered: [(PdfRegionKind, [PdfLayoutItem])] = [(.fullWidth, above)]
    if rightToLeft {
        ordered.append((.column, right))
        ordered.append((.column, left))
    } else {
        ordered.append((.column, left))
        ordered.append((.column, right))
    }
    ordered.append((.fullWidth, below))

    return ordered.compactMap { kind, items in
        items.isEmpty ? nil : PdfRegionNode(kind: kind, items: items)
    }
}
