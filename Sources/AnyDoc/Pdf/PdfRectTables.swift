/// The cluster loop of `detect_tables_from_rects`, ported from
/// pdf-inspector's `tables/detect_rects.rs`.
///
/// This is the orchestrator every rectangle strategy has been waiting for. It
/// takes a page's rectangles, groups them into clusters, and tries the
/// strategies against each in decreasing order of geometric evidence — with
/// three whole-page fallbacks behind them for the shapes clustering cannot
/// see. The ordering is not arbitrary: each fallback exists because the
/// stage above it produces nothing on a real document shape, and each is
/// gated tightly enough that it cannot fire on the shapes the earlier stages
/// already handle.

/// A competing table hypothesis rescued from a chart-like cluster must have
/// this many rows. Small chart panels form plausible grids from their axis
/// labels; sustained row evidence is what separates them from a real table.
private let pdfCompetingTableMinimumRows = 8

/// Tables found among a page's rectangles.
///
/// `rects` are the page's raw rectangles; they are normalised and filtered
/// here. `items` is the page's full text.
func pdfDetectTablesFromRects(
    items: [PdfLayoutItem],
    rects: [(x: Float, y: Float, width: Float, height: Float)]
) -> [PdfTable] {
    let pageRects = pdfPreparePageRects(rects)

    // Grid detection needs six rectangles before it will guess at anything.
    guard pageRects.count >= 6 else { return [] }

    var tables: [PdfTable] = []
    var failedClusters: [[(x: Float, y: Float, width: Float, height: Float)]] = []

    // A page-background fill anchored at the origin bridges separate table
    // regions into one cluster. Keep those out of the adjacency graph — but
    // *not* out of the clusters themselves, since grid detection still wants
    // their edges.
    let heights = pageRects.map(\.height).sorted()
    let heightThreshold = heights[heights.count / 2] * 20
    let isPageBackground = pageRects.map { $0.x < 5 && $0.y < 5 && $0.height > heightThreshold }

    let nonBackgroundIndices = (0..<pageRects.count).filter { !isPageBackground[$0] }
    let nonBackgroundRects = nonBackgroundIndices.map { pageRects[$0] }
    let clusters = pdfClusterRects(nonBackgroundRects, tolerance: 3, minimumSize: 6)
        .map { $0.map { nonBackgroundIndices[$0] } }

    // Chart clusters, and clusters whose table was found only after
    // normalisation, are barred from the merged fallback below.
    var mergeExcludedClusters = Set<Int>()

    for (clusterID, clusterIndices) in clusters.enumerated() {
        let groupRects = clusterIndices.map { pageRects[$0] }

        // Chart bars are neither table cells nor a hint region — gridding a
        // chart's axis labels scrambles the page — so a chart cluster is
        // dropped before it can reach any detector or fallback.
        if pdfIsChartBarCluster(items: items, groupRects: groupRects) {
            // Except that repeated page fills can dominate the geometry and
            // make a real shaded-cell table look like a chart. Strip those
            // fills, re-cluster, and let a table hypothesis compete with the
            // chart verdict before it wins.
            let normalised = pdfWithoutDominantPageBackgrounds(groupRects)
            var best: PdfTable?
            if normalised.count < groupRects.count {
                for indices in pdfClusterRects(normalised, tolerance: 3, minimumSize: 6) {
                    let candidate = indices.map { normalised[$0] }
                    if pdfIsChartBarCluster(items: items, groupRects: candidate) { continue }
                    let found =
                        pdfDetectTableFromRectGroup(items: items, groupRects: candidate)
                        ?? pdfDetectRowStripeTableFromCellRects(
                            items: items, groupRects: candidate)
                    guard let table = found, table.rows.count >= pdfCompetingTableMinimumRows
                    else { continue }
                    // `max_by_key` keeps the last of equal maxima.
                    if best == nil
                        || table.rows.count * table.columns.count
                            >= best!.rows.count * best!.columns.count
                    {
                        best = table
                    }
                }
            }
            mergeExcludedClusters.insert(clusterID)
            if let table = best { tables.append(table) }
            continue
        }

        if let table = pdfDetectDirectRectTable(items: items, rects: groupRects) {
            tables.append(table)
        } else if let halves = pdfSplitWideCluster(groupRects, minimumGap: 15, minimumGroupSize: 6) {
            // Too wide to be one table: two column groups with a gutter
            // between them. Retry each half on its own.
            var splitFound = false
            for half in [halves.left, halves.right] {
                if let table = pdfDetectTableFromRectGroup(items: items, groupRects: half) {
                    tables.append(table)
                    splitFound = true
                } else if let table = pdfDetectRowStripeTable(items: items, groupRects: half) {
                    tables.append(table)
                    splitFound = true
                }
            }
            if !splitFound { failedClusters.append(groupRects) }
        } else {
            failedClusters.append(groupRects)
        }
    }

    // Merged-cluster fallback, for clip-path PDFs where every column forms its
    // own cluster: nothing overlaps, so per-cluster detection sees columns
    // rather than a table. It also replaces tables that *were* found but are
    // suspiciously narrow, which is the same failure seen from the other side.
    let onlyNarrow = !tables.isEmpty && tables.allSatisfy { $0.columns.count <= 3 }
    if tables.isEmpty || onlyNarrow {
        let tableClusters = clusters.enumerated()
            .filter { !mergeExcludedClusters.contains($0.offset) }
            .map(\.element)
        let totalClustered = tableClusters.reduce(0) { $0 + $1.count }
        // Three clusters and fifty rectangles: enough that "every column is
        // its own cluster" is a better explanation than "there is no table".
        if tableClusters.count >= 3 && totalClustered >= 50 {
            let allClusterRects = tableClusters.flatMap { $0.map { pageRects[$0] } }
            if let table = pdfDetectMergedClusterTable(items: items, allRects: allClusterRects) {
                if onlyNarrow { tables.removeAll() }
                tables.append(table)
            }
        }
    }

    // Cell-rect fallback, for tables drawn as cell backgrounds rather than
    // borders: variable column widths and decoration fills leave no clean
    // grid, so rows come from the rectangles and columns from the text.
    if tables.isEmpty {
        for cluster in failedClusters where cluster.count >= 6 {
            if let table = pdfDetectRowStripeTableFromCellRects(items: items, groupRects: cluster) {
                tables.append(table)
            }
        }
    }

    // Row-stripe fallback, for banded tables: the stripes do not overlap, so
    // clustering yields nothing at all and the whole page has to be tried as
    // one table. Fifteen rectangles and ten resulting rows keep decorative
    // fills out.
    if tables.isEmpty && clusters.isEmpty && pageRects.count >= 15 {
        if let table = pdfDetectRowStripeTable(items: items, groupRects: pageRects),
            table.rows.count >= 10
        {
            tables.append(table)
        }
    }

    // Note what is deliberately *not* here: a stack of three to five boxes
    // never reaches `pdfDetectStackedBoxTable`, because both the page and the
    // cluster must hold six rectangles to get this far. Routing smaller
    // clusters through it was tried upstream and regressed four documents
    // while improving none — with so few boxes the anti-prose guards have too
    // little signal to discriminate.
    return tables
}
