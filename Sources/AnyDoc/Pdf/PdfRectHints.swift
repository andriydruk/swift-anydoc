/// Hint regions and chart regions, ported from the remainder of
/// `detect_tables_from_rects`, `merge_overlapping_hints`,
/// `extract_hint_region` and `detect_chart_regions` in pdf-inspector's
/// `tables/detect_rects.rs`.
///
/// When the rectangles on a page do not describe a table well enough to build
/// one, they can still say *where* a table is. A form drawn with only an outer
/// border and a header divider has no column structure at all, but its
/// bounding box keeps the heuristic detector from sweeping a graph legend into
/// the table beside it. That is what a hint region is for — not a table, but a
/// boundary.
///
/// Chart regions are the mirror image: a bounding box around text that must
/// *never* be gridded, whatever strategy is looking at it.

/// Where a table probably is, though its rectangles could not build one.
struct PdfRectHintRegion: Equatable {
    /// The top edge — the *highest* y, since PDF space grows upwards.
    var yTop: Float
    var yBottom: Float
    var xLeft: Float
    var xRight: Float
    /// The cluster's own rectangles, kept for rect-guided table building.
    var clusterRects: [(x: Float, y: Float, width: Float, height: Float)] = []

    static func == (a: PdfRectHintRegion, b: PdfRectHintRegion) -> Bool {
        a.yTop == b.yTop && a.yBottom == b.yBottom && a.xLeft == b.xLeft && a.xRight == b.xRight
            && a.clusterRects.count == b.clusterRects.count
            && zip(a.clusterRects, b.clusterRects).allSatisfy { $0 == $1 }
    }
}

/// Fold overlapping hints together until nothing more will merge.
///
/// Two hints join when they share more than half the shorter one's height and
/// sit within 50pt horizontally — a table split into column groups. The merged
/// result is capped at 400pt wide, which stops a chain of adjacent hints from
/// growing across the page one merge at a time.
func pdfMergeOverlappingHints(_ hints: [PdfRectHintRegion]) -> [PdfRectHintRegion] {
    guard hints.count > 1 else { return hints }
    var hints = hints
    while true {
        hints.sort { $0.xLeft < $1.xLeft }
        var merged: [PdfRectHintRegion] = []
        var anyMerged = false
        for hint in hints {
            var didMerge = false
            for index in merged.indices {
                let existing = merged[index]
                let yOverlap = min(existing.yTop, hint.yTop) - max(existing.yBottom, hint.yBottom)
                let yMinimumSpan = min(
                    existing.yTop - existing.yBottom, hint.yTop - hint.yBottom)
                if yOverlap <= yMinimumSpan * 0.5 { continue }

                let xGap = max(existing.xLeft, hint.xLeft) - min(existing.xRight, hint.xRight)
                if xGap < 50 {
                    let mergedLeft = min(existing.xLeft, hint.xLeft)
                    let mergedRight = max(existing.xRight, hint.xRight)
                    if mergedRight - mergedLeft > 400 { continue }
                    merged[index].xLeft = mergedLeft
                    merged[index].xRight = mergedRight
                    merged[index].yBottom = min(existing.yBottom, hint.yBottom)
                    merged[index].yTop = max(existing.yTop, hint.yTop)
                    merged[index].clusterRects.append(contentsOf: hint.clusterRects)
                    didMerge = true
                    anyMerged = true
                    break
                }
            }
            if !didMerge { merged.append(hint) }
        }
        hints = merged
        if !anyMerged { break }
    }
    return hints
}

/// A hint from a small cluster of cell borders, or `nil`.
///
/// Only small clusters qualify. A large cluster that failed grid validation is
/// usually form decoration spanning the whole page, and a hint that wide would
/// scope nothing. Rectangles over four times the median height are dropped
/// first: they are the enclosing box, not a row border.
///
/// Note the returned region carries *no* cluster rectangles, unlike the hints
/// the main loop produces — reproduced as written.
func pdfExtractHintRegion(
    _ groupRects: [(x: Float, y: Float, width: Float, height: Float)]
) -> PdfRectHintRegion? {
    guard groupRects.count >= 2, groupRects.count <= 8 else { return nil }

    let heights = groupRects.map(\.height).sorted()
    let medianHeight = heights[heights.count / 2]
    let cellRects = groupRects.filter { $0.height <= medianHeight * 4 }
    guard cellRects.count >= 2 else { return nil }

    guard let yBottom = cellRects.map(\.y).min(),
        let yTop = cellRects.map({ $0.y + $0.height }).max(),
        let xLeft = cellRects.map(\.x).min(),
        let xRight = cellRects.map({ $0.x + $0.width }).max()
    else { return nil }

    let height = yTop - yBottom
    guard height >= 10, height <= 300 else { return nil }
    return PdfRectHintRegion(yTop: yTop, yBottom: yBottom, xLeft: xLeft, xRight: xRight)
}

/// Bounding boxes of the page's chart-bar clusters.
///
/// Text inside one of these belongs to a figure — axis labels, data values,
/// legends — and no strategy may grid it.
///
/// The rectangle filtering here is deliberately *not* `pdfPreparePageRects`:
/// only the negative-extent normalisation and the 5pt minimum are shared. An
/// origin-anchored page background is dropped outright rather than merely kept
/// out of clustering, because letting one bridge into a bar cluster would
/// inflate the region to the whole page.
///
/// The regions are **corners**, not extents: the reference folds each cluster
/// into `(min x, min y, max x, max y)`, so the last two fields are the right
/// and top edges. Named accordingly here rather than reusing the rectangle
/// tuple, whose `width`/`height` labels would quietly mean something else.
func pdfDetectChartRegions(
    items: [PdfLayoutItem],
    rects: [(x: Float, y: Float, width: Float, height: Float)]
) -> [(left: Float, bottom: Float, right: Float, top: Float)] {
    var pageRects: [(x: Float, y: Float, width: Float, height: Float)] = []
    for rect in rects {
        var (x, y, width, height) = rect
        if width < 0 {
            x += width
            width = -width
        }
        if height < 0 {
            y += height
            height = -height
        }
        guard width >= 5, height >= 5, !(x < 5 && y < 5) else { continue }
        pageRects.append((x, y, width, height))
    }
    guard pageRects.count >= 6 else { return [] }

    var regions: [(left: Float, bottom: Float, right: Float, top: Float)] = []
    for cluster in pdfClusterRects(pageRects, tolerance: 3, minimumSize: 6) {
        let group = cluster.map { pageRects[$0] }
        guard pdfIsChartBarCluster(items: items, groupRects: group) else { continue }
        var x0 = Float.infinity
        var y0 = Float.infinity
        var x1 = -Float.infinity
        var y1 = -Float.infinity
        for rect in group {
            x0 = min(x0, rect.x)
            y0 = min(y0, rect.y)
            x1 = max(x1, rect.x + rect.width)
            y1 = max(y1, rect.y + rect.height)
        }
        regions.append((left: x0, bottom: y0, right: x1, top: y1))
    }
    return regions
}
