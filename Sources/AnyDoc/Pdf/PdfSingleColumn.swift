/// Grouping one column's runs into lines, ported from `group_single_column`
/// and `should_use_y_sorting` in `extractor/layout.rs`.
///
/// Wave 4's grouper sorted every run by baseline and trusted the result.
/// This one does not: a PDF's stream order is usually already reading order,
/// and sorting destroys information when two runs share a baseline. So the
/// stream order is kept unless it looks *chaotic*, and the grouping then
/// walks it in sequence, only ever merging into the line most recently
/// opened.
///
/// That single-line lookback is the design. A run that does not belong with
/// the previous line opens a new one, and the previous line is never revisited
/// — which is why the tests for "is this really the same line" have to be
/// thorough. There are three of them, and the last is the subtlest: two
/// columns whose gutter is too narrow for column detection still have to be
/// split, and the only evidence is that both sides read like prose.

/// Baselines within this are the same line.
private let pdfSingleColumnYTolerance: Float = 3
/// A jump larger than this is a real move rather than a sub- or superscript.
private let pdfChaosJumpThreshold: Float = 50

/// Whether the stream order is too chaotic to trust.
///
/// In reading order y mostly decreases, since PDF's origin is bottom-left.
/// Counting how often it jumps *up* instead measures how badly the producer
/// scattered its runs — a generator that draws all the headings first, then
/// the body, jumps up constantly.
///
/// Note both the sample and the verdict are deliberately coarse: fewer than
/// five items, or fewer than three large jumps, and the question is not asked
/// at all.
func pdfShouldUseYSorting(_ items: [PdfLayoutItem]) -> Bool {
    if items.count < 5 { return false }

    var jumpsUp = 0
    var jumpsDown = 0
    for index in 0..<(items.count - 1) {
        let delta = items[index + 1].y - items[index].y
        if delta > pdfChaosJumpThreshold {
            jumpsUp += 1
        } else if delta < -pdfChaosJumpThreshold {
            jumpsDown += 1
        }
    }

    let total = jumpsUp + jumpsDown
    if total < 3 { return false }
    // More than two in five jumps going the wrong way is chaos.
    return Float(jumpsUp) / Float(total) > 0.4
}

/// Group a column's runs into lines.
///
/// The reference also refuses to merge across a page boundary; this port is
/// called with one page's items at a time, so that test is not expressible
/// and not needed.
func pdfGroupSingleColumn(_ items: [PdfLayoutItem]) -> [PdfTextLine] {
    if items.isEmpty { return [] }

    var ordered = items
    if pdfShouldUseYSorting(items) {
        // Descending baseline, then left to right. Stable, as the
        // reference's sort is.
        ordered = items.enumerated().sorted { left, right in
            if left.element.y != right.element.y { return left.element.y > right.element.y }
            if left.element.x != right.element.x { return left.element.x < right.element.x }
            return left.offset < right.offset
        }.map(\.element)
    }

    var lines: [PdfTextLine] = []
    for item in ordered {
        var shouldMerge = false
        if let last = lines.last {
            shouldMerge = pdfBelongsToLine(last, item)
        }

        if shouldMerge {
            lines[lines.count - 1].items.append(item)
        } else {
            lines.append(PdfTextLine(items: [item], y: item.y))
        }
    }

    for index in lines.indices { pdfSortLineItems(&lines[index].items) }
    return lines
}

/// Whether a run belongs on the line most recently opened.
private func pdfBelongsToLine(_ line: PdfTextLine, _ item: PdfLayoutItem) -> Bool {
    let yDifference = abs(line.y - item.y)
    if yDifference >= pdfSingleColumnYTolerance { return false }

    // Within tolerance but not identical: the runs may be stacked lines
    // rather than one line, and two shapes say so.
    if yDifference > 0.5, let first = line.items.first {
        // Starting at the same left margin is what a new line looks like.
        if abs(item.x - first.x) < 5 { return false }
        // So is starting appreciably to the left of where the line has
        // reached — that is a carriage return, not an out-of-order run.
        if let last = line.items.last, item.x < last.x - 10 { return false }
    }

    // The subtle one: the same baseline, a wide void between, and the
    // incoming run starting with a letter. That is the neighbouring column's
    // body text sharing a baseline, in a gutter too narrow for column
    // detection to have found.
    //
    // Note the raw `width` here rather than the estimate used elsewhere: an
    // item with no measured width gives a gap computed from its left edge
    // alone, which reads as *wider* and so splits more readily.
    if let last = line.items.last {
        let gap = item.x - (last.x + last.width)
        let threshold = max(max(item.fontSize, last.fontSize) * 3, 30)
        guard gap > threshold,
            let firstScalar = item.text.rustTrim().unicodeScalars.first,
            firstScalar.properties.isAlphabetic
        else { return true }

        // Both sides must read as prose. This is what keeps a table of
        // contents intact: its page numbers, dot leaders and
        // outline-numbered cells start with digits or are too short to
        // qualify.
        let incoming = item.text.rustTrim()
        let incomingWordy =
            incoming.rustSplitWhitespace().count >= 3
            && incoming.unicodeScalars.filter { $0.properties.isAlphabetic }.count >= 10
        let lineText = line.items.map { $0.text.rustTrim() }.joined(separator: " ")
        let lineWordy =
            lineText.rustSplitWhitespace().count >= 2
            && lineText.unicodeScalars.filter { $0.properties.isAlphabetic }.count >= 8

        // A lowercase start is a mid-sentence continuation and splits on the
        // prose signals alone. An uppercase start needs corroboration from
        // style as well — a bold heading beside regular body text — or rows
        // of same-styled labels would shatter.
        let startsLower = firstScalar.properties.isLowercase
        // The *whole* line must be bold for that to count, not merely its
        // last run, so a bold-label-and-value row stays joined.
        let styleMismatch = line.items.allSatisfy { $0.isBold } && !item.isBold

        if lineWordy && incomingWordy && (startsLower || styleMismatch) { return false }
    }

    return true
}
