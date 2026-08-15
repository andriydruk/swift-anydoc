/// Where a table or an image sits in the reading order, ported from
/// `convert.rs`: `ChartProseOrder`, `PositionedMarkdown`,
/// `chart_stream_position`, `positioned_block_precedes_line`,
/// `compare_positioned_blocks` and `positioned_blocks_for_page`.
///
/// Tables and images are lifted out of the page before the text is grouped
/// into lines, and have to be put back in the right place afterwards. On an
/// ordinary page that is just a matter of baseline. On a page where a
/// full-width chart cuts between two prose columns it is not: the physical
/// order and the reading order diverge, and a right-column table would
/// otherwise be emitted ahead of the left-column prose it follows.
///
/// The fix is to give every block the same *logical stream* coordinate the
/// text uses, so both are ordered by the same rule.

/// A page whose full-width chart separates two prose columns.
struct PdfChartProseOrder: Equatable {
    /// The x that divides the two prose columns.
    var splitX: Float
    /// The chart's bounds, as the reference holds them: `(x0, y0, x1, y1)`.
    var chartRegion: (x0: Float, y0: Float, x1: Float, y1: Float)

    static func == (left: Self, right: Self) -> Bool {
        left.splitX == right.splitX && left.chartRegion == right.chartRegion
    }
}

/// A rendered block with the position it was lifted from.
struct PdfPositionedMarkdown {
    var y: Float
    var x: Float
    var markdown: String
    /// Present only on chart pages. Its absence is what selects the ordinary
    /// ordering everywhere else.
    var chartOrder: PdfChartProseOrder?
}

/// Tables sort before images where the two are otherwise equal, which is the
/// declaration order of the reference's enum.
enum PdfPositionedBlockKind: Int, Comparable {
    case table = 0
    case image = 1

    static func < (left: Self, right: Self) -> Bool { left.rawValue < right.rawValue }
}

/// A block, its index among its own kind, and the block itself.
typealias PdfPositionedBlockRef = (
    kind: PdfPositionedBlockKind, index: Int, block: PdfPositionedMarkdown
)

/// The chart band is treated as this much taller than it draws, so text
/// sitting just above or below it still counts as part of the band.
let pdfChartSeparatorPad: Float = 8

/// Where a point falls in the page's logical stream, as `(zone, column)`.
///
/// The pair is compared lexicographically, so zone dominates: everything
/// above the chart, then the chart band itself, then everything below.
/// Within a zone the left column precedes the right.
///
/// Anything inside the band — or claimed by the chart regardless of where it
/// sits — is put in **column zero**, because a full-width chart has no
/// columns to be on either side of.
func pdfChartStreamPosition(
    y: Float, x: Float, claimedByChart: Bool, order: PdfChartProseOrder
) -> (zone: UInt8, column: UInt8) {
    // The band is normalised, so a region given bottom-up reads the same.
    let low = min(order.chartRegion.y0, order.chartRegion.y1) - pdfChartSeparatorPad
    let high = max(order.chartRegion.y0, order.chartRegion.y1) + pdfChartSeparatorPad
    let inChartZone = claimedByChart || (y >= low && y <= high)

    let zone: UInt8
    if inChartZone {
        zone = 1
    } else if y > high {
        zone = 0
    } else {
        zone = 2
    }
    let column: UInt8 = (inChartZone || x < order.splitX) ? 0 : 1
    return (zone, column)
}

/// Whether a block should be emitted before a given line.
///
/// Off a chart page this is bare geometry — higher on the page comes first.
/// On one, the stream position leads and the baseline only breaks ties
/// within a single zone and column.
func pdfPositionedBlockPrecedesLine(_ block: PdfPositionedMarkdown, _ line: PdfTextLine) -> Bool {
    guard let order = block.chartOrder else { return block.y > line.y }

    // The line's own x is its *first* item's, and a line with no items at
    // all reads as x zero — which puts it in the left column.
    let lineX = line.items.first?.x ?? 0
    let lineClaimed = line.items.contains {
        pdfItemIsInChartRegion(
            $0,
            [
                PdfImageRegion(
                    x0: order.chartRegion.x0, y0: order.chartRegion.y0,
                    x1: order.chartRegion.x1, y1: order.chartRegion.y1)
            ])
    }
    let blockPosition = pdfChartStreamPosition(
        y: block.y, x: block.x, claimedByChart: false, order: order)
    let linePosition = pdfChartStreamPosition(
        y: line.y, x: lineX, claimedByChart: lineClaimed, order: order)

    if blockPosition != linePosition {
        return blockPosition < linePosition
    }
    return block.y > line.y
}

/// Order two blocks against each other.
///
/// **Both** must carry a chart order for the logical comparison to apply; a
/// single ordinary block drops the pair back to the legacy ordering, which
/// is detection order within kind and tables before images. That is a
/// genuinely inconsistent comparator on a mixed page — but a page either has
/// a chart stream or it does not, so the mixed case does not arise in
/// practice, and it is reproduced rather than repaired.
func pdfComparePositionedBlocks(_ left: PdfPositionedBlockRef, _ right: PdfPositionedBlockRef)
    -> Bool
{
    if let leftOrder = left.block.chartOrder, let rightOrder = right.block.chartOrder {
        let leftPosition = pdfChartStreamPosition(
            y: left.block.y, x: left.block.x, claimedByChart: false, order: leftOrder)
        let rightPosition = pdfChartStreamPosition(
            y: right.block.y, x: right.block.x, claimedByChart: false, order: rightOrder)
        if leftPosition != rightPosition { return leftPosition < rightPosition }
        // Descending y, then ascending x, then kind, then index. The
        // reference uses `total_cmp`, so these are total orders over floats
        // rather than the partial `<` — the difference shows only on NaN,
        // which cannot reach here from a parsed page.
        if left.block.y != right.block.y { return left.block.y > right.block.y }
        if left.block.x != right.block.x { return left.block.x < right.block.x }
        if left.kind != right.kind { return left.kind < right.kind }
        return left.index < right.index
    }
    if left.kind != right.kind { return left.kind < right.kind }
    return left.index < right.index
}

/// Every block on a page, in the order it should be emitted.
func pdfPositionedBlocksForPage(
    tables: [PdfPositionedMarkdown], images: [PdfPositionedMarkdown]
) -> [PdfPositionedBlockRef] {
    var blocks: [PdfPositionedBlockRef] = []
    blocks.append(contentsOf: tables.enumerated().map { (.table, $0.offset, $0.element) })
    blocks.append(contentsOf: images.enumerated().map { (.image, $0.offset, $0.element) })
    // `sort_by` is stable in Rust. Every comparison here ends in a kind and
    // index tiebreak, which is unique per block, so stability changes
    // nothing — but the enumerated index is kept as the final key anyway.
    return blocks.enumerated().sorted { left, right in
        if pdfComparePositionedBlocks(left.element, right.element) { return true }
        if pdfComparePositionedBlocks(right.element, left.element) { return false }
        return left.offset < right.offset
    }.map(\.element)
}
