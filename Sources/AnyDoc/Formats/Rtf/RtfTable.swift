/// RTF table assembly: cell properties captured at `\cellx` time, per-depth
/// row accumulation (nested tables live at `\itap` depth); the canonical
/// grid construction is the shared edge-based assembly (`Shared/Grid.swift`).

private struct RowBuild {
    var cells: [(blocks: [Block], prop: CellProp)] = []
    var header = false
}

private struct TableBuild {
    var rows: [RowBuild] = []
    /// Props declared by the current `\trowd ... \cellx` run.
    var rowProps: [CellProp] = []
    var propCursor = 0
    var pendingProp = CellProp()
    var row = RowBuild()
    var rowHeader = false
}

/// Table builders indexed by nesting depth - 1, plus the per-depth pending
/// cell content.
struct RtfTableState {
    private var tables: [TableBuild] = []
    private var cellBlocks: [[Block]] = [[]]
    private var cellRuns: [StyledRun] = [StyledRun()]

    /// Deepest depth with a builder allocated.
    var depth: Int { tables.count }

    private mutating func ensureTableDepth(_ depth: Int) {
        while tables.count < depth {
            tables.append(TableBuild())
        }
        ensureCellDepth(depth)
    }

    private mutating func ensureCellDepth(_ depth: Int) {
        while cellBlocks.count < depth {
            cellBlocks.append([])
        }
        while cellRuns.count < depth {
            cellRuns.append(StyledRun())
        }
    }

    private mutating func flushCellRun(_ depth: Int) {
        ensureCellDepth(depth)
        cellRuns[depth - 1].flush(&cellBlocks[depth - 1])
    }

    /// `\trowd`: reset the row's declared properties.
    mutating func beginRow(_ depth: Int) {
        ensureTableDepth(depth)
        tables[depth - 1].rowProps = []
        tables[depth - 1].propCursor = 0
        tables[depth - 1].pendingProp = CellProp()
        tables[depth - 1].rowHeader = false
    }

    /// `\trhdr`: the row repeats as a header.
    mutating func markHeaderRow(_ depth: Int) {
        ensureTableDepth(depth)
        tables[depth - 1].rowHeader = true
    }

    /// Apply a property to the slot the next `\cellx` will seal.
    mutating func withPendingProp(_ depth: Int, _ apply: (inout CellProp) -> Void) {
        ensureTableDepth(depth)
        apply(&tables[depth - 1].pendingProp)
    }

    /// `\cellxN`: seal the pending properties with the right boundary.
    mutating func declareCell(_ depth: Int, right: Int64) {
        ensureTableDepth(depth)
        var prop = tables[depth - 1].pendingProp
        tables[depth - 1].pendingProp = CellProp()
        prop.right = right
        tables[depth - 1].rowProps.append(prop)
    }

    /// A paragraph ended inside a cell at `depth`.
    mutating func pushCellParagraph(_ depth: Int, _ style: BlockStyle?, _ inlines: [Inline]) {
        ensureCellDepth(depth)
        if let style {
            cellRuns[depth - 1].push(style, inlines, &cellBlocks[depth - 1])
        } else {
            cellRuns[depth - 1].flush(&cellBlocks[depth - 1])
            if !inlinesAreEmpty(inlines) {
                cellBlocks[depth - 1].append(.paragraph(inlines))
            }
        }
    }

    /// Whether unfinished cell content is pending at `depth`.
    mutating func hasPendingCell(_ depth: Int) -> Bool {
        flushCellRun(depth)
        return !cellBlocks[depth - 1].isEmpty
    }

    /// Whether a row at `depth` is partially built (pending cell content or
    /// already-closed cells awaiting their `\row`).
    mutating func hasPartialRow(_ depth: Int) -> Bool {
        if hasPendingCell(depth) { return true }
        guard depth - 1 < tables.count else { return false }
        return !tables[depth - 1].row.cells.isEmpty
    }

    /// `\cell` / `\nestcell`: close the cell, folding in any completed
    /// deeper table.
    mutating func endCell(_ depth: Int, _ style: BlockStyle?, _ inlines: [Inline]) throws {
        pushCellParagraph(depth, style, inlines)
        flushCellRun(depth)
        // A deeper completed table belongs inside this cell.
        try flushIntoCell(depth + 1, into: depth)
        ensureCellDepth(depth)
        let blocks = cellBlocks[depth - 1]
        cellBlocks[depth - 1] = []
        ensureTableDepth(depth)
        let cursor = tables[depth - 1].propCursor
        let prop = cursor < tables[depth - 1].rowProps.count
            ? tables[depth - 1].rowProps[cursor] : CellProp()
        tables[depth - 1].propCursor += 1
        tables[depth - 1].row.cells.append((blocks: blocks, prop: prop))
    }

    /// `\row` / `\nestrow`: close the row (its last cell must already be
    /// closed by the caller).
    mutating func endRow(_ depth: Int) {
        ensureTableDepth(depth)
        var row = tables[depth - 1].row
        tables[depth - 1].row = RowBuild()
        row.header = tables[depth - 1].rowHeader
        tables[depth - 1].propCursor = 0
        if !row.cells.isEmpty {
            tables[depth - 1].rows.append(row)
        }
    }

    /// Take the finished table at `depth` as a block, if it has any rows.
    mutating func takeTable(_ depth: Int) throws -> Block? {
        guard depth - 1 < tables.count, !tables[depth - 1].rows.isEmpty else {
            return nil
        }
        let t = tables[depth - 1]
        tables[depth - 1] = TableBuild()
        return try buildEdgeTable(t.rows.map { GridRow(cells: $0.cells, header: $0.header) })
    }

    /// Build a finished table at `depth` into cell blocks one level up.
    private mutating func flushIntoCell(_ depth: Int, into: Int) throws {
        if let block = try takeTable(depth) {
            flushCellRun(into)
            ensureCellDepth(into)
            cellBlocks[into - 1].append(block)
        }
    }

    /// Collapse any dangling nested tables outward into their parent cells.
    mutating func collapseNested() throws {
        guard tables.count >= 2 else { return }
        for depth in stride(from: tables.count, through: 2, by: -1) {
            try flushIntoCell(depth, into: depth - 1)
        }
    }
}
