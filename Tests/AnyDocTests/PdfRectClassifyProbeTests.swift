import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the rect-cluster classifiers against
/// `tables/detect_rects.rs`. Shares the grid-build case file.
@Suite struct PdfRectClassifyProbeTests {
    @Test func clusterClassifiersMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/gridbuild-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/classify-rust.txt", encoding: .utf8)
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

            let kept = pdfWithoutDominantPageBackgrounds(rects)
            let ours =
                "stripe \(pdfIsRowStripePattern(rects) ? 1 : 0)\n"
                + "chart \(pdfIsChartBarCluster(items: items, groupRects: rects) ? 1 : 0)\n"
                + "kept \(kept.count)\n"

            if ours != expected[index] {
                let a = ours.split(separator: "\n", omittingEmptySubsequences: false)
                let b = expected[index].split(separator: "\n", omittingEmptySubsequences: false)
                var diff: [String] = []
                for line in 0..<max(a.count, b.count) {
                    let x = line < a.count ? String(a[line]) : "<none>"
                    let y = line < b.count ? String(b[line]) : "<none>"
                    if x != y { diff.append("    ours: \(x)\n    rust: \(y)") }
                }
                mismatches.append("case \(index)\n" + diff.joined(separator: "\n"))
            }
        }
        print("pdf rect classify probe: \(blocks.count) cases compared")
        let report = mismatches.prefix(4).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) classifier divergences:\n\(report)")
    }
}
