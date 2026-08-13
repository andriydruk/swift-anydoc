/// Recovery of a table header the structure tree never claimed, ported from
/// `recover_unclaimed_header_row` in pdf-inspector's
/// `tables/detect_struct.rs`.
///
/// Some generators tag a table's body but leave its header outside the tree
/// entirely — as loose text above the first row. The rows that *are* tagged
/// then come out ragged, and that raggedness is the signal that something is
/// missing. This looks just above the table for text that lines up with the
/// columns already established, and prepends it as a header row.
///
/// It only runs on ragged tables for that reason: on a clean one, text above
/// the table is a caption or a paragraph, and stealing it would be worse than
/// leaving the header absent.

/// How far above the table to look at all.
private let pdfMaxHeaderDistance: Float = 90
/// How close the nearest candidate line must be to count as attached.
private let pdfMaxGapToTable: Float = 35
/// How far apart two header lines may be and still be one header.
private let pdfMaxInterHeaderGap: Float = 25
private let pdfMaxHeaderRows = 3
/// Items within this distance share a line.
private let pdfHeaderYTolerance: Float = 5

/// Prepend a recovered header row to `table`, or leave it untouched.
func pdfRecoverUnclaimedHeaderRow(
    _ table: inout PdfTable, items: [PdfLayoutItem], hasRaggedRows: Bool
) {
    guard hasRaggedRows, !table.rows.isEmpty, table.columns.count >= 3 else { return }

    let topRowY = table.rows[0]
    // Asymmetric on purpose: a header label may overhang the last column to
    // the right far more than the first one does to the left.
    let xMin = (table.columns.first ?? 0) - 25
    let xMax = (table.columns.last ?? 0) + 120
    let claimed = Set(table.itemIndices)

    // Group the unclaimed text above the table into lines. Each line keeps
    // the y of the *first* item that opened it, so a drifting baseline does
    // not walk the line down the page.
    var candidateRows: [(y: Float, items: [(index: Int, item: PdfLayoutItem)])] = []
    for (index, item) in items.enumerated() {
        if claimed.contains(index) || item.text.rustTrim().isEmpty || item.y <= topRowY
            || item.y - topRowY > pdfMaxHeaderDistance || item.x < xMin || item.x > xMax
        {
            continue
        }
        if let row = candidateRows.firstIndex(where: { abs(item.y - $0.y) < pdfHeaderYTolerance })
        {
            candidateRows[row].items.append((index, item))
        } else {
            candidateRows.append((item.y, [(index, item)]))
        }
    }
    if candidateRows.isEmpty { return }

    for index in candidateRows.indices {
        candidateRows[index].items.sort { $0.item.x < $1.item.x }
    }
    // Ascending y, so the line closest to the table comes first.
    candidateRows.sort { $0.y < $1.y }

    // A line further than this from the table is floating text, not a header.
    if candidateRows[0].y - topRowY > pdfMaxGapToTable { return }

    var selectedRows = [candidateRows[0]]
    var previousY = candidateRows[0].y
    for row in candidateRows.dropFirst() {
        if selectedRows.count >= pdfMaxHeaderRows { break }
        if row.y - previousY > pdfMaxInterHeaderGap { break }
        previousY = row.y
        selectedRows.append(row)
    }

    var assignedRows: [(y: Float, cells: [String], indices: [Int])] = []
    var closestRowPopulated = 0
    var combinedColumns = Set<Int>()

    for (rowIndex, row) in selectedRows.enumerated() {
        // More items than columns means this is not a header line, and the
        // whole recovery is abandoned rather than that line skipped.
        if row.items.count > table.columns.count { return }

        let assignments = pdfAlignPositionsToColumns(
            cellXs: row.items.map(\.item.x), columns: table.columns)
        // The alignment can return fewer assignments than cells when it runs
        // out of columns; a partial header is not worth having.
        if assignments.count != row.items.count { return }

        var rowCells = [String](repeating: "", count: table.columns.count)
        var rowIndices: [Int] = []
        var populatedColumns = Set<Int>()

        for (entry, column) in zip(row.items, assignments) {
            let text = entry.item.text.rustTrim()
            if text.isEmpty { continue }
            if !rowCells[column].isEmpty { rowCells[column] += " " }
            rowCells[column] += text
            rowIndices.append(entry.index)
            populatedColumns.insert(column)
        }

        if rowIndex == 0 { closestRowPopulated = populatedColumns.count }
        combinedColumns.formUnion(populatedColumns)
        assignedRows.append((row.y, rowCells, rowIndices))
    }

    // A wide table is allowed one unlabelled column — a row-header stub
    // usually — but a narrow one must be fully labelled, since there is less
    // evidence to go on.
    let requiredColumns = table.columns.count <= 4 ? table.columns.count : table.columns.count - 1
    if closestRowPopulated < 2 || combinedColumns.count < requiredColumns { return }

    // Assembled bottom-up — `assignedRows` runs from the line nearest the
    // table upwards, so reversing it puts the topmost line first and a
    // two-line header reads in the right order.
    var headerCells = [String](repeating: "", count: table.columns.count)
    var headerIndices: [Int] = []
    for row in assignedRows.reversed() {
        for (column, text) in row.cells.enumerated() where !text.isEmpty {
            if !headerCells[column].isEmpty { headerCells[column] += " " }
            headerCells[column] += text
        }
        headerIndices.append(contentsOf: row.indices)
    }

    table.rows.insert(assignedRows.map(\.y).max() ?? topRowY, at: 0)
    table.cells.insert(headerCells, at: 0)
    table.itemIndices.append(contentsOf: headerIndices)
    table.itemIndices.sort()
    table.itemIndices = pdfDeduplicatedSorted(table.itemIndices)
}
