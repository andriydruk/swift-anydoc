import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the struct-tree table orchestrator against
/// `detect_tables_from_struct_tree`.
@Suite struct PdfStructTablesProbeTests {
    private func format(_ value: Float) -> String { String(format: "%.3f", value) }

    @Test func structTableDetectionMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/structtable-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/structtable-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var built = 0
        for (index, block) in blocks.enumerated() where index < expected.count {
            var structTables: [PdfStructTable] = []
            var items: [PdfLayoutItem] = []

            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                let space = line.firstIndex(of: " ")
                let tag = space.map { String(line[line.startIndex..<$0]) } ?? String(line)
                let rest = space.map {
                    String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces)
                } ?? ""
                switch tag {
                case "T":
                    structTables.append(PdfStructTable(rows: []))
                case "R":
                    if !structTables.isEmpty {
                        structTables[structTables.count - 1].rows.append(
                            PdfStructTableRow(cells: []))
                    }
                case "D":
                    let f = rest.split(separator: " ", maxSplits: 1,
                        omittingEmptySubsequences: false)
                    let isHeader = f.first == "1"
                    var mcids: [(mcid: Int, page: UInt32)] = []
                    if f.count > 1 && f[1] != "-" {
                        for entry in f[1].split(separator: ",") {
                            let bits = entry.split(separator: ":")
                            if bits.count == 2, let mcid = Int(bits[0]),
                                let page = UInt32(bits[1])
                            {
                                mcids.append((mcid, page))
                            }
                        }
                    }
                    if !structTables.isEmpty,
                        !structTables[structTables.count - 1].rows.isEmpty
                    {
                        let last = structTables.count - 1
                        let lastRow = structTables[last].rows.count - 1
                        structTables[last].rows[lastRow].cells.append(
                            PdfStructTableCell(isHeader: isHeader, mcids: mcids))
                    }
                case "I":
                    let f = rest.split(separator: " ", maxSplits: 3,
                        omittingEmptySubsequences: false)
                    guard f.count >= 4, let x = Float(f[0]), let y = Float(f[1]),
                        let mcid = Int(f[2])
                    else { continue }
                    items.append(
                        PdfLayoutItem(
                            text: String(f[3]).replacingOccurrences(of: "~", with: " "),
                            x: x, y: y, width: 20, fontSize: 10, fontName: "F1",
                            mcid: mcid < 0 ? nil : mcid))
                default:
                    continue
                }
            }

            let tables = pdfDetectTablesFromStructTree(
                items: items, structTables: structTables, page: 1)
            built += tables.count
            var ours = "tables \(tables.count)\n"
            for table in tables {
                ours += "t \(table.columns.count) \(table.rows.count)\nk"
                for value in table.columns { ours += " " + format(value) }
                ours += "\ny"
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
        print("pdf struct-table probe: \(blocks.count) cases, \(built) tables built")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) struct-table divergences:\n\(report)")
    }
}
