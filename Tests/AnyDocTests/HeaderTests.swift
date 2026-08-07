// Ported from src/shared/header.rs tests.
import Testing
@testable import AnyDoc

private func detect(_ rows: [[String]]) -> Int {
    let cells = rows.map { row in row.map { Cell.fromInlines([.plain($0)]) } }
    return resolveHeaderRows(Table.fromRows(cells, headerRows: 0, kind: .data), declared: 0)
}

@Suite struct HeaderTests {
    @Test func labelsOverTypedColumnsAreAHeader() {
        #expect(detect([["name", "qty"], ["a", "1"], ["b", "2"]]) == 1)
        #expect(detect([["when", "ok"], ["2026-03-15", "TRUE"], ["2026-03-16", "FALSE"]]) == 1)
    }

    @Test func aFirstDataRowIsNotAHeader() {
        // Numeric columns with a numeric first row: sanctions-list shape.
        #expect(detect([["36", "12", "aka"], ["173", "57", "aka"], ["306", "220", "aka"]]) == 0)
    }

    @Test func aLabelRepeatedBelowIsData() {
        #expect(detect([["x", "aka"], ["y", "aka"], ["z", "aka"]]) == 0)
    }

    @Test func allTextFallsBackToRowShape() {
        #expect(detect([["col1", "col2"], ["naïve", "café"], ["Αθήνα", "数据"]]) == 1)
        let long = String(repeating: "l", count: 65)
        #expect(detect([[long, "col2"], ["a", "b"], ["c", "d"]]) == 0)
    }

    @Test func structuralVetoes() {
        // Fewer fields than the body: a title line, not a header.
        #expect(detect([["Q1 report"], ["a", "1"], ["b", "2"]]) == 0)
        // An unlabelled column.
        #expect(detect([["name", ""], ["a", "1"], ["b", "2"]]) == 0)
        // Duplicate labels.
        #expect(detect([["name", "name"], ["a", "1"], ["b", "2"]]) == 0)
        // Nothing to compare against.
        #expect(detect([["name", "qty"]]) == 0)
    }

    @Test func aLeadingIndexColumnMayBeUnlabelled() {
        #expect(detect([["", "qty"], ["a", "1"], ["b", "2"]]) == 1)
    }

    @Test func aMixedColumnAbstainsRatherThanVotingAgainst() {
        #expect(detect([["kind", "value"], ["percent", "15.5%"], ["date", "2026-03-15"]]) == 1)
    }
}
