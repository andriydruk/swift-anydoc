import Foundation
import Testing

@testable import AnyDoc

/// Differential check of column inference and the DP alignment against
/// `infer_column_positions` and `align_positions_to_columns`.
@Suite struct PdfStructColumnsProbeTests {
    private func format(_ value: Float) -> String { String(format: "%.3f", value) }

    private func parseList(_ text: String) -> [Float?] {
        if text.isEmpty { return [] }
        return text.split(separator: ",", omittingEmptySubsequences: false).map {
            $0 == "-" ? nil : Float($0)
        }
    }

    @Test func columnInferenceMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/structcol-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/structcol-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var alignments = 0
        for (index, block) in blocks.enumerated() where index < expected.count {
            var rows: [[Float?]] = []
            var fallback: [Float] = []
            var columnCount = 0
            var ours = ""
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let space = line.firstIndex(of: " ") else { continue }
                let tag = String(line[line.startIndex..<space])
                let rest = String(line[line.index(after: space)...])
                    .trimmingCharacters(in: .whitespaces)
                switch tag {
                case "R": rows.append(parseList(rest))
                case "F": fallback = parseList(rest).compactMap { $0 }
                case "N": columnCount = Int(rest) ?? 0
                case "A":
                    let halves = rest.components(separatedBy: "|")
                    guard halves.count == 2 else { continue }
                    let cells = parseList(halves[0].trimmingCharacters(in: .whitespaces))
                        .compactMap { $0 }
                    let columns = parseList(halves[1].trimmingCharacters(in: .whitespaces))
                        .compactMap { $0 }
                    alignments += 1
                    ours += "a"
                    for value in pdfAlignPositionsToColumns(cellXs: cells, columns: columns) {
                        ours += " \(value)"
                    }
                    ours += "\n"
                default: continue
                }
            }
            ours += "i"
            for value in pdfInferColumnPositions(
                rowPositions: rows, fallback: fallback, columnCount: columnCount)
            {
                ours += " " + format(value)
            }
            ours += "\n"

            if ours != expected[index] {
                mismatches.append("case \(index)\n    ours: \(ours)    rust: \(expected[index])")
            }
        }
        print("pdf struct-column probe: \(blocks.count) cases, \(alignments) alignments")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) struct-column divergences:\n\(report)")
    }
}
