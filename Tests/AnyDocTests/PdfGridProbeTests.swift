import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the table-grid geometry against `tables/grid.rs`,
/// run inside the vendored pdf-inspector.
///
/// The threshold `find_column_boundaries` picks depends on the shape of the
/// gap distribution — three branches, chosen by item count and by how bimodal
/// the gaps are. A hand-written example reaches one of them by accident at
/// best, so the cases are generated to hit each, plus a random tail.
///
///   scripts/gen-graphics-oracle.sh /tmp/oracle
///   python3 scripts/gen-grid-probe.py /tmp/probe --oracle /tmp/oracle
///   ANYDOC_GRID_PROBE=/tmp/probe swift test --filter PdfGridProbe
@Suite struct PdfGridProbeTests {
    private func format(_ value: Float) -> String { String(format: "%.3f", value) }

    /// The reference prints an `Option<usize>` with `{:?}`.
    private func optional(_ value: Int?) -> String {
        value.map { "Some(\($0))" } ?? "None"
    }

    private func parse(_ block: Substring) -> [PdfLayoutItem] {
        block.split(separator: "\n").compactMap { line -> PdfLayoutItem? in
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count >= 5, let x = Float(fields[0]), let y = Float(fields[1]),
                let width = Float(fields[2]), let size = Float(fields[3])
            else { return nil }
            return PdfLayoutItem(
                text: String(fields[4]), x: x, y: y, width: width, fontSize: size,
                fontName: "F1")
        }
    }

    private func ourDump(_ items: [PdfLayoutItem]) -> String {
        var lines: [String] = []
        for (label, mode) in [
            ("SmallFont", PdfTableDetectionMode.smallFont),
            ("BodyFont", PdfTableDetectionMode.bodyFont),
        ] {
            let columns = pdfFindColumnBoundaries(items, mode: mode)
            lines.append("columns\(label)" + columns.map { " " + format($0) }.joined())
        }
        let columns = pdfFindColumnBoundaries(items, mode: .smallFont)
        let rows = pdfFindRowBoundaries(items)
        lines.append("rows" + rows.map { " " + format($0) }.joined())
        for item in items {
            lines.append(
                "cell \(optional(pdfFindColumnIndex(columns, item.x))) "
                    + "\(optional(pdfFindRowIndex(rows, item.y)))")
        }
        lines.append("join " + pdfJoinCellItems(items))
        return lines.joined(separator: "\n")
    }

    @Test func gridGeometryMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        let caseText = try String(contentsOfFile: path + "/grid-cases.txt", encoding: .utf8)
        let expectedText = try String(contentsOfFile: path + "/grid-rust.txt", encoding: .utf8)

        let blocks = caseText.components(separatedBy: "\n---\n")
        let expected = expectedText.components(separatedBy: "\n---\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, block) in blocks.enumerated() where index < expected.count {
            let items = parse(Substring(block))
            if items.isEmpty { continue }
            let ours = ourDump(items)
            let theirs = expected[index].trimmingCharacters(in: .newlines)
            if ours != theirs {
                let ourLines = ours.split(separator: "\n").map(String.init)
                let theirLines = theirs.split(separator: "\n").map(String.init)
                var diff: [String] = []
                for line in 0..<max(ourLines.count, theirLines.count) {
                    let a = line < ourLines.count ? ourLines[line] : "<none>"
                    let b = line < theirLines.count ? theirLines[line] : "<none>"
                    if a != b { diff.append("    ours: \(a)\n    rust: \(b)") }
                }
                mismatches.append(
                    "case \(index) (\(items.count) items)\n"
                        + diff.prefix(4).joined(separator: "\n"))
            }
        }
        print("pdf grid probe: \(blocks.count) cases compared")
        let report = mismatches.prefix(4).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) grid divergences:\n\(report)")
    }
}

/// Differential check of the table formatter against `tables/format.rs`.
///
/// Continuation merging is the interesting part: a row with an empty first
/// column is usually a wrapped cell, but it is also how a spanned first
/// column, a short sub-header and a hierarchical sub-entry look. The cases
/// include one of each, plus a random tail over the fragments those tests
/// key on.
@Suite struct PdfTableFormatProbeTests {
    @Test func formattingMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        let caseText = try String(contentsOfFile: path + "/format-cases.txt", encoding: .utf8)
        let expectedText = try String(contentsOfFile: path + "/format-rust.txt", encoding: .utf8)

        let blocks = caseText.components(separatedBy: "\n---\n")
        let expected = expectedText.components(separatedBy: "\n---\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, block) in blocks.enumerated() where index < expected.count {
            let cells = block.split(separator: "\n", omittingEmptySubsequences: true).map {
                $0.components(separatedBy: "\t")
            }
            if cells.isEmpty { continue }

            let (cleaned, footnotes) = pdfCleanTableCells(cells)
            var ours = ""
            for row in cleaned { ours += "clean\t" + row.joined(separator: "\t") + "\n" }
            for footnote in footnotes { ours += "footnote\t" + footnote + "\n" }
            var data = PdfTable()
            data.cells = cells
            data.kind = .data
            ours += "--data--\n" + pdfTableToMarkdown(data)
            ours += "--toc--\n" + pdfFormatTocAsList(cells, footnotes: [])

            if ours != expected[index] {
                let ourLines = ours.split(separator: "\n", omittingEmptySubsequences: false)
                let theirLines = expected[index].split(
                    separator: "\n", omittingEmptySubsequences: false)
                var diff: [String] = []
                for line in 0..<max(ourLines.count, theirLines.count) {
                    let a = line < ourLines.count ? String(ourLines[line]) : "<none>"
                    let b = line < theirLines.count ? String(theirLines[line]) : "<none>"
                    if a != b { diff.append("    ours: \(a)\n    rust: \(b)") }
                }
                mismatches.append("case \(index)\n" + diff.prefix(4).joined(separator: "\n"))
            }
        }
        print("pdf table format probe: \(blocks.count) cases compared")
        let report = mismatches.prefix(4).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) format divergences:\n\(report)")
    }
}
