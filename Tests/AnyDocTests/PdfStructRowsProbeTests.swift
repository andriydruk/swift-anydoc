import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the row-alignment strategies against
/// `align_struct_rows` and `left_align_struct_rows`.
@Suite struct PdfStructRowsProbeTests {
    private func format(_ value: Float) -> String { String(format: "%.3f", value) }

    private func dump(_ tag: String, _ result: PdfAlignedRows) -> String {
        var out = "\(tag) \(result.cells.count)\n"
        for row in result.cells {
            out += "c"
            for cell in row { out += "\t" + cell }
            out += "\n"
        }
        out += "y"
        for value in result.rowPositions { out += " " + format(value) }
        out += "\nx"
        for value in result.itemIndices { out += " \(value)" }
        out += "\n"
        return out
    }

    @Test func rowAlignmentMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/structrow-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/structrow-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, block) in blocks.enumerated() where index < expected.count {
            var columns: [Float] = []
            var columnCount = 0
            var rows: [[PdfMatchedCell]] = []
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let space = line.firstIndex(of: " ") else {
                    if line == "R" { rows.append([]) }
                    continue
                }
                let tag = String(line[line.startIndex..<space])
                let rest = String(line[line.index(after: space)...])
                    .trimmingCharacters(in: .whitespaces)
                switch tag {
                case "C":
                    columns = rest.split(separator: ",").compactMap { Float($0) }
                case "N":
                    columnCount = Int(rest) ?? 0
                case "R":
                    var row: [PdfMatchedCell] = []
                    if !rest.isEmpty {
                        for spec in rest.split(separator: " ") {
                            let f = spec.split(separator: ":", omittingEmptySubsequences: false)
                            guard f.count >= 4 else { continue }
                            row.append(
                                PdfMatchedCell(
                                    text: f[0] == "-"
                                        ? ""
                                        : String(f[0]).replacingOccurrences(of: "~", with: " "),
                                    itemIndices: f[1] == "-"
                                        ? []
                                        : f[1].split(separator: ".").compactMap { Int($0) },
                                    x: f[2] == "-" ? nil : Float(f[2]),
                                    y: f[3] == "-" ? nil : Float(f[3])))
                        }
                    }
                    rows.append(row)
                default:
                    continue
                }
            }

            var ours = dump(
                "aligned", pdfAlignStructRows(rows, columnPositions: columns))
            ours += dump("left", pdfLeftAlignStructRows(rows, columnCount: columnCount))

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
        print("pdf struct-row probe: \(blocks.count) cases compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) struct-row divergences:\n\(report)")
    }
}
