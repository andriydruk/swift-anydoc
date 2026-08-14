/// A page's items into lines of reading order, ported from
/// `group_into_lines_with_thresholds_and_regions_impl` in
/// `extractor/layout.rs`.
///
/// This is the layout half's assembly: everything waves 61–70 built is
/// wired together here. Given one page's items it decides the columns,
/// checks whether the page's images imply a local flow, files each item into
/// a column, groups each column into lines, and then emits them in reading
/// order — which differs completely depending on whether the columns are
/// independent flows or the rows of a table.
///
/// The reference loops over pages and looks its per-page parameters up in
/// maps; this port takes one page's items and those parameters directly,
/// which is the same thing with the loop lifted out.

/// Group a page's items into lines.
///
/// - `filterPageNumbers`: Markdown output drops standalone numeric headers
///   and footers. Plain-text callers opt out, because dropping extracted
///   text would violate that API.
/// - `chartRegions`: chart text scattered across the page fills the gutter in
///   the projection histogram, so the columns are detected blind to it. A
///   page with charts also skips the image-anchored path entirely, since
///   charts have their own positioned-region ordering.
func pdfGroupPageIntoLines(
    _ items: [PdfLayoutItem],
    page: Int = 1,
    adaptiveThreshold: Float = 0.10,
    hasTable: Bool = false,
    chartRegions: [PdfImageRegion] = [],
    imageRegions: [PdfImageRegion] = [],
    filterPageNumbers: Bool = true
) -> [PdfTextLine] {
    if items.isEmpty { return [] }
    let pageItems = filterPageNumbers ? items.filter { !pdfIsPageNumber($0) } : items
    if pageItems.isEmpty { return [] }

    func grouped(_ items: [PdfLayoutItem]) -> [PdfTextLine] {
        var lines = pdfGroupSingleColumn(items)
        for index in lines.indices {
            lines[index].adaptiveThreshold = adaptiveThreshold
            lines[index].page = page
        }
        return lines
    }

    // An image-backed region graph recovers local and asymmetric flows a
    // whole-page projection cannot represent. Charts already have their own
    // ordering and so stay off this path.
    if chartRegions.isEmpty && !imageRegions.isEmpty {
        let preliminary = pdfDetectColumns(pageItems, pageHasTable: hasTable)
        let detectedSplit = preliminary.count == 2 ? preliminary[0].xMax : nil
        if let band = pdfInferImageAnchoredFlow(
            pageItems, imageRegions, detectedSplit: detectedSplit)
        {
            var lines: [PdfTextLine] = []
            for node in pdfBuildRegionGraph(pageItems, band: band) {
                lines.append(contentsOf: grouped(node.items))
            }
            return lines
        }
    }

    let columns: [PdfColumnRegion]
    if chartRegions.isEmpty {
        columns = pdfDetectColumns(pageItems, pageHasTable: hasTable)
    } else {
        // Tight bounds — two points of slack — so this blinds the histogram
        // only to chart-internal text. Rows *adjacent* to a chart belong to
        // the column layout. Note the raw width here, not the estimate.
        let visible = pageItems.filter { item in
            let centre = item.x + item.width / 2
            return !chartRegions.contains { region in
                centre >= region.x0 - 2 && centre <= region.x1 + 2 && item.y >= region.y0 - 2
                    && item.y <= region.y1 + 2
            }
        }
        columns = pdfDetectColumns(visible, pageHasTable: hasTable)
    }

    if columns.count <= 1 { return grouped(pageItems) }

    // Multi-column. Lines running the full width — titles, section headers,
    // footers — are lifted out first: split across column buckets they would
    // corrupt both newspaper detection and reading order.
    let spanningMask = pdfIdentifySpanningLines(pageItems, columns)
    var spanningItems: [PdfLayoutItem] = []
    var columnItems: [PdfLayoutItem] = []
    for (index, item) in pageItems.enumerated() {
        if spanningMask[index] || pdfSpansMultipleColumns(item, columns) {
            spanningItems.append(item)
        } else {
            columnItems.append(item)
        }
    }

    // Filed by greatest horizontal *overlap* rather than by centre point,
    // which is what stops an item leaning into the gutter being misfiled.
    // Ties keep the earlier column, since the comparison is strict.
    var buckets = [[PdfLayoutItem]](repeating: [], count: columns.count)
    for item in columnItems {
        let left = item.x
        let right = item.x + pdfEffectiveItemWidth(item)
        var bestColumn = 0
        var bestOverlap = -Float.infinity
        for (index, column) in columns.enumerated() {
            let overlap = max(min(right, column.xMax) - max(left, column.xMin), 0)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestColumn = index
            }
        }
        buckets[bestColumn].append(item)
    }

    let perColumnLines = buckets.map(grouped)
    let spanningLines = grouped(spanningItems)

    if pdfIsNewspaperLayout(perColumnLines, columns) {
        return pdfNewspaperOrder(perColumnLines, spanningLines)
    }
    return pdfTabularOrder(perColumnLines, spanningLines)
}

/// Independent flows: all of column one, then all of column two.
///
/// Each column is first split into its densest cluster and its stragglers,
/// and the *cores* then decide where the page's shared material begins —
/// anything above that goes out first, whatever column it came from.
private func pdfNewspaperOrder(
    _ perColumnLines: [[PdfTextLine]], _ spanningLines: [PdfTextLine]
) -> [PdfTextLine] {
    var cores: [[PdfTextLine]] = []
    var stragglers: [[PdfTextLine]] = []
    for column in perColumnLines {
        let split = pdfSplitColumnStragglers(column)
        cores.append(split.core)
        stragglers.append(split.stragglers)
    }

    // The lowest of the columns' tops: material above *every* column's start
    // is shared. All cores empty leaves this infinite, so nothing is above.
    var columnTop = Float.infinity
    for core in cores where !core.isEmpty {
        var highest = -Float.infinity
        for line in core { highest = max(highest, line.y) }
        columnTop = min(columnTop, highest)
    }
    let margin: Float = 5

    var above: [PdfTextLine] = []
    var belowSpanning: [PdfTextLine] = []
    for line in spanningLines {
        if line.y > columnTop + margin { above.append(line) } else { belowSpanning.append(line) }
    }

    // A straggler above the columns joins the shared material; one below
    // **stays with its column**, since sorting it back by y would re-
    // interleave the flows this ordering exists to separate.
    var columnBelow = [[PdfTextLine]](repeating: [], count: cores.count)
    for (index, columnStragglers) in stragglers.enumerated() {
        for line in columnStragglers {
            if line.y > columnTop + margin {
                above.append(line)
            } else {
                columnBelow[index].append(line)
            }
        }
    }

    above = pdfSortLinesByBaseline(above)
    belowSpanning = pdfSortLinesByBaseline(belowSpanning)

    var result = above
    for core in cores { result.append(contentsOf: core) }
    for below in columnBelow { result.append(contentsOf: below) }
    result.append(contentsOf: belowSpanning)
    return result
}

/// Rows of a table: lines at the same baseline in different columns are one
/// logical line, so the page is interleaved by y and then merged.
private func pdfTabularOrder(
    _ perColumnLines: [[PdfTextLine]], _ spanningLines: [PdfTextLine]
) -> [PdfTextLine] {
    var all = spanningLines
    for column in perColumnLines { all.append(contentsOf: column) }

    // Descending baseline, then by the line's leftmost item. Stable, as the
    // reference's sort is.
    let sorted = all.enumerated().sorted { left, right in
        if left.element.y != right.element.y { return left.element.y > right.element.y }
        let leftX = left.element.items.first?.x ?? 0
        let rightX = right.element.items.first?.x ?? 0
        if leftX != rightX { return leftX < rightX }
        return left.offset < right.offset
    }.map(\.element)

    let yTolerance: Float = 3
    var merged: [PdfTextLine] = []
    for line in sorted {
        if let last = merged.last, abs(last.y - line.y) < yTolerance {
            merged[merged.count - 1].items.append(contentsOf: line.items)
            pdfSortLineItems(&merged[merged.count - 1].items)
            continue
        }
        merged.append(line)
    }
    return merged
}

/// Descending baseline, stably.
private func pdfSortLinesByBaseline(_ lines: [PdfTextLine]) -> [PdfTextLine] {
    lines.enumerated().sorted { left, right in
        if left.element.y != right.element.y { return left.element.y > right.element.y }
        return left.offset < right.offset
    }.map(\.element)
}
