import Foundation
import Testing

@testable import AnyDoc

/// Differential check of grid assignment against `assign_items_to_grid`.
@Suite struct PdfGridAssignProbeTests {
    @Test func gridAssignmentMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(contentsOfFile: path + "/assign-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/assign-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, block) in blocks.enumerated() where index < expected.count {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 2 else { continue }
            let columns = lines[0].split(separator: " ").compactMap { Float($0) }
            let rows = lines[1].split(separator: " ").compactMap { Float($0) }
            let items = lines.dropFirst(2).compactMap { line -> PdfLayoutItem? in
                let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
                guard f.count >= 5, let x = Float(f[0]), let y = Float(f[1]),
                    let w = Float(f[2]), let s = Float(f[3])
                else { return nil }
                return PdfLayoutItem(
                    text: String(f[4]), x: x, y: y, width: w, fontSize: s, fontName: "F1")
            }

            var ours = ""
            if columns.count >= 2, rows.count >= 2 {
                let (cells, indices) = pdfAssignItemsToGrid(
                    items, columnEdges: columns, rowEdges: rows)
                for row in cells { ours += "cell\t" + row.joined(separator: "\t") + "\n" }
                ours += "idx [" + indices.map(String.init).joined(separator: ", ") + "]\n"
            } else {
                ours += "skip\n"
            }
            for text in ["a ( b )", "a (b)", "x [ 1 ] y", "{ z }", "no brackets", "( )"] {
                ours += "delim \(text)|\(pdfRemoveInnerDelimiterSpaces(text))\n"
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
        print("pdf grid assign probe: \(blocks.count) cases compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) assignment divergences:\n\(report)")
    }
}
