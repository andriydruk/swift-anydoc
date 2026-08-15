/// Side-by-side regions, ported from `split_side_by_side` in
/// `markdown/mod.rs`.
///
/// Two independent tables set beside each other look, to a column detector,
/// exactly like one wide table with a big inner gap. Getting it wrong either
/// way is bad: reading two tables as one interleaves their rows, and reading
/// one as two splits every row in half.
///
/// So this is deliberately hard to satisfy. A candidate gap must be wide,
/// central and balanced; it must be crossed by almost nothing; it must be the
/// **only** such gap on the page; and the two sides must not look like a
/// label column beside a number column, which is one table however wide the
/// gap between them.

/// Below this many runs the page is too sparse to judge.
private let pdfSideBySideMinimumItems = 40
/// A candidate gap must be at least this wide.
private let pdfSideBySideMinimumGap: Float = 30
/// And have at least this many runs to either side of it.
private let pdfSideBySideMinimumPerSide = 20

/// The two x bands a page divides into, or nothing if it does not.
func pdfSplitSideBySide(_ items: [PdfLayoutItem]) -> [(low: Float, high: Float)] {
    if items.count < pdfSideBySideMinimumItems { return [] }

    let xs = items.map(\.x).sorted { $0 < $1 }
    guard let xMin = xs.first, let xMax = xs.last else { return [] }
    let range = xMax - xMin
    // Only the middle three fifths: a gap near either margin is whitespace,
    // not a division.
    let centreLow = xMin + range * 0.2
    let centreHigh = xMin + range * 0.8

    var candidates: [Float] = []
    for index in 1..<xs.count {
        let gap = xs[index] - xs[index - 1]
        let splitX = (xs[index - 1] + xs[index]) / 2
        if gap >= pdfSideBySideMinimumGap && index >= pdfSideBySideMinimumPerSide
            && xs.count - index >= pdfSideBySideMinimumPerSide
            && splitX >= centreLow && splitX <= centreHigh
        {
            candidates.append(splitX)
        }
    }
    if candidates.isEmpty { return [] }

    // Balance is counted by *centre* rather than left edge, which is the
    // more honest measure of which side a run belongs to.
    let minimumSide = items.count / 5
    func isBalanced(_ splitX: Float) -> Bool {
        let leftCount = items.filter { $0.x + $0.width / 2 < splitX }.count
        return min(leftCount, items.count - leftCount) >= minimumSide
    }

    var bestSplit: Float = 0
    var bestCrossing = Int.max
    for splitX in candidates where isBalanced(splitX) {
        let crossing = items.filter { $0.x < splitX && $0.x + $0.width > splitX }.count
        // Strictly fewer, so the leftmost of equally good splits wins.
        if crossing < bestCrossing {
            bestCrossing = crossing
            bestSplit = splitX
        }
    }
    if bestCrossing == Int.max { return [] }

    // A spanning header or two may cross; a fifth of the page may not.
    let maximumCrossing = max(items.count / 20, 2)
    if bestCrossing > maximumCrossing { return [] }

    // Several balanced candidates far apart mean one multi-column table
    // rather than two regions. Candidates within 50pt are the same gap.
    var balanced = candidates.filter(isBalanced).sorted { $0 < $1 }
    var clustered: [Float] = []
    for position in balanced {
        if let last = clustered.last, abs(position - last) < 50 { continue }
        clustered.append(position)
    }
    balanced = clustered
    if balanced.count > 1 { return [] }

    // The last refusal: a column of labels beside a column of numbers is one
    // table. All three signs must show — text on the left, numbers on the
    // right, and the two lining up row for row.
    func isNumeric(_ item: PdfLayoutItem) -> Bool {
        let text = item.text.rustTrim()
        if text.isEmpty { return false }
        let dataCharacters = text.unicodeScalars.filter { scalar in
            pdfIsAsciiDigitScalarValue(scalar) || pdfNumericPunctuation.contains(scalar)
        }.count
        return Float(dataCharacters) / Float(text.unicodeScalars.count) >= 0.6
    }

    let leftItems = items.filter { $0.x + $0.width / 2 < bestSplit }
    let rightItems = items.filter { $0.x + $0.width / 2 >= bestSplit }
    if !leftItems.isEmpty && !rightItems.isEmpty {
        let leftNumericRatio = Float(leftItems.filter(isNumeric).count) / Float(leftItems.count)
        let rightNumericRatio =
            Float(rightItems.filter(isNumeric).count) / Float(rightItems.count)
        if leftNumericRatio < 0.30 && rightNumericRatio >= 0.70 {
            let yTolerance: Float = 5
            let matches = rightItems.filter { right in
                leftItems.contains { abs($0.y - right.y) < yTolerance }
            }.count
            if Float(matches) / Float(rightItems.count) >= 0.5 { return [] }
        }
    }

    return [(xMin, bestSplit), (bestSplit, xMax)]
}

/// The punctuation that reads as part of a number: separators, signs, and the
/// currency marks a figure column carries.
private let pdfNumericPunctuation: Set<Unicode.Scalar> = [
    ",", ".", "-", "+", "%", "€", "$", "£", "¥", "(", ")",
]
