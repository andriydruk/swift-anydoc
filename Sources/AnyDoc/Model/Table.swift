/// Canonical table grid. **Invariant:** every logical grid position appears
/// exactly once — content and spans exist only on the origin slot, and each
/// position covered by a span holds a `CellSlot.covered` marker pointing back
/// at its origin. Frontends construct grids through one internal builder that
/// enforces this, so a `Table` handed to a consumer always holds.
public struct Table: Sendable {
    /// Rows of slots. Rows may differ in length when the source is ragged.
    public var grid: [[CellSlot]]
    /// Number of leading rows that are header rows (0 = no header).
    public var headerRows: Int
    /// Whether the source used this table for data or for layout.
    public var kind: TableKind

    public init(grid: [[CellSlot]] = [], headerRows: Int = 0, kind: TableKind = .data) {
        self.grid = grid
        self.headerRows = headerRows
        self.kind = kind
    }

    /// Build a plain span-less table from rows of cells (spreadsheets, CSV).
    public static func fromRows(_ rows: [[Cell]], headerRows: Int, kind: TableKind) -> Table {
        var b = GridBuilder()
        for row in rows {
            b.nextRow()
            for var cell in row {
                cell.colSpan = 1
                cell.rowSpan = 1
                // Span-less placement never charges the expansion budget.
                try! b.place(cell)
            }
        }
        var table = b.finish(kind)
        table.headerRows = headerRows
        return table
    }

    /// True when the table is a single origin cell (any covered padding aside).
    public var isSingleCell: Bool {
        grid.count == 1 && grid[0].count == 1 && grid[0][0].isOrigin
    }
}

/// What a table is for.
public enum TableKind: Sendable, Equatable {
    /// A real data table.
    case data
    /// Layout scaffolding (text boxes, positioning tables); renderers may
    /// unwrap trivial layout tables.
    case layout
}

/// One position in a `Table.grid`: either a cell or the shadow of one.
public enum CellSlot: Sendable {
    /// The cell itself, holding the content and the span extents.
    case origin(Cell)
    /// A position swallowed by a span, pointing back at the origin that
    /// covers it.
    case covered(originRow: Int, originCol: Int)

    var isOrigin: Bool {
        if case .origin = self { return true }
        return false
    }
}

/// A table cell and the extent it spans.
///
/// The default (`Cell()`) mirrors Rust's `Cell::default()`: **zero** spans.
/// `GridBuilder.place` normalizes spans to at least 1; the zero-span default
/// only reaches a grid through stray-covered and gap-fill cells, exactly as
/// in the reference implementation.
public struct Cell: Sendable {
    /// The cell's content.
    public var blocks: [Block]
    /// Columns covered.
    public var colSpan: UInt32
    /// Rows covered.
    public var rowSpan: UInt32

    public init(blocks: [Block] = [], colSpan: UInt32 = 0, rowSpan: UInt32 = 0) {
        self.blocks = blocks
        self.colSpan = colSpan
        self.rowSpan = rowSpan
    }

    /// A cell spanning one position.
    public static func cell(_ blocks: [Block]) -> Cell {
        Cell(blocks: blocks, colSpan: 1, rowSpan: 1)
    }

    /// A one-paragraph cell spanning one position.
    public static func fromInlines(_ inlines: [Inline]) -> Cell {
        .cell([.paragraph(inlines)])
    }

    /// A cell covering `colSpan` by `rowSpan` positions; either span given as
    /// 0 is raised to 1.
    public static func spanning(_ blocks: [Block], colSpan: UInt32, rowSpan: UInt32) -> Cell {
        Cell(blocks: blocks, colSpan: max(colSpan, 1), rowSpan: max(rowSpan, 1))
    }

    /// True when the cell holds nothing that would render: only paragraphs
    /// count toward emptiness, so a cell with a table or list in it is not
    /// empty even if that content is blank.
    public var isEmpty: Bool {
        blocks.allSatisfy { block in
            if case .paragraph(let inlines) = block { return inlinesAreEmpty(inlines) }
            return false
        }
    }
}

struct GridPos: Hashable {
    var row: Int
    var col: Int
}

/// Sole constructor for `Table` grids. Enforces the exactly-once invariant:
/// spans register their covered positions, later placements skip over them,
/// and overlapping spans are clamped rather than double-counted.
struct GridBuilder {
    private(set) var grid: [[CellSlot]] = []
    /// Positions in future rows covered by an earlier row-spanning origin.
    private var pending: [GridPos: GridPos] = [:]
    /// Covered positions claimed by span expansion, charged against
    /// `Limits.maxExpansion` *before* any per-position work so a tiny
    /// document carrying a huge span cannot force unbounded insertions.
    var expansion: UInt64 = 0

    init() {}

    mutating func nextRow() {
        grid.append([])
    }

    private mutating func rowIndex() -> Int {
        if grid.isEmpty { grid.append([]) }
        return grid.count - 1
    }

    /// Materialize pending covered positions at the cursor, so the next
    /// placement lands on the first genuinely free column.
    private mutating func skipPending(_ row: Int) {
        while let origin = pending.removeValue(forKey: GridPos(row: row, col: grid[row].count)) {
            grid[row].append(.covered(originRow: origin.row, originCol: origin.col))
        }
    }

    /// Place a cell at the next free position of the current row. The cell's
    /// spans register covered positions as *pending*: an explicitly written
    /// covered cell (ODF) consumes one via `covered()`, while producers that
    /// omit them (HTML, OOXML) have the positions materialized automatically
    /// when the next cell is placed.
    ///
    /// The complete span area is charged against the expansion budget before
    /// any expansion happens; `resourceLimit` when the budget is exceeded.
    mutating func place(_ cell: Cell) throws {
        let area = UInt64(max(cell.colSpan, 1)) * UInt64(max(cell.rowSpan, 1))
        expansion = expansion &+ (area - 1) // cannot overflow: area <= 2^64 / 2
        if expansion > Limits.maxExpansion {
            throw ConvertError.resourceLimit(
                limit: "max_expansion",
                detail: "table span expansion exceeds the content budget")
        }
        let row = rowIndex()
        skipPending(row)
        let col = grid[row].count
        var colSpan = Int(max(cell.colSpan, 1))
        var rowSpan = Int(max(cell.rowSpan, 1))
        // Clamp the spans to positions this origin can actually own — an
        // overlap with an earlier span would break the exactly-once invariant.
        for dc in 1..<max(colSpan, 1) where pending[GridPos(row: row, col: col + dc)] != nil {
            colSpan = dc
            break
        }
        rows: for dr in 1..<max(rowSpan, 1) {
            for dc in 0..<colSpan where pending[GridPos(row: row + dr, col: col + dc)] != nil {
                rowSpan = dr
                break rows
            }
        }
        var placed = cell
        placed.colSpan = UInt32(colSpan)
        placed.rowSpan = UInt32(rowSpan)
        grid[row].append(.origin(placed))
        for dr in 0..<rowSpan {
            for dc in 0..<colSpan where (dr, dc) != (0, 0) {
                pending[GridPos(row: row + dr, col: col + dc)] = GridPos(row: row, col: col)
            }
        }
    }

    /// Consume one explicitly-written covered position (ODF
    /// `covered-table-cell`). Returns `false` when no span accounts for the
    /// position — the stray marker then becomes an empty cell.
    @discardableResult
    mutating func covered() -> Bool {
        let row = rowIndex()
        let col = grid[row].count
        if let origin = pending.removeValue(forKey: GridPos(row: row, col: col)) {
            grid[row].append(.covered(originRow: origin.row, originCol: origin.col))
            return true
        }
        grid[row].append(.origin(Cell()))
        return false
    }

    mutating func finish(_ kind: TableKind) -> Table {
        // Materialize every pending covered position in surviving rows,
        // including tails behind a gap (a short row under a span at a later
        // column): intervening slots fill with empty cells so each covered
        // marker lands on its true column.
        var byRow: [Int: [Int]] = [:]
        for pos in pending.keys where pos.row < grid.count {
            byRow[pos.row, default: []].append(pos.col)
        }
        for (row, cols) in byRow.sorted(by: { $0.key < $1.key }) {
            for col in cols.sorted() {
                while grid[row].count < col {
                    grid[row].append(.origin(Cell()))
                }
                let origin = pending.removeValue(forKey: GridPos(row: row, col: col))!
                // Placement always consumes pending slots at the cursor, so a
                // still-pending position can only sit at or past the row end.
                grid[row].append(.covered(originRow: origin.row, originCol: origin.col))
            }
        }
        // Drop trailing all-empty rows.
        while let last = grid.last, last.allSatisfy({ slot in
            switch slot {
            case .origin(let c): c.isEmpty
            case .covered: true
            }
        }) {
            grid.removeLast()
        }
        // Clamp stored spans to the surviving grid so every claimed position
        // is backed by a covered marker (exactly-once invariant).
        let rows = grid.count
        for r in 0..<rows {
            let width = grid[r].count
            for c in 0..<width {
                if case .origin(var cell) = grid[r][c] {
                    cell.rowSpan = min(cell.rowSpan, UInt32(rows - r))
                    cell.colSpan = min(cell.colSpan, UInt32(width - c))
                    grid[r][c] = .origin(cell)
                }
            }
        }
        return Table(grid: grid, headerRows: 0, kind: kind)
    }
}
