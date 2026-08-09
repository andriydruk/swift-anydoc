/// Choosing between competing table interpretations, ported from the
/// hypothesis-selection cluster in pdf-inspector's `tables/detect_lines.rs`.
///
/// A ruled page rarely yields one obvious table. The reference builds several
/// *hypotheses* over the same items — a stacked-token reading, a text-anchor
/// reading, a dense-row-anchor reading, an open-edge grid — and then has to
/// pick. It does not try to decide which strategy is cleverer; it scores each
/// result on how much evidence it actually accounts for, takes the best, and
/// then takes the best of what is left over that does not overlap it.
///
/// That greedy-by-evidence shape is the whole design: a strategy that
/// explains more of the page wins, whatever produced it.

/// How much of the page a table accounts for.
///
/// The weights are the reference's and are worth reading as a statement of
/// priorities: an item consumed is worth far more than a cell filled, and a
/// column occupied is worth three times a row, because spanning columns is
/// what distinguishes a table from a list. Empty cells are a small penalty —
/// enough to prefer a tight grid over a sparse one covering the same items,
/// not enough to reject a legitimately ragged table.
func pdfTableEvidenceScore(_ table: PdfTable) -> Int {
    let filledCells = table.cells.flatMap { $0 }.count(where: { !$0.isEmpty })
    let occupiedRows = table.cells.count(where: { row in row.contains { !$0.isEmpty } })
    let columnCount = table.cells.first?.count ?? 0
    let occupiedColumns = (0..<columnCount).count(where: { column in
        table.cells.contains { row in column < row.count && !row[column].isEmpty }
    })
    let emptyCells = table.cells.count * columnCount - filledCells

    let positive =
        table.itemIndices.count * 100 + filledCells * 25 + occupiedColumns * 60
        + occupiedRows * 20
    // Saturating, as in the reference: a grid mostly empty must not score
    // negative and sort below a table that found nothing at all.
    return max(positive - max(emptyCells, 0) * 4, 0)
}

/// Take the best-scoring hypotheses that do not claim the same items.
///
/// Greedy: sort by evidence, and accept a table only if none of its items has
/// already been claimed. Ties go to the table consuming more items. The
/// survivors are returned down the page, since that is reading order.
func pdfSelectNonOverlappingHypotheses(_ candidates: [PdfTable]) -> [PdfTable] {
    let ordered = candidates.enumerated().sorted { left, right in
        let a = pdfTableEvidenceScore(left.element)
        let b = pdfTableEvidenceScore(right.element)
        if a != b { return a > b }
        if left.element.itemIndices.count != right.element.itemIndices.count {
            return left.element.itemIndices.count > right.element.itemIndices.count
        }
        // Rust's sort is stable, so equal candidates keep their input order.
        return left.offset < right.offset
    }.map(\.element)

    var selected: [PdfTable] = []
    var claimed: Set<Int> = []
    for table in ordered {
        if table.itemIndices.contains(where: { claimed.contains($0) }) { continue }
        claimed.formUnion(table.itemIndices)
        selected.append(table)
    }

    return selected.enumerated().sorted { left, right in
        let a = left.element.rows.first ?? 0
        let b = right.element.rows.first ?? 0
        if a != b { return a > b }
        return left.offset < right.offset
    }.map(\.element)
}

/// Whether two tables lay claim to any of the same items.
func pdfTablesShareItems(_ left: PdfTable, _ right: PdfTable) -> Bool {
    let rightItems = Set(right.itemIndices)
    return left.itemIndices.contains { rightItems.contains($0) }
}

/// Whether a candidate straddles more than one already-accepted table, which
/// means it is a misreading spanning a boundary rather than a table.
func pdfOverlapsMultipleTables(_ candidate: PdfTable, _ tables: [PdfTable]) -> Bool {
    var count = 0
    for table in tables where pdfTablesShareItems(candidate, table) {
        count += 1
        if count > 1 { return true }
    }
    return false
}

/// Choose between the original line-grid reading and the alternative
/// strategies.
///
/// Note there is no preference for either: when both exist they are pooled
/// and scored together, so an alternative that explains the page better
/// displaces the grid reading outright.
func pdfSelectTableHypothesis(legacy: [PdfTable], alternatives: [PdfTable]) -> [PdfTable] {
    if alternatives.isEmpty { return legacy }
    if legacy.isEmpty { return pdfSelectNonOverlappingHypotheses(alternatives) }
    return pdfSelectNonOverlappingHypotheses(legacy + alternatives)
}
