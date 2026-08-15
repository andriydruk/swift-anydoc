import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the small chart-prose predicates against
/// `markdown/mod.rs`.
@Suite struct PdfChartProseProbeTests {
    @Test func chartProsePredicatesMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/charttext-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/charttext-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
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
        print("pdf chart-prose probe: \(cases.count) cases compared — \(shape)")
        let report = mismatches.prefix(5).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) chart-prose divergences:\n\(report)")
    }

    private func answer(for line: String) -> String? {
        let split = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let tag = split.first.map(String.init) else { return nil }
        let rest = split.count > 1 ? String(split[1]) : ""

        switch tag {
        case "P":
            let halves = rest.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let previous = (halves.first.map(String.init) ?? "")
                .replacingOccurrences(of: "~", with: " ")
            let current = (halves.count > 1 ? String(halves[1]) : "")
                .replacingOccurrences(of: "~", with: " ")
            return "cp \(pdfIsCrossRowProseContinuation(previous, current) ? 1 : 0)"
        case "H":
            let text = rest.replacingOccurrences(of: "~", with: " ")
            return "chd \(pdfLooksLikeNumberedSectionHeading(text) ? 1 : 0)"
        case "R":
            let fields = rest.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
            let corners = (fields.first ?? "").split(separator: ",").compactMap { Float($0) }
            guard corners.count >= 4 else { return "cx 0" }
            let region = PdfImageRegion(
                x0: corners[0], y0: corners[1], x1: corners[2], y1: corners[3])
            let splitX = fields.count > 1 ? (Float(fields[1]) ?? 0) : 0
            return "cx \(pdfChartSpansProseSplit(region, splitX: splitX) ? 1 : 0)"
        case "M":
            let fields = rest.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
            return "cmr \(pdfMergedRetrySkipsBodyFont(detectedColumns: fields.first == "1", hasChartRegions: fields.count > 1 && fields[1] == "1") ? 1 : 0)"
        default:
            return nil
        }
    }
}
