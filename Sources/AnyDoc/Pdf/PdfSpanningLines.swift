/// Reconciling a page's columns with the lines that ignore them, ported from
/// `extractor/layout.rs` in pdf-inspector: `identify_spanning_lines` and
/// `split_column_stragglers`.
///
/// Waves 61 and 62 decided where the columns are. A real page then breaks
/// them: a title runs the full width, a section header sits across the
/// gutter, a footer belongs to neither column. Those items have to be pulled
/// out before the columns are read in sequence, or the title arrives halfway
/// through column one.
///
/// The hard part is that a spanning title and two columns' worth of text at
/// the same height look identical from their x extents alone. What separates
/// them is *where the gaps fall* — a genuine spanning line has no gap sitting
/// at a gutter, because nothing interrupts it there.

/// Which items belong to lines that run across the columns.
///
/// Returns a mask parallel to `items`. A line qualifies when it is half again
/// wider than the widest column *and* has no inter-item gap at a gutter — the
/// second test being what tells a title apart from two columns of body text
/// sharing a baseline.
func pdfIdentifySpanningLines(
    _ items: [PdfLayoutItem], _ columns: [PdfColumnRegion]
) -> [Bool] {
    var mask = [Bool](repeating: false, count: items.count)
    if items.count < 3 || columns.count < 2 { return mask }

    var maximumColumnWidth: Float = 0
    for column in columns { maximumColumnWidth = max(maximumColumnWidth, column.xMax - column.xMin) }
    let spanThreshold = maximumColumnWidth * 1.3

    // A gutter is the right edge of every column but the last.
    let gutters = columns.dropLast().map(\.xMax)
    let gutterTolerance: Float = 15
    let yTolerance: Float = 5

    // Descending y, stably — Rust's `sort_by` keeps equal baselines in their
    // original order, and the grouping below walks the result in sequence.
    let indexed = items.enumerated().map { (index: $0.offset, y: $0.element.y) }
        .sorted { left, right in
            if left.y != right.y { return left.y > right.y }
            return left.index < right.index
        }

    // Rough lines by baseline proximity, held as index sets. As elsewhere in
    // this port the comparison is against the group's *first* baseline, so
    // drifting text does not chain.
    var groups: [[Int]] = []
    var current: [Int] = []
    var currentY = Float.nan
    for entry in indexed {
        if current.isEmpty || abs(currentY - entry.y) < yTolerance {
            if current.isEmpty { currentY = entry.y }
            current.append(entry.index)
        } else {
            groups.append(current)
            current = [entry.index]
            currentY = entry.y
        }
    }
    if !current.isEmpty { groups.append(current) }

    for group in groups {
        if group.count < 2 { continue }

        // Stable again: items at the same x keep the order the baseline sort
        // gave them.
        let byX = group.enumerated().sorted { left, right in
            let leftX = items[left.element].x
            let rightX = items[right.element].x
            if leftX != rightX { return leftX < rightX }
            return left.offset < right.offset
        }.map(\.element)

        guard let first = byX.first, let last = byX.last else { continue }
        let span = items[last].x + pdfEffectiveItemWidth(items[last]) - items[first].x
        if span <= spanThreshold { continue }

        // A gap at a gutter means these are two columns' items sharing a
        // baseline, not one line crossing the page. Gaps under 5pt are
        // word spacing and say nothing either way.
        var hasGutterGap = false
        for position in 0..<(byX.count - 1) {
            let leftItem = items[byX[position]]
            let leftEnd = leftItem.x + pdfEffectiveItemWidth(leftItem)
            let rightStart = items[byX[position + 1]].x
            if rightStart - leftEnd < 5 { continue }
            if gutters.contains(where: {
                $0 > leftEnd - gutterTolerance && $0 < rightStart + gutterTolerance
            }) {
                hasGutterGap = true
                break
            }
        }

        if !hasGutterGap {
            for index in byX { mask[index] = true }
        }
    }

    return mask
}

/// Separate a column's core text from the lines that merely landed in it.
///
/// A column region collects everything within its x range, which on a real
/// page includes remnants of the header above it and per-word fragments of a
/// full-width line below. Those sit far from the body, so the column is cut
/// at every unusually large vertical gap and the biggest remaining run is
/// kept as the core.
///
/// The threshold is relative — three times the column's own median line
/// spacing — with a 30pt floor so a tightly set column does not fragment on
/// ordinary paragraph breaks.
func pdfSplitColumnStragglers(
    _ lines: [PdfTextLine]
) -> (core: [PdfTextLine], stragglers: [PdfTextLine]) {
    if lines.count < 3 { return (lines, []) }

    // Lines arrive top-first, so a gap is the drop to the next baseline.
    var gaps: [Float] = []
    for index in 0..<(lines.count - 1) { gaps.append(lines[index].y - lines[index + 1].y) }

    let sortedGaps = gaps.sorted { $0 < $1 }
    let medianGap = sortedGaps[sortedGaps.count / 2]
    let threshold = max(medianGap * 3, 30)

    var splitIndices: [Int] = []
    for (index, gap) in gaps.enumerated() where gap > threshold { splitIndices.append(index) }
    if splitIndices.isEmpty { return (lines, []) }

    var segments: [(start: Int, end: Int)] = []
    var start = 0
    for index in splitIndices {
        segments.append((start, index + 1))
        start = index + 1
    }
    segments.append((start, lines.count))

    // Rust's `max_by_key` returns the **last** maximum where Swift's `max(by:)`
    // returns the first, so the comparison here is `>=` on purpose: with two
    // segments of equal length the lower one is the core.
    var coreIndex = 0
    var coreLength = -1
    for (index, segment) in segments.enumerated() where segment.end - segment.start >= coreLength {
        coreLength = segment.end - segment.start
        coreIndex = index
    }

    let core = segments[coreIndex]
    var kept: [PdfTextLine] = []
    var stragglers: [PdfTextLine] = []
    for (index, line) in lines.enumerated() {
        if index >= core.start && index < core.end {
            kept.append(line)
        } else {
            stragglers.append(line)
        }
    }
    return (kept, stragglers)
}
