import Foundation
import Testing

@testable import AnyDoc

/// Differential checks of the two row-shaping stages of the cell-rect stripe
/// strategy against the reference: the row-edge derivation at the head of
/// `detect_row_stripe_table_from_cell_rects`, and
/// `collapse_multiline_description_rows`.
@Suite struct PdfCellRectRowsProbeTests {
    private func format(_ value: Float) -> String { String(format: "%.3f", value) }

    @Test func rowEdgeDerivationMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/gridbuild-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/cellrows-rust.txt", encoding: .utf8)
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

            var ours = "rows"
            if let edges = pdfCellRectRowEdges(items: items, groupRects: rects) {
                for edge in edges { ours += " " + format(edge) }
            } else {
                ours += " none"
            }
            ours += "\n"

            if ours != expected[index] {
                mismatches.append("case \(index)\n    ours: \(ours)    rust: \(expected[index])")
            }
        }
        print("pdf cell-rect row probe: \(blocks.count) cases compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) row-edge divergences:\n\(report)")
    }

    @Test func descriptionRowCollapsingMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/collapse-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/collapse-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, block) in blocks.enumerated() where index < expected.count {
            var rowEdges: [Float] = []
            var columnEdges: [Float] = []
            var cells: [[String]] = []
            for line in block.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
                if line.hasPrefix("E ") {
                    rowEdges = line.dropFirst(2).split(separator: " ").compactMap { Float($0) }
                } else if line.hasPrefix("X ") {
                    columnEdges = line.dropFirst(2).split(separator: " ").compactMap { Float($0) }
                } else if line.hasPrefix("R\t") {
                    cells.append(
                        line.dropFirst(2)
                            .split(separator: "\t", omittingEmptySubsequences: false)
                            .map { $0.replacingOccurrences(of: "~", with: " ") })
                } else if line == "R" {
                    cells.append([])
                }
            }

            let result = pdfCollapseMultilineDescriptionRows(
                cells: cells, rowEdges: rowEdges, columnEdges: columnEdges)
            var ours = "wrapped \(result.wrappedRows)\ne"
            for edge in result.rowEdges { ours += " " + format(edge) }
            ours += "\n"
            // The reference writes the tab *before* each cell, so a row with
            // no cells at all is a bare "r".
            for row in result.cells {
                ours += "r"
                for cell in row { ours += "\t" + cell }
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
        print("pdf collapse probe: \(blocks.count) cases compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) collapse divergences:\n\(report)")
    }
}
