import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the chart-region trio against `markdown/mod.rs`.
@Suite struct PdfChartRegionsProbeTests {
    @Test func chartRegionsMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(contentsOfFile: path + "/chart-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/chart-rust.txt", encoding: .utf8)
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
        print("pdf chart-region probe: \(cases.count) cases compared — \(shape)")
        let report = mismatches.prefix(5).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) chart-region divergences:\n\(report)")
    }

    private func answer(for line: String) -> String? {
        let split = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let tag = split.first.map(String.init), split.count > 1 else { return nil }
        let fields = split[1].split(separator: " ").filter { !$0.isEmpty }.map(String.init)
        guard let semi = fields.firstIndex(of: ";") else { return nil }

        let regions: [PdfImageRegion] = fields[..<semi].compactMap {
            let f = $0.split(separator: ",")
            guard f.count >= 4, let x0 = Float(f[0]), let y0 = Float(f[1]),
                let x1 = Float(f[2]), let y1 = Float(f[3])
            else { return nil }
            return PdfImageRegion(x0: x0, y0: y0, x1: x1, y1: y1)
        }
        let items: [PdfLayoutItem] = fields[(semi + 1)...].compactMap { field in
            let f = field.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 6, let x = Float(f[0]), let y = Float(f[1]),
                let width = Float(f[2]), let height = Float(f[3]), let size = Float(f[4])
            else { return nil }
            var item = PdfLayoutItem(
                text: f[5].replacingOccurrences(of: "~", with: " "), x: x, y: y, width: width,
                fontSize: size, fontName: "F1")
            item.height = height
            return item
        }

        switch tag {
        case "L":
            let region = regions.first ?? PdfImageRegion(x0: 0, y0: 0, x1: 0, y1: 0)
            return "cl "
                + items.map { pdfIsChartAdjacentLabel($0, region) ? "1" : "0" }.joined()
        case "I":
            return "ci "
                + items.map { pdfItemIsInChartRegion($0, regions) ? "1" : "0" }.joined()
        case "O":
            return "co \(pdfItemsOutsideChartRegions(items, regions).count)"
        default:
            return nil
        }
    }
}
