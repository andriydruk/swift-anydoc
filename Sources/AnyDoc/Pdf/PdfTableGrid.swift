/// Column and row geometry for table detection, ported from
/// pdf-inspector's `tables/grid.rs`.
///
/// This is the foundation the four detection strategies all stand on: given
/// the text items in a candidate region, where are the columns, where are the
/// rows, which cell does an item fall in, and how does a cell's fragments
/// join into one string.
///
/// The hard part is columns. A table's columns are a clustering of x
/// positions, and the right threshold depends on the table: a dense train
/// schedule with twenty-four columns at 26pt spacing and a two-column layout
/// with 200pt spacing cannot share one. The reference picks the threshold by
/// looking at the *distribution* of gaps, and the branches below are its.

/// Which pass is asking. The body-font pass applies a safeguard the
/// small-font pass does not, because its candidates include ordinary prose.
enum PdfTableDetectionMode {
    /// Items smaller than the body text, the classic signal.
    case smallFont
    /// Body-sized items, which need stricter structural evidence.
    case bodyFont
}

/// Whether the text reads as a number: digits with the punctuation numbers
/// carry, and at least one digit. `3,456.78` and `+5%` qualify; `BIO` and
/// `Core Courses` do not.
func pdfIsNumericText(_ text: String) -> Bool {
    let trimmed = text.rustTrim()
    guard !trimmed.isEmpty else { return false }
    let allowed: Set<Unicode.Scalar> = [".", ",", "-", "+", "%"]
    var sawDigit = false
    for scalar in trimmed.unicodeScalars {
        if scalar >= "0", scalar <= "9" {
            sawDigit = true
        } else if !allowed.contains(scalar) {
            return false
        }
    }
    return sawDigit
}

/// The mean of a non-empty list.
private func pdfMean(_ values: [Float]) -> Float {
    values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
}

/// The x positions of a region's items, clustered into columns.
func pdfFindColumnBoundaries(
    _ items: [PdfLayoutItem], mode: PdfTableDetectionMode = .smallFont
) -> [Float] {
    let xs = items.map(\.x).sorted()
    guard let first = xs.first, let last = xs.last else { return [] }

    let range = last - first
    let averageGap = xs.count > 1 ? range / Float(xs.count - 1) : 60

    // The default: cluster around the running mean, at a threshold derived
    // from the average spacing.
    var clusterThreshold = min(max(averageGap, 25), 50)
    var useEdgeClustering = false

    // A table with densely packed columns has a bimodal gap distribution —
    // small gaps within a column, large ones between — and the average is
    // dominated by the within-column ones, so it over-clusters. Look for the
    // break between the two modes.
    var gaps = zip(xs, xs.dropFirst()).map { $1 - $0 }.filter { $0 > 0.1 }
    if gaps.count > 2 {
        gaps.sort()
        // At least three values either side, or a single wide page-margin gap
        // decides the split on its own.
        let minimumSide = min(3, gaps.count / 2)
        var bestSplit = gaps.count / 2
        var bestJump: Float = 0
        for index in 0..<max(gaps.count - 1, 0) {
            let leftCount = index + 1
            let rightCount = gaps.count - index - 1
            if leftCount < minimumSide || rightCount < minimumSide { continue }
            let jump = gaps[index + 1] - gaps[index]
            if jump > bestJump {
                bestJump = jump
                bestSplit = index
            }
        }
        let threshold = (gaps[bestSplit] + gaps[min(bestSplit + 1, gaps.count - 1)]) / 2

        if threshold < 15, bestJump > 2, xs.count > 500 {
            // A genuinely dense table. Clustering from the *edge* rather than
            // the mean avoids the centre drift that merges adjacent narrow
            // columns.
            clusterThreshold = min(max(threshold, 8), 25)
            useEdgeClustering = true
        } else if bestJump > 10, threshold < clusterThreshold {
            // A strong bimodal signal with fewer items: take the lower
            // threshold but keep clustering around the mean, which does not
            // over-split wide columns.
            clusterThreshold = max(threshold, 8)
        }
    }

    var clusters: [[Float]] = [[first]]
    for x in xs.dropFirst() {
        guard let current = clusters.last else { continue }
        let reference = useEdgeClustering ? (current.last ?? x) : pdfMean(current)
        if x - reference > clusterThreshold {
            clusters.append([x])
        } else {
            clusters[clusters.count - 1].append(x)
        }
    }

    if clusters.count >= 3 {
        clusters = pdfMergeNumericAdjacentClusters(clusters, items, clusterThreshold)
    }

    var columns = clusters.map(pdfMean)

    // A column needs more than a stray item or two behind it.
    let minimumPerColumn = max(items.count / max(columns.count, 1) / 4, 2)
    columns = columns.filter { column in
        items.count(where: { abs($0.x - column) < clusterThreshold }) >= minimumPerColumn
    }

    // Prose concentrates at the left margin; a table spreads out. In the
    // body-font pass, a column holding more than three fifths of everything
    // means this was a paragraph.
    if mode == .bodyFont, !items.isEmpty {
        for column in columns {
            let count = items.count(where: { abs($0.x - column) < clusterThreshold })
            if Float(count) / Float(items.count) > 0.60 { return [] }
        }
    }
    return columns
}

/// Merge a sparse cluster into a dense numeric neighbour.
///
/// A wrapped multi-line header sits at a slightly different x from the data
/// beneath it, which splits one logical column in two. When one side is
/// mostly numbers and the other holds a handful of items, they are the same
/// column.
private func pdfMergeNumericAdjacentClusters(
    _ input: [[Float]], _ items: [PdfLayoutItem], _ threshold: Float
) -> [[Float]] {
    struct Info {
        var center: Float
        var count: Int
        var numericFraction: Float
    }
    func info(_ xs: [Float]) -> Info {
        let center = pdfMean(xs)
        var total = 0
        var numeric = 0
        for item in items where abs(item.x - center) < threshold {
            total += 1
            if pdfIsNumericText(item.text) { numeric += 1 }
        }
        return Info(
            center: center, count: total,
            numericFraction: total > 0 ? Float(numeric) / Float(total) : 0)
    }

    // Slightly beyond the clustering threshold, to catch header-versus-data
    // splits that the first pass separated.
    let mergeDistance = threshold * 1.5
    var clusters = input
    var merged = true
    while merged {
        merged = false
        var index = 0
        while index + 1 < clusters.count {
            let a = info(clusters[index])
            let b = info(clusters[index + 1])
            guard abs(b.center - a.center) <= mergeDistance else {
                index += 1
                continue
            }
            let sparse = a.count < b.count ? a : b
            let dense = a.count < b.count ? b : a
            let shouldMerge =
                dense.numericFraction > 0.50 && sparse.count <= dense.count / 2
                && sparse.count <= 5
            if shouldMerge {
                clusters[index] += clusters.remove(at: index + 1)
                merged = true
                // Do not advance: the merged cluster may absorb another.
            } else {
                index += 1
            }
        }
    }
    return clusters
}

/// The y positions of a region's items, clustered into rows, top first.
///
/// The threshold is four fifths of the median font size, which sits between
/// the near-zero gaps within a row and the full-line gaps between rows.
func pdfFindRowBoundaries(_ items: [PdfLayoutItem]) -> [Float] {
    let ys = items.map(\.y).sorted(by: >)
    guard let first = ys.first else { return [] }

    let sizes = items.map(\.fontSize).sorted()
    let clusterThreshold = max(sizes[sizes.count / 2] * 0.8, 4)

    var rows: [Float] = []
    var current: [Float] = [first]
    for y in ys.dropFirst() {
        let center = pdfMean(current)
        if center - y >= clusterThreshold {
            rows.append(center)
            current = [y]
        } else {
            current.append(y)
        }
    }
    if !current.isEmpty { rows.append(pdfMean(current)) }
    return rows
}

/// The column an x position belongs to, or none when it sits between them.
///
/// The tolerance is half the *tightest* column gap, so a table of narrow
/// columns does not claim items belonging to its neighbours — bounded to the
/// same 25–50pt band the clustering uses.
func pdfFindColumnIndex(_ columns: [Float], _ x: Float) -> Int? {
    let threshold: Float
    if columns.count >= 2 {
        let minimumGap = zip(columns, columns.dropFirst()).map { abs($1 - $0) }.min() ?? .infinity
        threshold = min(max(minimumGap / 2, 25), 50)
    } else {
        threshold = 50
    }
    return pdfNearestIndex(columns, x, within: threshold)
}

/// The row a y position belongs to.
func pdfFindRowIndex(_ rows: [Float], _ y: Float) -> Int? {
    pdfNearestIndex(rows, y, within: 15)
}

/// The nearest boundary's index, if it is close enough.
///
/// Ties go to the earlier boundary, as `min_by` keeps the first minimum.
private func pdfNearestIndex(_ boundaries: [Float], _ value: Float, within threshold: Float) -> Int?
{
    var best: Int?
    var bestDistance = Float.infinity
    for (index, boundary) in boundaries.enumerated() {
        let distance = abs(value - boundary)
        if distance < bestDistance {
            bestDistance = distance
            best = index
        }
    }
    guard let best, abs(value - boundaries[best]) < threshold else { return nil }
    return best
}

/// Join a cell's fragments into one string.
///
/// Like a line's own text, but the decisions are a cell's: a hyphen binds
/// what it joins, an opening bracket binds what follows it, and a
/// sub/superscript binds to the token it belongs to — recognised by a font
/// size change of more than fifteen percent together with a baseline shift.
func pdfJoinCellItems(_ items: [PdfLayoutItem]) -> String {
    var result = ""
    for (index, item) in items.enumerated() {
        let text = item.text.rustTrim()
        if text.isEmpty { continue }
        if result.isEmpty {
            result = text
            continue
        }
        // The previous *item*, which may have been an empty one that
        // contributed nothing — the reference indexes back by one regardless.
        let previous = items[index - 1]

        let previousEndsWithHyphen = result.hasSuffix("-")
        let startsWithHyphen = text.hasPrefix("-")
        let previousOpensDelimiter =
            result.hasSuffix("(") || result.hasSuffix("[") || result.hasSuffix("{")
        let closesDelimiter =
            text.hasPrefix(")") || text.hasPrefix("]") || text.hasPrefix("}")

        let yShift = abs(item.y - previous.y)
        let isScript =
            previous.fontSize > 0 && item.fontSize / previous.fontSize < 0.85 && yShift > 1
        let wasScript =
            item.fontSize > 0 && previous.fontSize / item.fontSize < 0.85 && yShift > 1

        if previousEndsWithHyphen || startsWithHyphen || isScript || wasScript
            || previousOpensDelimiter || closesDelimiter
        {
            result += text
        } else {
            result += " " + text
        }
    }
    return result
}
