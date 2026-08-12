import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the line-table orchestrator against
/// `detect_tables_from_lines` and `detect_vector_grid_tables_from_lines`,
/// plus the stroke classification they share.
@Suite struct PdfLineTablesProbeTests {
    private func format(_ value: Float) -> String { String(format: "%.3f", value) }

    private func emit(_ tag: String, _ table: PdfTable) -> String {
        var out = "\(tag) \(table.columns.count) \(table.rows.count)\nc"
        for value in table.columns { out += " " + format(value) }
        out += "\nw"
        for value in table.rows { out += " " + format(value) }
        out += "\n"
        for row in table.cells {
            out += "x"
            for cell in row { out += "\t" + cell }
            out += "\n"
        }
        out += "i"
        for index in table.itemIndices { out += " \(index)" }
        out += "\n"
        return out
    }

    @Test func lineTableDetectionMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/linetable-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/linetable-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var accepts = 0
        for (index, block) in blocks.enumerated() where index < expected.count {
            var lines: [PdfLineSegment] = []
            var items: [PdfLayoutItem] = []
            var inItems = false
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    inItems = true
                    continue
                }
                let p = line.split(separator: " ", omittingEmptySubsequences: false)
                if !inItems {
                    if p.count >= 5, p[0] == "L", let a = Float(p[1]), let b = Float(p[2]),
                        let c = Float(p[3]), let d = Float(p[4])
                    {
                        lines.append(PdfLineSegment(x1: a, y1: b, x2: c, y2: d, strokeWidth: 1))
                    }
                } else if p.count >= 5, let x = Float(p[0]), let y = Float(p[1]),
                    let w = Float(p[2]), let s = Float(p[3])
                {
                    items.append(
                        PdfLayoutItem(
                            text: p[4...].joined(separator: " "), x: x, y: y, width: w,
                            fontSize: s, fontName: "F1"))
                }
            }

            let classified = pdfClassifyRuleLines(lines)
            var ours = "class \(classified.horizontals.count) \(classified.verticals.count)\n"
            let full = pdfDetectTablesFromLines(items: items, lines: lines)
            accepts += full.count
            ours += "full \(full.count)\n"
            for table in full { ours += emit("f", table) }
            let vector = pdfDetectVectorGridTablesFromLines(items: items, lines: lines)
            ours += "vector \(vector.count)\n"
            for table in vector { ours += emit("v", table) }

            if ours != expected[index] {
                let a = ours.split(separator: "\n", omittingEmptySubsequences: false)
                let b = expected[index].split(separator: "\n", omittingEmptySubsequences: false)
                var diff: [String] = []
                for line in 0..<max(a.count, b.count) {
                    let x = line < a.count ? String(a[line]) : "<none>"
                    let y = line < b.count ? String(b[line]) : "<none>"
                    if x != y { diff.append("    ours: \(x)\n    rust: \(y)") }
                }
                mismatches.append("case \(index)\n" + diff.prefix(3).joined(separator: "\n"))
            }
        }
        print("pdf line-table probe: \(blocks.count) cases compared, \(accepts) tables")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) line-table divergences:\n\(report)")
    }
}
