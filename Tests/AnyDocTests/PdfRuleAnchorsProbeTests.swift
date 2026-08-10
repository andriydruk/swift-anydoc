import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the anchor primitives against
/// `collect_anchored_rows`, `logical_row_anchors`, `nearest_anchor_column`
/// and `matched_anchor_column_count`. Shares the rule case file.
@Suite struct PdfRuleAnchorsProbeTests {
    private func format(_ value: Float) -> String { String(format: "%.3f", value) }

    @Test func anchoredRowsMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(contentsOfFile: path + "/rules-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/anchors-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var multiAnchorRows = 0
        for (index, block) in blocks.enumerated() where index < expected.count {
            var rules: [PdfHorizontalRule] = []
            var items: [PdfLayoutItem] = []
            var inItems = false
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    inItems = true
                    continue
                }
                let p = line.split(separator: " ", omittingEmptySubsequences: false)
                if !inItems {
                    if p.count >= 3, let y = Float(p[0]), let a = Float(p[1]), let b = Float(p[2]) {
                        rules.append(PdfHorizontalRule(y: y, xMin: a, xMax: b))
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

            let rows = pdfCollectAnchoredRows(items: items, rules: rules)
            var ours = "rows \(rows.count)\n"
            for row in rows {
                ours += "r \(format(row.y))"
                for entry in row.items { ours += " \(entry.index)" }
                ours += "\n"
                let anchors = pdfLogicalRowAnchors(row.items)
                if anchors.count >= 2 { multiAnchorRows += 1 }
                ours += "a"
                for anchor in anchors { ours += " " + format(anchor) }
                ours += "\nm \(pdfMatchedAnchorColumnCount(row.items, anchors: anchors))\n"
                ours += "k"
                for entry in row.items {
                    if let column = pdfNearestAnchorColumn(entry.item, anchors: anchors) {
                        ours += " \(column)"
                    } else {
                        ours += " -"
                    }
                }
                ours += "\n"
            }

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
        print("pdf anchor probe: \(blocks.count) cases compared, \(multiAnchorRows) multi-anchor rows")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) anchor divergences:\n\(report)")
    }
}
