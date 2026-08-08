/// Edge-based table assembly shared by RTF (`\cellx` boundaries) and binary
/// DOC (TAP `rgdxaCenter` boundaries): grid columns come from the clustered
/// union of every row's cell edges, horizontal merges collapse into column
/// spans, and vertical chains start at an explicit restart flag and are
/// continued by continuation cells whose boundaries match the chain's.
///
/// The formats that need this describe a row as a list of right-hand
/// boundaries rather than as a column count, so two rows only share a column
/// when their boundaries agree — which is why the columns have to be derived
/// before any cell can be placed.

/// Merge and boundary properties of one cell.
struct CellProp: Equatable {
    /// First cell of a horizontally merged set.
    var mergeFirst = false
    /// Horizontal continuation: folds into the preceding first cell.
    var mergeCont = false
    /// First cell of a vertically merged chain.
    var vmergeFirst = false
    /// Vertical continuation: covered by the chain's origin above.
    var vmergeCont = false
    /// The cell's right boundary in twips — vertical merge chains match on
    /// actual boundaries, not cell ordinals.
    var right: Int64 = 0
}

/// One logical row: its cells with their properties, and whether the row is
/// a header row.
struct GridRow {
    var cells: [(blocks: [Block], prop: CellProp)]
    var header: Bool
}

/// Producer boundary jitter under this threshold clusters into one edge.
private let edgeTolerance: Int64 = 10

/// Assemble logical rows into the canonical grid.
func buildEdgeTable(_ rows: [GridRow]) throws -> Block? {
    /// A placed cell and the global column range it owns.
    struct Origin {
        var blocks: [Block]
        /// Half-open global column range.
        var colL: Int
        var colR: Int
        var rowSpan: UInt32
        var vmergeFirst: Bool
        var covered: Bool
    }

    let headerRows = rows.prefix(while: { $0.header }).count

    // Normalize each row's right edges to be strictly increasing (cells past
    // the declared boundaries get synthetic edges), then cluster the union
    // into the global column-edge list.
    let rowsEdged: [[(blocks: [Block], prop: CellProp)]] = rows.map { row in
        var last = Int64.min
        return row.cells.map { cell in
            var prop = cell.prop
            if prop.right <= last {
                prop.right = last + 1
            }
            last = prop.right
            return (blocks: cell.blocks, prop: prop)
        }
    }
    var edges: [Int64] = rowsEdged.flatMap { $0.map(\.prop.right) }
    edges.sort()
    var clusters: [Int64] = []
    for edge in edges where clusters.last.map({ edge - $0 > edgeTolerance }) ?? true {
        clusters.append(edge)
    }
    /// The column index a right boundary falls in: the first cluster not
    /// left of it, within the jitter tolerance.
    func columnOf(_ x: Int64) -> Int {
        partitionPoint(clusters) { $0 < x - edgeTolerance }
    }

    var placed: [[Origin]] = []
    for row in rowsEdged {
        var out: [Origin] = []
        var col = 0
        var i = 0
        while i < row.count {
            var mergedBlocks = row[i].blocks
            var right = row[i].prop.right
            if row[i].prop.mergeFirst {
                // A horizontal merge swallows the continuation cells that
                // follow it, taking its width from the last one.
                while i + 1 < row.count, row[i + 1].prop.mergeCont {
                    i += 1
                    mergedBlocks.append(contentsOf: row[i].blocks)
                    right = row[i].prop.right
                }
            }
            let colR = max(columnOf(right) + 1, col + 1)
            out.append(
                Origin(
                    blocks: mergedBlocks, colL: col, colR: colR, rowSpan: 1,
                    vmergeFirst: row[i].prop.vmergeFirst, covered: row[i].prop.vmergeCont))
            col = colR
            i += 1
        }
        placed.append(out)
    }

    // Vertical chains keyed by the origin's exact column range.
    var active: [ColumnRange: GridIndex] = [:]
    for r in placed.indices {
        var nextActive: [ColumnRange: GridIndex] = [:]
        for i in placed[r].indices {
            let range = ColumnRange(left: placed[r][i].colL, right: placed[r][i].colR)
            if placed[r][i].covered {
                if let origin = active[range] {
                    placed[origin.row][origin.index].rowSpan += 1
                    nextActive[range] = origin
                    continue
                }
                // Continuation without a matching chain: keep it visible.
                placed[r][i].covered = false
            }
            if placed[r][i].vmergeFirst {
                nextActive[range] = GridIndex(row: r, index: i)
            }
        }
        active = nextActive
    }

    var builder = GridBuilder()
    for row in placed {
        builder.nextRow()
        for origin in row {
            let span = UInt32(origin.colR - origin.colL)
            if origin.covered {
                for _ in 0..<span {
                    builder.covered()
                }
            } else {
                try builder.place(
                    Cell.spanning(origin.blocks, colSpan: span, rowSpan: origin.rowSpan))
            }
        }
    }
    var table = builder.finish(.data)
    if table.grid.isEmpty {
        return nil
    }
    table.headerRows = resolveHeaderRows(table, declared: headerRows)
    return .table(table)
}

private struct ColumnRange: Hashable {
    var left: Int
    var right: Int
}

private struct GridIndex {
    var row: Int
    var index: Int
}

/// Rust `slice::partition_point`: the index of the first element for which
/// `predicate` is false, over a slice partitioned by it.
func partitionPoint<T>(_ values: [T], _ predicate: (T) -> Bool) -> Int {
    var low = 0
    var high = values.count
    while low < high {
        let mid = low + (high - low) / 2
        if predicate(values[mid]) {
            low = mid + 1
        } else {
            high = mid
        }
    }
    return low
}
