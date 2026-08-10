import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the stacked-box and row-stripe strategies against
/// `detect_stacked_box_table` and `detect_row_stripe_table`. Shares the
/// grid-build case file.
@Suite struct PdfRowStripeProbeTests {
    private func format(_ value: Float) -> String { String(format: "%.3f", value) }

    @Test func rowStripeDetectionMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/gridbuild-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/stack-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, block) in blocks.enumerated() where index < expected.count {
            var rects: [(x: Float, y: Float, width: Float, height: Float)] = []
            var items: [PdfLayoutItem] = []
            for line in block.split(separator: "\n").dropFirst() {
                let p = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: false)
                if p.count >= 5, p[0] == "R", let x = Float(p[1]), let y = Float(p[2]),
                    let w = Float(p[3]), let h = Float(p[4])
                {
                    rects.append((x, y, w, h))
                } else if p.count >= 6, p[0] == "I", let x = Float(p[1]), let y = Float(p[2]),
                    let w = Float(p[3]), let s = Float(p[4])
                {
                    items.append(
                        PdfLayoutItem(
                            text: String(p[5]), x: x, y: y, width: w, fontSize: s,
                            fontName: "F1"))
                }
            }

            var ours = "cols"
            for column in pdfClusterXPositions(items, minimumThreshold: 15) {
                ours += " " + format(column)
            }
            ours += "\n"
            // The reference's probe emits cols, then stack, then stripe.
            if let stacked = pdfDetectStackedBoxTable(items: items, groupRects: rects) {
                ours += "stack \(stacked.rows.count)\n"
                for row in stacked.cells { ours += "k\t" + row.joined(separator: "\t") + "\n" }
            } else {
                ours += "stack none\n"
            }
            if let table = pdfDetectRowStripeTable(items: items, groupRects: rects) {
                ours += "stripe \(table.columns.count) \(table.rows.count)\n"
                for row in table.cells { ours += "s\t" + row.joined(separator: "\t") + "\n" }
            } else {
                ours += "stripe none\n"
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
        print("pdf stripe/stack probe: \(blocks.count) cases compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) stripe divergences:\n\(report)")
    }
}
