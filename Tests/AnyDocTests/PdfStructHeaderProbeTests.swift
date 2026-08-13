import Foundation
import Testing

@testable import AnyDoc

/// Differential check of unclaimed-header recovery against
/// `recover_unclaimed_header_row`.
@Suite struct PdfStructHeaderProbeTests {
    private func format(_ value: Float) -> String { String(format: "%.3f", value) }

    @Test func headerRecoveryMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/structheader-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/structheader-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var recovered = 0
        for (index, block) in blocks.enumerated() where index < expected.count {
            var ragged = false
            var columns: [Float] = []
            var rows: [Float] = []
            var claimed: [Int] = []
            var cells: [[String]] = []
            var items: [PdfLayoutItem] = []

            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                let space = line.firstIndex(of: " ")
                let tag = space.map { String(line[line.startIndex..<$0]) } ?? String(line)
                let rest = space.map {
                    String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces)
                } ?? ""
                switch tag {
                case "G": ragged = rest == "1"
                case "C": columns = rest.split(separator: ",").compactMap { Float($0) }
                case "Y": rows = rest.split(separator: ",").compactMap { Float($0) }
                case "X": claimed = rest.split(separator: ",").compactMap { Int($0) }
                case "E":
                    cells.append(
                        rest.isEmpty
                            ? []
                            : rest.split(separator: "\t", omittingEmptySubsequences: false)
                                .map { $0.replacingOccurrences(of: "~", with: " ") })
                case "I":
                    let f = rest.split(separator: " ", maxSplits: 2,
                        omittingEmptySubsequences: false)
                    guard f.count >= 3, let x = Float(f[0]), let y = Float(f[1]) else { continue }
                    items.append(
                        PdfLayoutItem(
                            text: String(f[2]).replacingOccurrences(of: "~", with: " "),
                            x: x, y: y, width: 20, fontSize: 10, fontName: "F1"))
                default: continue
                }
            }

            var table = PdfTable(
                columns: columns, rows: rows, cells: cells, itemIndices: claimed)
            let before = table.rows.count
            pdfRecoverUnclaimedHeaderRow(&table, items: items, hasRaggedRows: ragged)
            if table.rows.count > before { recovered += 1 }

            var ours = "h \(table.rows.count) \(table.cells.count)\ny"
            for value in table.rows { ours += " " + format(value) }
            ours += "\n"
            for row in table.cells {
                ours += "c"
                for cell in row { ours += "\t" + cell }
                ours += "\n"
            }
            ours += "x"
            for value in table.itemIndices { ours += " \(value)" }
            ours += "\n"

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
        print("pdf struct-header probe: \(blocks.count) cases, \(recovered) recovered")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) struct-header divergences:\n\(report)")
    }
}
