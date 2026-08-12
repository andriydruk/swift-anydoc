import Foundation
import Testing

@testable import AnyDoc

/// Differential check of letter-spacing repair against
/// `fix_letterspaced_items`, `compute_canva_join_threshold` and
/// `collect_gap_ratios`.
@Suite struct PdfLetterSpacingProbeTests {
    private func format(_ value: Float) -> String { String(format: "%.6f", value) }

    @Test func letterSpacingRepairMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/letterspacing-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/letterspacing-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var raised = 0
        for (index, block) in blocks.enumerated() where index < expected.count {
            var items: [PdfLayoutItem] = []
            for line in block.split(separator: "\n") {
                let p = line.split(separator: " ", omittingEmptySubsequences: false)
                guard p.count >= 5, let x = Float(p[0]), let y = Float(p[1]),
                    let w = Float(p[2]), let s = Float(p[3])
                else { continue }
                items.append(
                    PdfLayoutItem(
                        text: p[4...].joined(separator: " ").replacingOccurrences(
                            of: "~", with: " "),
                        x: x, y: y, width: w, fontSize: s, fontName: "F1"))
            }

            let ratios = pdfCollectGapRatios(items)
            var ours = "r \(ratios.count)"
            for value in ratios { ours += " " + format(value) }
            ours += "\nc " + format(pdfCanvaJoinThreshold(items)) + "\n"
            let threshold = pdfFixLetterspacedItems(&items)
            if threshold != 0.10 { raised += 1 }
            ours += "f " + format(threshold) + "\n"
            for item in items {
                ours += "i " + item.text.replacingOccurrences(of: " ", with: "~") + "\n"
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
        print("pdf letter-spacing probe: \(blocks.count) cases, \(raised) raised thresholds")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) letter-spacing divergences:\n\(report)")
    }
}
