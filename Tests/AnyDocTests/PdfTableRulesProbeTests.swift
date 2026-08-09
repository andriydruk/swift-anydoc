import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the horizontal-rule primitives against
/// `tables/detect_lines.rs`.
///
/// Cases cover each branch these functions turn on: segments joined across a
/// small gap but not a large one, two tables sharing endpoints split by a
/// caption and by an empty band, the same band filled with text so it must
/// *not* split, a uniform ruled grid and one just outside the 2% bar, and
/// endpoints that do and do not recur down the table.
///
///   python3 scripts/gen-grid-probe.py /tmp/grid --oracle /tmp/oracle
///   ANYDOC_GRID_PROBE=/tmp/grid swift test --filter PdfTableRulesProbe
@Suite struct PdfTableRulesProbeTests {
    private func format(_ value: Float) -> String { String(format: "%.3f", value) }

    @Test func rulePrimitivesMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(contentsOfFile: path + "/rules-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/rules-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, block) in blocks.enumerated() where index < expected.count {
            // Rules, a blank line, then items.
            let halves = block.components(separatedBy: "\n\n")
            let rules = halves[0].split(separator: "\n").compactMap { line -> PdfHorizontalRule? in
                let f = line.split(separator: " ")
                guard f.count >= 3, let y = Float(f[0]), let a = Float(f[1]), let b = Float(f[2])
                else { return nil }
                return PdfHorizontalRule(y: y, xMin: a, xMax: b)
            }
            let items = (halves.count > 1 ? halves[1] : "").split(separator: "\n")
                .compactMap { line -> PdfLayoutItem? in
                    let f = line.split(separator: " ", maxSplits: 4)
                    guard f.count >= 5, let x = Float(f[0]), let y = Float(f[1]),
                        let w = Float(f[2]), let s = Float(f[3])
                    else { return nil }
                    return PdfLayoutItem(
                        text: String(f[4]), x: x, y: y, width: w, fontSize: s, fontName: "F1")
                }

            var ours = ""
            let merged = pdfMergeHorizontalSegments(rules)
            for rule in merged {
                ours +=
                    "merged \(format(rule.y)) \(format(rule.xMin)) \(format(rule.xMax))\n"
            }
            for (i, group) in pdfGroupRulesBySpan(merged).enumerated() {
                ours += "group \(i) \(group.count)\n"
            }
            for (i, run) in pdfSplitIndependentRuleRuns(merged, items: items).enumerated() {
                ours += "run \(i) \(run.count)\n"
            }
            ours += "uniform \(pdfRulesAreUniformGrid(merged) ? 1 : 0)\n"
            if let columns = pdfDeriveColumnsFromHorizontalSegments(merged) {
                ours += "columns" + columns.map { " " + format($0) }.joined() + "\n"
            } else {
                ours += "columns none\n"
            }
            for text in ["Table 3", "Table 12.", "table (4) x", "Tables 3", "Table x", "Table"] {
                ours += "caption \(pdfIsNumberedTableCaption(text) ? 1 : 0) \(text)\n"
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
        print("pdf table rules probe: \(blocks.count) cases compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) rule divergences:\n\(report)")
    }
}
