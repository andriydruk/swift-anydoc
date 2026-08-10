import Foundation
import Testing

@testable import AnyDoc

/// Differential check of grid building against `try_build_grid`.
@Suite struct PdfRectGridProbeTests {
    @Test func gridBuildingMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/gridbuild-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/gridbuild-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, block) in blocks.enumerated() where index < expected.count {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            guard let header = lines.first else { continue }
            let fields = header.split(separator: " ", omittingEmptySubsequences: false)
            let strict = fields.first == "1"
            let skipSpec =
                fields.count > 1
                ? fields[1].split(separator: ",", omittingEmptySubsequences: false).map { $0 == "1" }
                : []

            var rects: [(x: Float, y: Float, width: Float, height: Float)] = []
            var items: [PdfLayoutItem] = []
            for line in lines.dropFirst() {
                let p = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: false)
                if p.count >= 5, p[0] == "R",
                    let x = Float(p[1]), let y = Float(p[2]),
                    let w = Float(p[3]), let h = Float(p[4])
                {
                    rects.append((x, y, w, h))
                } else if p.count >= 6, p[0] == "I",
                    let x = Float(p[1]), let y = Float(p[2]),
                    let w = Float(p[3]), let s = Float(p[4])
                {
                    items.append(
                        PdfLayoutItem(
                            text: String(p[5]), x: x, y: y, width: w, fontSize: s,
                            fontName: "F1"))
                }
            }
            var skips = [Bool](repeating: false, count: rects.count)
            for (i, value) in skipSpec.enumerated() where i < skips.count { skips[i] = value }

            var ours = ""
            switch pdfTryBuildGrid(
                items: items, groupRects: rects, skipRects: skips, strict: strict)
            {
            case .failed: ours = "failed\n"
            case .fewNonEmptyRows: ours = "fewrows\n"
            case .ok(let table):
                let kind = table.kind == .data ? "Data" : "Toc"
                ours = "ok \(table.columns.count) \(table.rows.count) \(kind)\n"
                for row in table.cells { ours += "c\t" + row.joined(separator: "\t") + "\n" }
                ours +=
                    "idx [" + table.itemIndices.map(String.init).joined(separator: ", ") + "]\n"
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
        print("pdf rect grid probe: \(blocks.count) cases compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) grid-build divergences:\n\(report)")
    }
}
