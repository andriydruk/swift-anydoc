import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the heading-tier and heading-level pair against
/// `compute_heading_tiers`, `detect_header_level` and `line_is_mostly_bold`.
@Suite struct PdfHeadingProbeTests {
    @Test func headingDetectionMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(contentsOfFile: path + "/heading-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/heading-rust.txt", encoding: .utf8)
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
        print("pdf heading probe: \(cases.count) cases compared — \(shape)")
        let report = mismatches.prefix(5).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) heading divergences:\n\(report)")
    }

    private func answer(for line: String) -> String? {
        let parts = line.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
        guard let tag = parts.first else { return nil }
        switch tag {
        case "L":
            let bars = parts.enumerated().filter { $0.element == "|" }.map(\.offset)
            guard bars.count >= 2, parts.count > 2 else { return nil }
            let tiers = parts[(bars[0] + 1)..<bars[1]].compactMap { Float($0) }
            let bold = bars[1] + 1 < parts.count && parts[bars[1] + 1] == "1"
            let level = pdfHeadingLevel(
                fontSize: Float(parts[1]) ?? 12, bodySize: Float(parts[2]) ?? 10, tiers: tiers,
                isBold: bold)
            return level.map { "hl \($0)" } ?? "hl -"
        case "T":
            guard let semi = parts.firstIndex(of: ";"), parts.count > 1 else { return nil }
            let lines: [PdfTextLine] = parts[(semi + 1)...].compactMap { field in
                let f = field.split(separator: ",", omittingEmptySubsequences: false)
                guard f.count >= 3, let size = Float(f[0]) else { return nil }
                var item = PdfLayoutItem(
                    text: f[2].replacingOccurrences(of: "~", with: " "), x: 0, y: 0, width: 10,
                    fontSize: size, fontName: "F1")
                item.isBold = f[1] == "1"
                return PdfTextLine(items: [item], y: 0)
            }
            let tiers = pdfHeadingTiers(lines, bodySize: Float(parts[1]) ?? 10)
            var out = "ht \(tiers.count)"
            for tier in tiers { out += " \(twoPlaces(tier))" }
            return out
        case "B":
            guard let semi = parts.firstIndex(of: ";") else { return nil }
            let items: [PdfLayoutItem] = parts[(semi + 1)...].compactMap { field in
                let f = field.split(separator: ",", omittingEmptySubsequences: false)
                guard f.count >= 2 else { return nil }
                var item = PdfLayoutItem(
                    text: f[1].replacingOccurrences(of: "~", with: " "), x: 0, y: 0, width: 10,
                    fontSize: 12, fontName: "F1")
                item.isBold = f[0] == "1"
                return item
            }
            return "mb \(pdfLineIsMostlyBold(PdfTextLine(items: items, y: 0)) ? 1 : 0)"
        default:
            return nil
        }
    }

    private func twoPlaces(_ value: Float) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        let scaled = (Double(value) * 100).rounded(.toNearestOrAwayFromZero)
        let whole = Int(scaled / 100)
        let fraction = abs(Int(scaled) % 100)
        let sign = (scaled < 0 && whole == 0) ? "-" : ""
        return "\(sign)\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }
}
