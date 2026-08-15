import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the positioned-block cluster against
/// `chart_stream_position`, `positioned_block_precedes_line` and
/// `positioned_blocks_for_page`.
@Suite struct PdfPositionedProbeTests {
    @Test func positionedOrderingMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/positioned-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/positioned-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n").map(String.init)
        let expected = expectedText.split(separator: "\n").filter { !$0.isEmpty }.map(String.init)
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var verdicts: [String: Int] = [:]
        for (index, line) in cases.enumerated() where index < expected.count {
            guard let ours = answer(for: line) else { continue }
            verdicts[String(ours.prefix(2)), default: 0] += 1
            if ours != expected[index] {
                mismatches.append("\(line)\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        let shape = verdicts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
        print("pdf positioned probe: \(cases.count) cases compared — \(shape)")
        let report = mismatches.prefix(5).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) positioned divergences:\n\(report)")
    }

    /// `split:cx0:cy0:cx1:cy1`, or `-` for a page with no chart stream.
    private func parseOrder(_ spec: String) -> PdfChartProseOrder? {
        if spec == "-" { return nil }
        let f = spec.split(separator: ":")
        guard f.count >= 5 else { return nil }
        return PdfChartProseOrder(
            splitX: Float(f[0]) ?? 0,
            chartRegion: (Float(f[1]) ?? 0, Float(f[2]) ?? 0, Float(f[3]) ?? 0, Float(f[4]) ?? 0))
    }

    private func answer(for line: String) -> String? {
        let space = line.firstIndex(of: " ")
        let tag = space.map { String(line[line.startIndex..<$0]) } ?? line
        let rest = space.map { String(line[line.index(after: $0)...]) } ?? ""
        let fields = rest.split(separator: " ").filter { !$0.isEmpty }.map(String.init)

        switch tag {
        case "Z":
            guard fields.count >= 4, let order = parseOrder(fields[3]) else { return nil }
            let position = pdfChartStreamPosition(
                y: Float(fields[0]) ?? 0, x: Float(fields[1]) ?? 0,
                claimedByChart: fields[2] == "1", order: order)
            return "pz \(position.zone) \(position.column)"
        case "P":
            guard fields.count >= 5 else { return nil }
            let block = PdfPositionedMarkdown(
                y: Float(fields[0]) ?? 0, x: Float(fields[1]) ?? 0, markdown: "md",
                chartOrder: parseOrder(fields[2]))
            let lineY = Float(fields[4]) ?? 0
            let items = fields[5...].compactMap { Float($0) }.map {
                PdfLayoutItem(text: "t", x: $0, y: lineY, width: 10, fontSize: 10, fontName: "F1")
            }
            let textLine = PdfTextLine(items: items, y: lineY)
            return "pp \(pdfPositionedBlockPrecedesLine(block, textLine) ? 1 : 0)"
        case "S":
            guard let semi = fields.firstIndex(of: ";") else { return nil }
            var tables: [PdfPositionedMarkdown] = []
            var images: [PdfPositionedMarkdown] = []
            for spec in fields[(semi + 1)...] {
                let f = spec.split(separator: ":")
                guard f.count >= 3 else { continue }
                let block = PdfPositionedMarkdown(
                    y: Float(f[1]) ?? 0, x: Float(f[2]) ?? 0, markdown: "md",
                    chartOrder: parseOrder(f[3...].joined(separator: ":")))
                if f[0] == "T" { tables.append(block) } else { images.append(block) }
            }
            let blocks = pdfPositionedBlocksForPage(tables: tables, images: images)
            return "ps"
                + blocks.map { " \($0.kind == .table ? "T" : "I")\($0.index)" }.joined()
        default:
            return nil
        }
    }
}
