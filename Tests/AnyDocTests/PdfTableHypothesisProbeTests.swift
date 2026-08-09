import Foundation
import Testing

@testable import AnyDoc

/// Differential check of table-hypothesis scoring and selection against
/// `tables/detect_lines.rs`.
@Suite struct PdfTableHypothesisProbeTests {
    /// Parse one candidate line: `L|A rowY a,b;c,d 1,2,3`.
    private func parse(_ line: Substring) -> (tag: String, table: PdfTable)? {
        // Rust's `splitn` keeps empty fields; Swift's `split` drops them
        // unless told otherwise, and the cells field is empty whenever a
        // one-cell grid holds the empty string.
        let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard f.count >= 4, let y = Float(f[1]) else { return nil }
        let cells = f[2].components(separatedBy: ";").map { row in
            row.components(separatedBy: ",").map {
                $0.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            }
        }
        let items = f[3].split(separator: ",").compactMap { Int($0) }
        let rows = [Float](repeating: y, count: max(cells.count, 1))
        let columns = [Float](repeating: 0, count: cells.first?.count ?? 0)
        return (
            String(f[0]),
            PdfTable(columns: columns, rows: rows, cells: cells, itemIndices: items)
        )
    }

    @Test func hypothesisSelectionMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard let caseText = try? String(contentsOfFile: path + "/hyp-cases.txt", encoding: .utf8),
            let expectedText = try? String(contentsOfFile: path + "/hyp-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, block) in blocks.enumerated() where index < expected.count {
            var legacy: [PdfTable] = []
            var alternatives: [PdfTable] = []
            for line in block.split(separator: "\n") {
                guard let parsed = parse(line) else { continue }
                if parsed.tag == "L" { legacy.append(parsed.table) } else {
                    alternatives.append(parsed.table)
                }
            }

            var ours = ""
            for table in legacy + alternatives {
                ours += "score \(pdfTableEvidenceScore(table))\n"
            }
            func list(_ items: [Int]) -> String {
                "[" + items.map(String.init).joined(separator: ", ") + "]"
            }
            for table in pdfSelectNonOverlappingHypotheses(legacy + alternatives) {
                ours += "sel \(list(table.itemIndices))\n"
            }
            for table in pdfSelectTableHypothesis(legacy: legacy, alternatives: alternatives) {
                ours += "hyp \(list(table.itemIndices))\n"
            }
            if let a = legacy.first, let b = alternatives.first {
                ours += "share \(pdfTablesShareItems(a, b) ? 1 : 0)\n"
                ours += "multi \(pdfOverlapsMultipleTables(b, legacy) ? 1 : 0)\n"
            }

            if ours != expected[index] {
                let x = ours.split(separator: "\n", omittingEmptySubsequences: false)
                let y = expected[index].split(separator: "\n", omittingEmptySubsequences: false)
                var diff: [String] = []
                for line in 0..<max(x.count, y.count) {
                    let a = line < x.count ? String(x[line]) : "<none>"
                    let b = line < y.count ? String(y[line]) : "<none>"
                    if a != b { diff.append("    ours: \(a)\n    rust: \(b)") }
                }
                mismatches.append("case \(index)\n" + diff.prefix(3).joined(separator: "\n"))
            }
        }
        print("pdf table hypothesis probe: \(blocks.count) cases compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) hypothesis divergences:\n\(report)")
    }
}
