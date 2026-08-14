/// Column detection, ported from `detect_columns` in `extractor/layout.rs`.
///
/// This is the assembly function waves 61–64 were built for. It projects the
/// page's text onto its x axis and looks for the gutter, with three routes to
/// an answer tried in order of how much they assume:
///
///   1. **Absolute valleys** — bins the text genuinely avoids. The common
///      case, and the cheapest to believe.
///   2. **Relative valleys** — a dip between two peaks, for justified text
///      that fills its gutter. Only for dense pages, and only when both sides
///      then read as prose.
///   3. **The XY cut** — one clean vertical gap, which catches the sidebar
///      layouts a histogram dominated by the body column misses.
///
/// Every route can decline, and the page then comes back as one full-width
/// column. Nothing here reports failure.
///
/// The reference filters `items` down to one page and drops image
/// placeholders; this port takes the page's items already selected, because
/// `PdfLayoutItem` carries no page number, and drops images by the flag.

/// Two points per bin — fine enough to resolve an 8pt gutter.
private let pdfColumnBinWidth: Float = 2
/// A gutter narrower than this is letter spacing.
private let pdfColumnMinGutterWidth: Float = 8
/// Both sides of a gutter must share this much of the page's height.
private let pdfColumnMinVerticalSpanRatio: Float = 0.30
/// And the busier side must carry this many items.
private let pdfColumnMinItemsPerColumn = 10
/// A bin at or below this fraction of the busiest is "empty" — a few stray
/// descenders should not fill a gutter.
private let pdfColumnNoiseFraction: Float = 0.15

/// The columns a page is set in, left to right.
///
/// Returns an empty list only for an empty page; otherwise at least one
/// region spanning the text's own extent — which is narrower than the page
/// itself, since the margins hold nothing to measure.
func pdfDetectColumns(_ items: [PdfLayoutItem], pageHasTable: Bool) -> [PdfColumnRegion] {
    // An image's left edge would otherwise count toward the projection.
    let pageItems = items.filter { !$0.isImage }
    if pageItems.isEmpty { return [] }

    var xMin = Float.infinity
    var xMax = -Float.infinity
    for item in pageItems {
        xMin = min(xMin, item.x)
        xMax = max(xMax, item.x + pdfEffectiveItemWidth(item))
    }
    let pageWidth = xMax - xMin

    let single = [PdfColumnRegion(xMin: xMin, xMax: xMax)]
    if pageWidth < 200 { return single }
    // Too little text to project. Note this bound is what makes the empty-list
    // crash in `pdfTryXyCutSplit` unreachable from here.
    if pageItems.count < 20 { return single }

    // Items wider than 60% of the page are titles and full-width paragraphs.
    // They are left out of the histogram because they cross the gutter and
    // would fill it — which is what stops a two-column abstract being found
    // on a page that also carries single-column introduction text.
    let wideThreshold = pageWidth * 0.6
    let binCount = max(Int((pageWidth / pdfColumnBinWidth).rounded(.up)), 1)
    var histogram = [UInt32](repeating: 0, count: binCount)

    for item in pageItems {
        let width = pdfEffectiveItemWidth(item)
        if width > wideThreshold { continue }
        // Rust's float-to-integer casts saturate, so a negative index would
        // become zero rather than wrapping. It cannot arise — `xMin` is the
        // minimum over these same items — but the clamp keeps that true
        // rather than assumed.
        let left = min(max(Int(((item.x - xMin) / pdfColumnBinWidth).rounded(.down)), 0), binCount)
        let right = min(
            max(Int(((item.x + width - xMin) / pdfColumnBinWidth).rounded(.up)), 0), binCount)
        if left < right {
            for bin in left..<right { histogram[bin] &+= 1 }
        }
    }

    let maximumCount = histogram.max() ?? 0
    // Truncated toward zero, so a page whose busiest bin holds six items has
    // a noise threshold of zero and needs a genuinely empty gutter.
    let noiseThreshold = UInt32(Float(maximumCount) * pdfColumnNoiseFraction)

    // Runs of quiet bins.
    var valleys: [(lower: Int, upper: Int)] = []
    var valleyStart: Int?
    for (bin, count) in histogram.enumerated() {
        if count <= noiseThreshold {
            if valleyStart == nil { valleyStart = bin }
        } else if let start = valleyStart {
            valleys.append((start, bin))
            valleyStart = nil
        }
    }
    if let start = valleyStart { valleys.append((start, binCount)) }

    // The page's own left and right margins are quiet too, and are not
    // gutters. A valley is kept when it is wide enough and its centre is
    // clear of both edges.
    let marginThreshold = pageWidth * 0.05
    valleys = valleys.filter { valley in
        let widthPoints = Float(valley.upper - valley.lower) * pdfColumnBinWidth
        if widthPoints < pdfColumnMinGutterWidth { return false }
        let centre = (Float(valley.lower + valley.upper) / 2) * pdfColumnBinWidth
        return centre > marginThreshold && centre < pageWidth - marginThreshold
    }

    if valleys.isEmpty && pageItems.count >= 100 && !pageHasTable {
        // Justified text reaches the gutter's edge on both sides, so the
        // absolute search finds nothing. Only for dense pages — a sparse
        // page's shallow dips are not columns — and never where a table was
        // found, since a table's column gaps look identical and the table
        // pipeline already orders them.
        let relative = pdfFindRelativeValleys(
            histogram: histogram, binCount: binCount, binWidth: pdfColumnBinWidth,
            pageWidth: pageWidth, marginThreshold: marginThreshold)
        if !relative.isEmpty {
            let result = pdfValidateAndBuildColumns(
                valleys: relative, items: pageItems, xMin: xMin, binWidth: pdfColumnBinWidth,
                xMax: xMax, minimumItems: pdfColumnMinItemsPerColumn,
                minimumVerticalSpan: pdfColumnMinVerticalSpanRatio, centreAssign: true)
            // A relative valley is weaker evidence than an absolute one, so
            // it has to be corroborated: both sides must read as prose before
            // the split is committed to.
            if result.count > 1 && pdfColumnsHaveProse(result, pageItems) { return result }
        }
        // **Not reached by the probe, and likely unreachable.** Arriving
        // here means the absolute search found no valley, so no run of empty
        // bins clears the margins — while the XY cut needs a 15pt gap that
        // nothing spans, which would produce exactly such a run. The two
        // conditions can only hold together if the gap's centre lies inside
        // the 5% margin, and the XY cut's own 10% margin test is stricter.
        if let columns = pdfTryXyCutSplit(pageItems, pageXMin: xMin, pageXMax: xMax) {
            return columns
        }
        return single
    }

    // Centre-based assignment first, which handles a sidebar better; edge
    // based only if that produced no split at all.
    let centred = pdfValidateAndBuildColumns(
        valleys: valleys, items: pageItems, xMin: xMin, binWidth: pdfColumnBinWidth, xMax: xMax,
        minimumItems: pdfColumnMinItemsPerColumn,
        minimumVerticalSpan: pdfColumnMinVerticalSpanRatio, centreAssign: true)
    if centred.count > 1 { return centred }

    // **Not reached by the probe.** Edge assignment gives each side a subset
    // of what centre assignment gives, so its counts can only shrink and its
    // vertical extents can only narrow — neither of which can turn a refusal
    // into an acceptance. The one gate that could flip is the list-marker
    // check, and only for marker items wide enough to straddle the gutter,
    // which no real page produces. Left in place because it is the
    // reference's, and recorded here rather than claimed as covered.
    let edged = pdfValidateAndBuildColumns(
        valleys: valleys, items: pageItems, xMin: xMin, binWidth: pdfColumnBinWidth, xMax: xMax,
        minimumItems: pdfColumnMinItemsPerColumn,
        minimumVerticalSpan: pdfColumnMinVerticalSpanRatio, centreAssign: false)
    if edged.count > 1 { return edged }

    // Last resort: the widest single gap. A narrow sidebar has too few items
    // to register in the occupancy profile at all, so the histogram cannot
    // see it however it is thresholded.
    if pageItems.count >= 20 && !pageHasTable {
        if let columns = pdfTryXyCutSplit(pageItems, pageXMin: xMin, pageXMax: xMax) {
            return columns
        }
    }

    return single
}
