import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the stacked-token and open-edge grid strategies
/// against `build_stacked_token_table` and `build_open_edge_grid_tables`.
@Suite struct PdfOpenEdgeGridProbeTests {
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

    @Test func openEdgeStrategiesMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/openedge-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/openedge-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var anchorAccepts = 0
        var bandAccepts = 0
        var stackedAccepts = 0
        var gridAccepts = 0
        for (index, block) in blocks.enumerated() where index < expected.count {
            var rules: [PdfHorizontalRule] = []
            var verticals: [PdfVerticalRule] = []
            var pathLines: [PdfLineSegment] = []
            var items: [PdfLayoutItem] = []
            var inItems = false
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    inItems = true
                    continue
                }
                let p = line.split(separator: " ", omittingEmptySubsequences: false)
                if !inItems {
                    if p[0] == "p", p.count >= 5, let a = Float(p[1]), let b = Float(p[2]),
                        let c = Float(p[3]), let d = Float(p[4])
                    {
                        pathLines.append(
                            PdfLineSegment(x1: a, y1: b, x2: c, y2: d, strokeWidth: 1))
                    } else if p[0] == "v", p.count >= 4, let x = Float(p[1]), let lo = Float(p[2]),
                        let hi = Float(p[3])
                    {
                        verticals.append((x: x, yMin: lo, yMax: hi))
                    } else if p.count >= 3, let y = Float(p[0]), let a = Float(p[1]),
                        let b = Float(p[2])
                    {
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

            var ours = ""
            if let anchor = pdfBuildTextAnchorTable(items: items, rules: rules) {
                anchorAccepts += 1
                ours += emit("anchor", anchor)
            } else {
                ours += "anchor none\n"
            }
            let anchored = pdfCollectAnchoredRows(items: items, rules: rules)
            if let stacked = pdfBuildStackedTokenTable(rows: anchored, rules: rules) {
                stackedAccepts += 1
                ours += emit("stacked", stacked)
            } else {
                ours += "stacked none\n"
            }
            let bands = pdfDetectTextAnchorRuleTables(
                items: items, horizontals: rules, verticals: verticals, pathLines: pathLines)
            bandAccepts += bands.count
            ours += "bands \(bands.count)\n"
            for band in bands {
                ours += "b \(format(band.xLeft)) \(format(band.xRight)) "
                ours += "\(format(band.yBottom)) \(format(band.yTop))\n"
                ours += emit("bt", band.table)
            }

            let grids = pdfBuildOpenEdgeGridTables(
                items: items, horizontals: rules, verticals: verticals)
            gridAccepts += grids.count
            ours += "grids \(grids.count)\n"
            for grid in grids { ours += emit("g", grid) }

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
        print(
            "pdf open-edge probe: \(blocks.count) cases, \(anchorAccepts) anchor, "
                + "\(stackedAccepts) stacked, \(bandAccepts) bands, \(gridAccepts) grids")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) open-edge divergences:\n\(report)")
    }
}
