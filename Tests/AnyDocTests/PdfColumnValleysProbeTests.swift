import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the column-detection leaf tests against
/// `find_relative_valleys`, `is_list_marker_column`,
/// `spans_multiple_columns` and `is_page_number`.
@Suite struct PdfColumnValleysProbeTests {
    @Test func columnLeafTestsMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(contentsOfFile: path + "/valley-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/valley-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n").map(String.init)
        let expected = expectedText.split(separator: "\n").filter { !$0.isEmpty }.map(String.init)
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var verdicts: [String: Int] = [:]
        for (index, line) in cases.enumerated() where index < expected.count {
            guard let ours = answer(for: line) else { continue }
            verdicts[String(ours.prefix(3)), default: 0] += 1
            if ours != expected[index] {
                mismatches.append("\(line)\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        let shape = verdicts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
        print("pdf column-leaf probe: \(cases.count) cases compared — \(shape)")
        let report = mismatches.prefix(5).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) column-leaf divergences:\n\(report)")
    }

    private func answer(for line: String) -> String? {
        let parts = line.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
        guard let tag = parts.first else { return nil }
        switch tag {
        case "V":
            guard let bar = parts.firstIndex(of: "|"), parts.count > 3 else { return nil }
            let binWidth = Float(parts[1]) ?? 1
            let pageWidth = Float(parts[2]) ?? 612
            let margin = Float(parts[3]) ?? 0
            let histogram = parts[(bar + 1)...].map { UInt32($0) ?? 0 }
            let valleys = pdfFindRelativeValleys(
                histogram: histogram, binCount: histogram.count, binWidth: binWidth,
                pageWidth: pageWidth, marginThreshold: margin)
            var out = "v \(valleys.count)"
            for valley in valleys { out += " \(valley.lower):\(valley.upper)" }
            return out
        case "L":
            let texts = (parts.count > 1 && parts[1] == "-") ? [] : Array(parts.dropFirst())
            let items = texts.map { text in
                PdfLayoutItem(
                    text: text.replacingOccurrences(of: "~", with: " "), x: 0, y: 0, width: 0,
                    fontSize: 12, fontName: "F1")
            }
            return "l \(pdfIsListMarkerColumn(items) ? 1 : 0)"
        case "S":
            guard let bar = parts.firstIndex(of: "|"), parts.count > 4 else { return nil }
            let item = PdfLayoutItem(
                text: parts[4].replacingOccurrences(of: "~", with: " "),
                x: Float(parts[1]) ?? 0, y: 700, width: Float(parts[2]) ?? 0,
                fontSize: Float(parts[3]) ?? 12, fontName: "F1")
            let numbers = parts[(bar + 1)...].map { Float($0) ?? 0 }
            var columns: [PdfColumnRegion] = []
            var index = 0
            while index + 1 < numbers.count {
                columns.append(PdfColumnRegion(xMin: numbers[index], xMax: numbers[index + 1]))
                index += 2
            }
            return "s \(pdfSpansMultipleColumns(item, columns) ? 1 : 0)"
        case "P":
            guard parts.count > 2 else { return nil }
            let item = PdfLayoutItem(
                text: parts[2].replacingOccurrences(of: "~", with: " "), x: 0,
                y: Float(parts[1]) ?? 0, width: 0, fontSize: 12, fontName: "F1")
            return "p \(pdfIsPageNumber(item) ? 1 : 0)"
        default:
            return nil
        }
    }
}
