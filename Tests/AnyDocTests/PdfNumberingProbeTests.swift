import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the section-numbering parser against
/// `markdown/heading.rs`.
@Suite struct PdfNumberingProbeTests {
    @Test func numberingMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/numbering-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/numbering-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let expected = expectedText.split(separator: "\n").filter { !$0.isEmpty }.map(String.init)
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var verdicts: [String: Int] = [:]
        for (index, line) in cases.enumerated() where index < expected.count {
            guard let ours = answer(for: line) else { continue }
            verdicts[String(ours.prefix(1)), default: 0] += 1
            if ours != expected[index] {
                mismatches.append("\(line)\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        let shape = verdicts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
        print("pdf numbering probe: \(cases.count) cases compared — \(shape)")
        let report = mismatches.prefix(6).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) numbering divergences:\n\(report)")
    }

    private func answer(for line: String) -> String? {
        let split = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let tag = split.first.map(String.init) else { return nil }
        let text = (split.count > 1 ? String(split[1]) : "")
            .replacingOccurrences(of: "~", with: " ")

        switch tag {
        case "R":
            return pdfRomanValue(text).map { "r \($0)" } ?? "r -"
        case "N":
            guard let numbering = pdfParseNumbering(text) else { return "n -" }
            var out = "n \(numbering.kind == .decimal ? "d" : "m") \(numbering.depth)"
            for part in numbering.parts { out += " \(part)" }
            return out
        case "A":
            return "a \(pdfHasAdditionalDecimalNumbering(text) ? 1 : 0)"
        case "H":
            let sides = text.split(separator: "|", omittingEmptySubsequences: false)
            func parse(_ side: Substring?) -> [UInt32] {
                (side ?? "").split(separator: ",").compactMap { UInt32($0.rustTrim()) }
            }
            let left = parse(sides.first)
            let right = parse(sides.count > 1 ? sides[1] : nil)
            return "h \(pdfNumberingFormsHierarchy(left, right) ? 1 : 0)"
        default:
            return nil
        }
    }
}
