// Ported from src/model/table.rs tests.
import Testing
@testable import AnyDoc

private func textCell(_ t: String) -> Cell {
    Cell.fromInlines([.plain(t)])
}

private func spanningText(_ t: String, _ cols: UInt32, _ rows: UInt32) -> Cell {
    Cell.spanning([.paragraph([.plain(t)])], colSpan: cols, rowSpan: rows)
}

private func widths(_ table: Table) -> [Int] {
    table.grid.map(\.count)
}

/// Every position a stored span claims must hold a covered marker pointing
/// back at that origin.
private func assertSpansBacked(_ t: Table) {
    for (r, row) in t.grid.enumerated() {
        for (c, slot) in row.enumerated() {
            guard case .origin(let cell) = slot else { continue }
            for dr in 0..<Int(cell.rowSpan) {
                for dc in 0..<Int(cell.colSpan) where (dr, dc) != (0, 0) {
                    var backed = false
                    if r + dr < t.grid.count, c + dc < t.grid[r + dr].count,
                        case .covered(let or, let oc) = t.grid[r + dr][c + dc]
                    {
                        backed = or == r && oc == c
                    }
                    #expect(backed, "span of origin (\(r),\(c)) not backed at (\(r + dr),\(c + dc))")
                }
            }
        }
    }
}

@Suite struct GridBuilderTests {
    @Test func colSpanCoversPositions() throws {
        var b = GridBuilder()
        b.nextRow()
        try b.place(Cell.spanning([], colSpan: 2, rowSpan: 1))
        try b.place(textCell("end"))
        let t = b.finish(.data)
        #expect(widths(t) == [3])
        guard case .covered(0, 0) = t.grid[0][1] else {
            Issue.record("expected covered slot at (0,1)")
            return
        }
    }

    @Test func rowSpanSkipsNextRowPosition() throws {
        var b = GridBuilder()
        b.nextRow()
        try b.place(Cell.spanning([], colSpan: 1, rowSpan: 2))
        try b.place(textCell("b1"))
        b.nextRow()
        try b.place(textCell("b2"))
        let t = b.finish(.data)
        #expect(widths(t) == [2, 2])
        guard case .covered(0, 0) = t.grid[1][0] else {
            Issue.record("expected covered slot at (1,0)")
            return
        }
        guard case .origin(let c) = t.grid[1][1], !c.isEmpty else {
            Issue.record("expected non-empty origin at (1,1)")
            return
        }
    }

    @Test func explicitCoveredConsumesExactlyOne() throws {
        var b = GridBuilder()
        b.nextRow()
        try b.place(Cell.spanning([], colSpan: 2, rowSpan: 1))
        let consumed1 = b.covered()
        #expect(consumed1)
        try b.place(textCell("end"))
        let t = b.finish(.data)
        #expect(widths(t) == [3])
    }

    @Test func strayCoveredBecomesEmptyCell() throws {
        var b = GridBuilder()
        b.nextRow()
        let consumed1 = b.covered()
        #expect(!consumed1)
        try b.place(textCell("x"))
        let t = b.finish(.data)
        #expect(widths(t) == [2])
    }

    @Test func overlappingSpansClampTheLateOrigin() throws {
        var b = GridBuilder()
        b.nextRow()
        try b.place(spanningText("tall", 1, 3))
        try b.place(textCell("a"))
        b.nextRow()
        let consumed1 = b.covered()
        #expect(consumed1)
        try b.place(spanningText("wide", 2, 2))
        b.nextRow()
        let consumed2 = b.covered()
        #expect(consumed2)
        try b.place(textCell("tail"))
        let t = b.finish(.data)
        assertSpansBacked(t)
    }

    @Test func conflictingSpanRectanglesStayConsistent() throws {
        var b = GridBuilder()
        b.nextRow()
        try b.place(spanningText("block", 2, 2))
        b.nextRow()
        try b.place(spanningText("late", 2, 1))
        let t = b.finish(.data)
        guard case .covered = t.grid[1][0], case .covered = t.grid[1][1] else {
            Issue.record("expected covered slots at (1,0) and (1,1)")
            return
        }
        guard case .origin(let c) = t.grid[1][2], c.colSpan == 2 else {
            Issue.record("expected origin with colSpan 2 at (1,2)")
            return
        }
        assertSpansBacked(t)
    }

    @Test func trimmedRowsClampSurvivingSpans() throws {
        var b = GridBuilder()
        b.nextRow()
        try b.place(Cell.spanning([.paragraph([.plain("x")])], colSpan: 1, rowSpan: 3))
        b.nextRow()
        b.nextRow()
        let t = b.finish(.data)
        #expect(t.grid.count == 1)
        guard case .origin(let c) = t.grid[0][0], c.rowSpan == 1 else {
            Issue.record("expected origin with rowSpan clamped to 1")
            return
        }
        assertSpansBacked(t)
    }

    @Test func hugeSpanHitsTheExpansionBudgetBeforeExpanding() {
        var b = GridBuilder()
        b.nextRow()
        #expect(throws: ConvertError.self) {
            try b.place(Cell.spanning([], colSpan: .max, rowSpan: .max))
        }
    }

    @Test func accumulatedSpansHitTheExpansionBudget() throws {
        var b = GridBuilder()
        b.expansion = Limits.maxExpansion - 10
        b.nextRow()
        try b.place(Cell.spanning([], colSpan: 3, rowSpan: 3)) // 8 more: still within
        #expect(throws: ConvertError.self) {
            try b.place(Cell.spanning([], colSpan: 2, rowSpan: 2)) // 3 more: over
        }
    }

    @Test func coveredTailBehindShortRowGapMaterializes() throws {
        var b = GridBuilder()
        b.nextRow()
        for _ in 0..<5 {
            try b.place(textCell("h"))
        }
        try b.place(spanningText("tall", 1, 2))
        b.nextRow()
        try b.place(textCell("only"))
        let t = b.finish(.data)
        #expect(t.grid[1].count == 6)
        guard case .covered(0, 5) = t.grid[1][5] else {
            Issue.record("expected covered slot at (1,5)")
            return
        }
        guard case .origin(let c) = t.grid[0][5], c.rowSpan == 2 else {
            Issue.record("expected origin with rowSpan 2 at (0,5)")
            return
        }
        assertSpansBacked(t)
    }

    @Test func trailingEmptyRowsTrimmed() throws {
        var b = GridBuilder()
        b.nextRow()
        try b.place(textCell("x"))
        b.nextRow()
        try b.place(Cell())
        let t = b.finish(.data)
        #expect(widths(t) == [1])
    }
}
