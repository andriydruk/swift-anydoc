import Foundation
import Testing

@testable import AnyDoc

/// Differential check of layout complexity and the band filters against
/// `compute_layout_complexity`, `filter_rects_to_band` and
/// `filter_lines_to_band`.
@Suite struct PdfComplexityProbeTests {
    @Test func layoutComplexityMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/complexity-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/complexity-rust.txt", encoding: .utf8)
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
                mismatches.append("\(line.prefix(70))\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        let shape = verdicts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
        print("pdf complexity probe: \(cases.count) cases compared — \(shape)")
        let report = mismatches.prefix(4).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) complexity divergences:\n\(report)")
    }

    private func answer(for line: String) -> String? {
        let space = line.firstIndex(of: " ")
        let tag = space.map { String(line[line.startIndex..<$0]) } ?? line
        let rest = space.map { String(line[line.index(after: $0)...]) } ?? ""
        let fields = rest.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
        guard let semi = fields.firstIndex(of: ";") else { return nil }
        let specs = Array(fields[(semi + 1)...])

        switch tag {
        case "R":
            let rects: [PdfRect] = specs.compactMap {
                let f = $0.split(separator: ",")
                guard f.count >= 4, let x = Float(f[0]), let y = Float(f[1]),
                    let width = Float(f[2]), let height = Float(f[3])
                else { return nil }
                return PdfRect(x: x, y: y, width: width, height: height)
            }
            let kept = pdfFilterRectsToBand(
                rects, xLow: Float(fields[0]) ?? 0, xHigh: Float(fields[1]) ?? 0)
            return "cr \(kept.count)" + kept.map { " \(Int($0.x.rounded(.toNearestOrEven)))" }
                .joined()
        case "S":
            let segments: [PdfLineSegment] = specs.compactMap {
                let f = $0.split(separator: ",")
                guard f.count >= 4, let x1 = Float(f[0]), let y1 = Float(f[1]),
                    let x2 = Float(f[2]), let y2 = Float(f[3])
                else { return nil }
                return PdfLineSegment(x1: x1, y1: y1, x2: x2, y2: y2, strokeWidth: 1)
            }
            let kept = pdfFilterLinesToBand(
                segments, xLow: Float(fields[0]) ?? 0, xHigh: Float(fields[1]) ?? 0)
            return "cs \(kept.count)" + kept.map { " \(Int($0.x1.rounded(.toNearestOrEven)))" }
                .joined()
        case "C":
            var itemsByPage: [Int: [PdfLayoutItem]] = [:]
            for spec in specs {
                let f = spec.split(separator: ",")
                guard f.count >= 5, let page = Int(f[0]), let x = Float(f[1]),
                    let y = Float(f[2]), let size = Float(f[3])
                else { continue }
                itemsByPage[page, default: []].append(
                    PdfLayoutItem(
                        text: f[4...].joined(separator: ",")
                            .replacingOccurrences(of: "~", with: " "),
                        x: x, y: y, width: 40, fontSize: size, fontName: "F1"))
            }
            let complexity = pdfLayoutComplexity(itemsByPage: itemsByPage)
            return "cc \(complexity.isComplex ? 1 : 0) "
                + "t=\(complexity.pagesWithTables.map(String.init).joined(separator: ",")) "
                + "c=\(complexity.pagesWithColumns.map(String.init).joined(separator: ","))"
        default:
            return nil
        }
    }
}
