/// Which text belongs to a chart, ported from `markdown/mod.rs`:
/// `is_chart_adjacent_label`, `item_is_in_chart_region` and
/// `items_outside_chart_regions`.
///
/// A chart's axis labels, category names and caption are text like any
/// other, and left in the flow they read as fragments scattered through the
/// prose. Removing them means deciding which runs *near* a chart belong to
/// it — a question of geometry, since nothing in the PDF says so.
///
/// The band around a chart is generous vertically and the tests inside it
/// are correspondingly strict: being close is not enough, the run must also
/// look like a label rather than a paragraph that happens to sit nearby.

/// How far outside a chart's box its labels may still sit.
private let pdfChartRegionPad: Float = 20

/// Whether a run beside a chart is one of its labels.
///
/// Three ways to qualify, any one of which suffices: the run is **compact**
/// in its own right, it is a **caption**, or it sits mostly within the
/// chart's width, close to its edge, and is narrow relative to the chart.
///
/// A bare bullet or a list item never qualifies — those belong to the prose
/// however close they fall.
func pdfIsChartAdjacentLabel(_ item: PdfLayoutItem, _ region: PdfImageRegion) -> Bool {
    let text = item.text.rustTrim()
    let bareBullets: Set<String> = ["•", "●", "○", "◦", "-", "*"]
    if text.isEmpty || pdfIsListItem(text) || bareBullets.contains(text) { return false }

    // Neither the region's corners nor the run's width are ordered.
    let left = min(region.x0, region.x1)
    let right = max(region.x0, region.x1)
    let bottom = min(region.y0, region.y1)
    let top = max(region.y0, region.y1)
    let itemLeft = min(item.x, item.x + item.width)
    let itemRight = max(item.x, item.x + item.width)
    let itemWidth = max(itemRight - itemLeft, 1)
    let chartWidth = max(right - left, 1)

    let horizontalOverlap = max(min(itemRight, right) - max(itemLeft, left), 0)
    let mostlyInsideChartWidth = horizontalOverlap >= itemWidth * 0.8

    let verticalGap: Float
    if item.y < bottom {
        verticalGap = bottom - item.y
    } else if item.y > top {
        verticalGap = item.y - top
    } else {
        verticalGap = 0
    }

    let isCaption = pdfIsCaptionLine(text)
    // The run's own type size, since the extractor may not have recorded a
    // height.
    let em = max(max(item.height, item.fontSize), 1)
    let compactLabel = itemWidth <= em * 18.5
    // A category name sits within about two lines of the axis; the clamp
    // keeps that sane for very small and very large type.
    let categoryBand = min(max(em * 1.85, 6), pdfChartRegionPad)
    let closeToChartEdge = isCaption ? verticalGap <= pdfChartRegionPad
        : verticalGap <= categoryBand
    let categorySized = itemWidth <= chartWidth * 0.75

    return verticalGap <= pdfChartRegionPad
        && (compactLabel || isCaption
            || (mostlyInsideChartWidth && closeToChartEdge && categorySized))
}

/// Whether a run belongs to any of the page's charts.
///
/// Horizontally the run's **centre** must fall within the padded box.
/// Vertically there are two ways in: inside the box outright, which needs no
/// further argument, or within the padding *and* looking like a label.
func pdfItemIsInChartRegion(_ item: PdfLayoutItem, _ regions: [PdfImageRegion]) -> Bool {
    let centre = item.x + item.width / 2
    for region in regions {
        // Note the unpadded corners are used as given here, unlike in the
        // label test — a region written backwards will not match.
        let withinPaddedX =
            centre >= region.x0 - pdfChartRegionPad && centre <= region.x1 + pdfChartRegionPad
        guard withinPaddedX else { continue }
        let withinCoreY = item.y >= region.y0 && item.y <= region.y1
        let withinPaddedY =
            item.y >= region.y0 - pdfChartRegionPad && item.y <= region.y1 + pdfChartRegionPad
            && pdfIsChartAdjacentLabel(item, region)
        if withinCoreY || withinPaddedY { return true }
    }
    return false
}

/// The page's runs with every chart's own text removed.
func pdfItemsOutsideChartRegions(
    _ items: [PdfLayoutItem], _ regions: [PdfImageRegion]
) -> [PdfLayoutItem] {
    items.filter { !pdfItemIsInChartRegion($0, regions) }
}
