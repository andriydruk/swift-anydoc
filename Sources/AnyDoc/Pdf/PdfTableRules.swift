/// The horizontal-rule primitives that line-based table detection is built
/// on, ported from pdf-inspector's `tables/detect_lines.rs` (plus
/// `snap_edges`, which it borrows from `detect_rects.rs`).
///
/// Many forms and government PDFs draw their grids with `m`/`l`/`S` path
/// operators rather than `re` rectangles, so the table is a scatter of
/// stroked segments. Before any of the six table-building strategies in that
/// file can run, those segments have to be turned into *rules*: merged where
/// they were drawn a cell at a time, grouped where they share a span, and
/// split where two tables happen to share x endpoints.

/// Rules within this vertical distance are the same rule.
let pdfRuleYTolerance: Float = 2.0

/// Segments this close end-to-end were one rule drawn in pieces.
let pdfRuleJoinGap: Float = 6.0

/// How far two rules' endpoints may differ and still count as the same span.
private let pdfRuleSpanTolerance: Float = 8.0

/// Text baselines within this distance are one row, for the empty-gap test.
let pdfTextRowTolerance: Float = 2.5

/// A horizontal rule: a baseline and the span it covers.
struct PdfHorizontalRule: Equatable {
    var y: Float
    var xMin: Float
    var xMax: Float
}

/// Collapse near-equal values into one representative each, keeping the
/// lowest of each cluster.
///
/// Note this is a *sweep*, not a clustering: each value is compared against
/// the last one **kept**, not against its predecessor. So an evenly spaced
/// chain does not collapse to one edge — `[100, 102, 104, 106, 108]` at a 3pt
/// tolerance keeps `[100, 104, 108]`, because 104 is measured from 100 rather
/// than from 102.
func pdfSnapEdges(_ values: [Float], tolerance: Float) -> [Float] {
    var snapped: [Float] = []
    for value in values.sorted() {
        if let last = snapped.last, abs(value - last) <= tolerance { continue }
        snapped.append(value)
    }
    return snapped
}

/// Merge touching segments into logical rules.
///
/// A form often strokes one segment per cell at the same y. Treating those as
/// separate rules would manufacture column edges out of path endpoints, so
/// they are joined first and the columns recovered from the text instead.
func pdfMergeHorizontalSegments(_ horizontals: [PdfHorizontalRule]) -> [PdfHorizontalRule] {
    // Down the page, then left to right.
    let sorted = horizontals.sorted {
        $0.y != $1.y ? $0.y > $1.y : $0.xMin < $1.xMin
    }

    // Rows, formed against the *first* rule of the group in progress — so a
    // slowly drifting set of baselines does not chain into one row.
    var rows: [[PdfHorizontalRule]] = []
    for rule in sorted {
        if let first = rows.last?.first, abs(first.y - rule.y) <= pdfRuleYTolerance {
            rows[rows.count - 1].append(rule)
        } else {
            rows.append([rule])
        }
    }

    var merged: [PdfHorizontalRule] = []
    for row in rows {
        let ordered = row.sorted { $0.xMin < $1.xMin }
        // The row's rules all take the mean baseline.
        let y = ordered.map(\.y).reduce(0, +) / Float(ordered.count)
        var current = PdfHorizontalRule(y: y, xMin: ordered[0].xMin, xMax: ordered[0].xMax)
        for rule in ordered.dropFirst() {
            if rule.xMin <= current.xMax + pdfRuleJoinGap {
                current.xMax = max(current.xMax, rule.xMax)
            } else {
                merged.append(current)
                current = PdfHorizontalRule(y: y, xMin: rule.xMin, xMax: rule.xMax)
            }
        }
        merged.append(current)
    }
    return merged.sorted { $0.y > $1.y }
}

/// Group rules that share a span, which is what the rules of one table do.
///
/// A rule joins the group whose first member it matches most closely, not
/// merely the first one it matches — so a rule sitting between two spans goes
/// to the nearer.
func pdfGroupRulesBySpan(_ rules: [PdfHorizontalRule]) -> [[PdfHorizontalRule]] {
    var groups: [[PdfHorizontalRule]] = []
    for rule in rules {
        var best: (index: Int, error: Float)?
        for (index, group) in groups.enumerated() {
            guard let first = group.first else { continue }
            guard abs(first.xMin - rule.xMin) <= pdfRuleSpanTolerance,
                abs(first.xMax - rule.xMax) <= pdfRuleSpanTolerance
            else { continue }
            let error = abs(first.xMin - rule.xMin) + abs(first.xMax - rule.xMax)
            if best == nil || error < best!.error { best = (index, error) }
        }
        if let best {
            groups[best.index].append(rule)
        } else {
            groups.append([rule])
        }
    }
    for index in groups.indices { groups[index].sort { $0.y > $1.y } }
    return groups
}

/// Whether the text is a numbered table caption — `Table 3`, `Table 12.`
///
/// The token after `table ` is stripped of everything that is not a digit
/// before parsing, so `3.` and `(4)` both count.
func pdfIsNumberedTableCaption(_ text: String) -> Bool {
    let lower = text.rustTrim().asciiLowercased()
    guard lower.hasPrefix("table ") else { return false }
    let rest = String(lower.dropFirst("table ".count))
    guard let token = rest.rustSplitWhitespace().first else { return false }
    var digits = Substring(token)
    while let first = digits.first, !(first >= "0" && first <= "9") { digits = digits.dropFirst() }
    while let last = digits.last, !(last >= "0" && last <= "9") { digits = digits.dropLast() }
    return !digits.isEmpty && UInt32(digits) != nil
}

/// Split a run of equal-span rules where two separate tables share endpoints.
///
/// Consecutive booktabs tables very often do. A numbered caption between two
/// rules is an explicit separator; failing that, a large *mostly empty* gap
/// is the fallback. Both sides must keep at least two rules, which protects a
/// long table whose top, middle and bottom rules straddle many text rows.
func pdfSplitIndependentRuleRuns(
    _ rules: [PdfHorizontalRule], items: [PdfLayoutItem]
) -> [[PdfHorizontalRule]] {
    guard let first = rules.first else { return [] }

    var groups: [[PdfHorizontalRule]] = []
    var current = [first]
    for index in 0..<max(rules.count - 1, 0) {
        let a = rules[index]
        let b = rules[index + 1]
        let yMin = min(a.y, b.y)
        let yMax = max(a.y, b.y)

        let hasCaption = items.contains {
            $0.y > yMin && $0.y < yMax && pdfIsNumberedTableCaption($0.text)
        }

        let canFormTwoRuns = index + 1 >= 2 && rules.count - (index + 1) >= 2
        let ruleGap = yMax - yMin
        var hasEmptySeparator = false
        if canFormTwoRuns, ruleGap >= 36 {
            let xMin = min(a.xMin, b.xMin) - pdfRuleJoinGap
            let xMax = max(a.xMax, b.xMax) + pdfRuleJoinGap
            var occupied = items.filter {
                !$0.text.rustTrim().isEmpty && $0.y > yMin && $0.y < yMax
                    && $0.x + max($0.width, 0) >= xMin && $0.x <= xMax
            }.map(\.y)
            occupied.append(yMin)
            occupied.append(yMax)
            occupied.sort()
            // `dedup_by` drops each value within tolerance of the last kept.
            var distinct: [Float] = []
            for value in occupied
            where !(distinct.last.map { abs(value - $0) <= pdfTextRowTolerance } ?? false) {
                distinct.append(value)
            }
            let largestGap = zip(distinct, distinct.dropFirst()).map { $1 - $0 }.max() ?? 0
            hasEmptySeparator = largestGap >= max(36, ruleGap * 0.45)
        }

        if hasCaption || hasEmptySeparator {
            groups.append(current)
            current = [b]
        } else {
            current.append(b)
        }
    }
    groups.append(current)
    return groups
}

/// Whether the rules are evenly spaced enough to be a drawn grid rather than
/// the rules of a table whose rows vary.
///
/// Two percent relative standard deviation is a tight bar, and deliberately
/// so: this distinguishes ruled *paper* from a ruled table.
func pdfRulesAreUniformGrid(_ rules: [PdfHorizontalRule]) -> Bool {
    guard rules.count >= 5 else { return false }
    let spacings = zip(rules, rules.dropFirst()).map { abs($0.y - $1.y) }
    let mean = spacings.reduce(0, +) / Float(spacings.count)
    guard mean > 0.1 else { return false }
    let variance =
        spacings.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(spacings.count)
    return variance.squareRoot() / mean < 0.02
}

/// Recover column positions from where the horizontal rules start and stop.
///
/// A segmented table draws each cell's rule separately, so the segment
/// endpoints *are* the column edges — but only those that recur down the
/// table. An endpoint touching fewer than half the rows is a ragged edge, not
/// a column.
func pdfDeriveColumnsFromHorizontalSegments(_ horizontals: [PdfHorizontalRule]) -> [Float]? {
    guard horizontals.count >= 3 else { return nil }

    let endpoints = horizontals.flatMap { [$0.xMin, $0.xMax] }
    let clusters = pdfSnapEdges(endpoints, tolerance: 5)
    guard clusters.count >= 3 else { return nil }

    // Rows are counted on a tenth-point grid, loose enough to survive the
    // 3pt clustering applied to row edges later.
    func rowKey(_ y: Float) -> Int32 { Int32((y * 10).rounded()) }
    let uniqueRows = Set(horizontals.map { rowKey($0.y) })
    guard uniqueRows.count >= 2 else { return nil }
    let minimumRows = Int((Float(uniqueRows.count) * 0.5).rounded(.up))

    let qualifying = clusters.filter { cluster in
        let touched = Set(
            horizontals
                .filter { abs($0.xMin - cluster) < 5 || abs($0.xMax - cluster) < 5 }
                .map { rowKey($0.y) })
        return touched.count >= minimumRows
    }
    return qualifying.count >= 3 ? qualifying : nil
}
