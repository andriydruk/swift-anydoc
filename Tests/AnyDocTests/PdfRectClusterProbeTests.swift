import Foundation
import Testing

@testable import AnyDoc

/// Differential check of rectangle clustering against the foundation of
/// `tables/detect_rects.rs`.
@Suite struct PdfRectClusterProbeTests {
    @Test func rectClusteringMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard let caseText = try? String(contentsOfFile: path + "/rect-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/rect-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, block) in blocks.enumerated() where index < expected.count {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            guard let header = lines.first else { continue }
            let h = header.split(separator: " ").compactMap { Float($0) }
            guard h.count >= 4 else { continue }
            let (tolerance, minimumSize) = (h[0], Int(h[1]))
            let (gap, minimumGroup) = (h[2], Int(h[3]))

            let rects = lines.dropFirst().compactMap {
                line -> (x: Float, y: Float, width: Float, height: Float)? in
                let v = line.split(separator: " ").compactMap { Float($0) }
                guard v.count >= 4 else { return nil }
                return (v[0], v[1], v[2], v[3])
            }

            var ours = ""
            for (i, group) in pdfClusterRects(
                rects, tolerance: tolerance, minimumSize: minimumSize
            ).enumerated() {
                ours += "group \(i) [" + group.map(String.init).joined(separator: ", ") + "]\n"
            }
            if rects.count >= 2 {
                let overlaps = pdfRectsOverlap(rects[0], rects[1], tolerance: tolerance)
                ours += "overlap \(overlaps ? 1 : 0)\n"
            }
            if let split = pdfSplitWideCluster(
                rects, minimumGap: gap, minimumGroupSize: minimumGroup
            ) {
                ours += "split \(split.left.count) \(split.right.count)\n"
            } else {
                ours += "split none\n"
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
        print("pdf rect cluster probe: \(blocks.count) cases compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) cluster divergences:\n\(report)")
    }
}
