/// The two remaining pieces of column detection, ported from
/// `extractor/layout.rs` in pdf-inspector: `try_xy_cut_split` and
/// `is_newspaper_layout`.
///
/// `try_xy_cut_split` is tried *before* the projection histogram. Where the
/// histogram asks "which vertical band does the text avoid", this asks the
/// simpler question "is there one clean vertical cut with everything on
/// either side of it" — which a page with a wide sidebar answers and a
/// histogram, dominated by the body column, often does not.
///
/// `is_newspaper_layout` asks a different question again, and asks it after
/// the columns are known: are these independent text flows to be read one
/// after the other, or a single flow that happens to be set in columns? Get
/// it wrong and a newspaper's second column is interleaved line-by-line into
/// its first.

/// A gap narrower than this is word or paragraph spacing, not a gutter.
private let pdfXyCutMinimumGap: Float = 15
/// The busier side of a cut must carry this many items.
private let pdfXyCutMinimumItemsMajor = 10
/// The quieter side — a sidebar — needs only these.
private let pdfXyCutMinimumItemsMinor = 3

/// Split a page at its single widest vertical gap, if it has a convincing one.
///
/// Returns two regions or nothing at all. The sweep is what makes this
/// different from looking at adjacent items: it tracks the furthest right
/// edge seen *so far*, so an item that reaches across several others cannot
/// leave a false gap behind it.
func pdfTryXyCutSplit(
    _ items: [PdfLayoutItem], pageXMin: Float, pageXMax: Float
) -> [PdfColumnRegion]? {
    let pageWidth = pageXMax - pageXMin
    if pageWidth < 200 { return nil }

    // **A deliberate divergence.** The reference indexes `0..len - 1`, which
    // underflows on an empty list and panics — confirmed by running the
    // reference binary, which dies with "index out of bounds: the len is 0
    // but the index is 0" at `layout.rs:272`. Its own caller returns early
    // for any page under twenty items, so the case is unreachable through
    // the real entry point; this port guards rather than reproducing a trap
    // nobody can observe. A single item needs no guard — the loop simply
    // does not run and the zero gap fails the minimum below.
    if items.count < 2 { return nil }

    // Ascending by left edge, stably — Rust's `sort_by` keeps items sharing an
    // edge in their original order and the sweep below is order-sensitive.
    let sortedByLeft = items.enumerated().sorted { left, right in
        if left.element.x != right.element.x { return left.element.x < right.element.x }
        return left.offset < right.offset
    }.map { (x: $0.element.x, right: $0.element.x + pdfEffectiveItemWidth($0.element)) }

    var bestGap: Float = 0
    var bestSplit: Float = 0
    var maximumRightSoFar = -Float.infinity
    for index in 0..<(sortedByLeft.count - 1) {
        maximumRightSoFar = max(maximumRightSoFar, sortedByLeft[index].right)
        let nextLeft = sortedByLeft[index + 1].x
        let gap = nextLeft - maximumRightSoFar
        // Strictly greater, and the running best starts at zero — so
        // overlapping items, which give a negative gap, never win.
        if gap > bestGap {
            bestGap = gap
            bestSplit = (maximumRightSoFar + nextLeft) / 2
        }
    }

    if bestGap < pdfXyCutMinimumGap { return nil }

    // A cut in the outer tenth of the page is a margin, not a gutter.
    let margin = pageWidth * 0.10
    if bestSplit - pageXMin < margin || pageXMax - bestSplit < margin { return nil }

    // Membership by centre, so an item overhanging the cut counts once.
    let leftItems = items.filter { $0.x + pdfEffectiveItemWidth($0) / 2 <= bestSplit }
    let rightItems = items.filter { $0.x + pdfEffectiveItemWidth($0) / 2 > bestSplit }
    let minor = min(leftItems.count, rightItems.count)
    let major = max(leftItems.count, rightItems.count)
    if major < pdfXyCutMinimumItemsMajor || minor < pdfXyCutMinimumItemsMinor { return nil }

    // Both sides must run alongside each other, as in wave 62 — text above a
    // figure and text beside it are told apart the same way.
    var leftYMin = Float.infinity
    var leftYMax = -Float.infinity
    for item in leftItems {
        leftYMin = min(leftYMin, item.y)
        leftYMax = max(leftYMax, item.y)
    }
    var rightYMin = Float.infinity
    var rightYMax = -Float.infinity
    for item in rightItems {
        rightYMin = min(rightYMin, item.y)
        rightYMax = max(rightYMax, item.y)
    }
    let overlap = max(min(leftYMax, rightYMax) - max(leftYMin, rightYMin), 0)
    // Floored at one, so a page whose text sits on a single baseline divides
    // by one rather than by zero.
    let yRange = max(max(leftYMax, rightYMax) - min(leftYMin, rightYMin), 1)
    if overlap / yRange < 0.20 { return nil }

    return [
        PdfColumnRegion(xMin: pageXMin, xMax: bestSplit),
        PdfColumnRegion(xMin: bestSplit, xMax: pageXMax),
    ]
}

/// Whether the columns are independent flows to be read one after another.
///
/// Three routes to yes, in decreasing confidence: dense columns of similar
/// length; a narrow sparse sidebar beside a dense body; or, for columns of
/// unequal length, the shortest column's lines mostly colliding with another
/// column's — which means they were set side by side rather than following
/// one another.
func pdfIsNewspaperLayout(
    _ perColumnLines: [[PdfTextLine]], _ columns: [PdfColumnRegion]
) -> Bool {
    if perColumnLines.count < 2 { return false }

    let minimumLines = perColumnLines.map(\.count).min() ?? 0
    let maximumLines = perColumnLines.map(\.count).max() ?? 0
    if minimumLines < 5 { return false }

    if minimumLines < 15 {
        // The sidebar case, and the only route out of this branch. Every
        // guard has to hold: exactly two columns, one much narrower, one with
        // far fewer lines, a substantial body, and a sidebar wide enough to
        // be a column rather than a margin note.
        guard columns.count == 2, perColumnLines.count == 2 else { return false }
        let width0 = columns[0].xMax - columns[0].xMin
        let width1 = columns[1].xMax - columns[1].xMin
        let widthRatio = min(width0, width1) / max(width0, width1)
        let lineBalance = maximumLines > 0 ? Float(minimumLines) / Float(maximumLines) : 1
        let narrowWidth = min(width0, width1)
        guard widthRatio < 0.50, lineBalance < 0.35, maximumLines >= 20, narrowWidth >= 160
        else { return false }

        // The narrower column must also be the emptier one — a narrow column
        // packed with lines is a dense reference table, not a sidebar.
        let narrowerIndex = width0 < width1 ? 0 : 1
        let fewestIndex = perColumnLines[0].count <= perColumnLines[1].count ? 0 : 1
        guard narrowerIndex == fewestIndex else { return false }

        // Sidebar annotations are spread thinly down the page where body text
        // is dense, so the average line spacing separates them.
        func averageGap(_ lines: [PdfTextLine]) -> Float {
            if lines.count < 2 { return 0 }
            let ys = lines.map(\.y).sorted { $0 < $1 }
            return ((ys.last ?? 0) - (ys.first ?? 0)) / Float(lines.count - 1)
        }
        let narrowGap = averageGap(perColumnLines[narrowerIndex])
        let wideGap = averageGap(perColumnLines[1 - narrowerIndex])
        return wideGap > 0 && narrowGap / wideGap >= 2.5
    }

    // Dense and balanced is newspaper whatever the baselines do. Table items
    // have already been removed by this point, so two dense columns of what
    // remains are independent prose.
    let balance = Float(minimumLines) / Float(maximumLines)
    if balance > 0.7 { return true }

    // Unbalanced: fall back to asking whether the shortest column's lines sit
    // *beside* another column's rather than after them. Five points of
    // tolerance rather than three, which government gazette typesetting needs.
    let yTolerance: Float = 5
    // Rust's `min_by_key` returns the first minimum — unlike `max_by_key`,
    // which returns the last — and so does this.
    var smallestIndex = 0
    var smallestCount = Int.max
    for (index, column) in perColumnLines.enumerated() where column.count < smallestCount {
        smallestCount = column.count
        smallestIndex = index
    }

    let smallest = perColumnLines[smallestIndex]
    var collisions = 0
    for line in smallest {
        for (index, column) in perColumnLines.enumerated() where index != smallestIndex {
            if column.contains(where: { abs($0.y - line.y) < yTolerance }) {
                collisions += 1
                break
            }
        }
    }
    return Float(collisions) / Float(smallest.count) > 0.5
}
