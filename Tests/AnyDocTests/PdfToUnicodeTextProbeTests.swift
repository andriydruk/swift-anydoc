import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the ToUnicode string helpers against
/// `parse_hex_u16`, `hex_to_unicode_string`,
/// `normalize_tounicode_destination`, `hex_to_unicode_scalar` and
/// `find_usecmap_name`.
@Suite struct PdfToUnicodeTextProbeTests {
    @Test func toUnicodeTextHelpersMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/tounicodetext-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/tounicodetext-rust.txt", encoding: .utf8)
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
        print("pdf tounicode-text probe: \(cases.count) cases compared — \(shape)")
        let report = mismatches.prefix(5).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) tounicode-text divergences:\n\(report)")
    }

    /// Scalars as dot-separated hex, which is how the oracle prints them.
    private func show(_ text: String) -> String {
        text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: ".")
    }

    private func answer(for line: String) -> String? {
        let space = line.firstIndex(of: " ")
        let tag = space.map { String(line[line.startIndex..<$0]) } ?? line
        let raw = space.map { String(line[line.index(after: $0)...]) } ?? ""
        // `@` stands for an empty argument, since a case line cannot end in
        // the separator.
        let argument =
            raw == "@"
            ? ""
            : raw.replacingOccurrences(of: "~", with: " ")
                .replacingOccurrences(of: "^", with: "\n")
                .replacingOccurrences(of: "%", with: "\t")

        switch tag {
        case "P":
            return "tp " + (pdfParseHexU16(argument).map(String.init) ?? "-")
        case "S":
            return "ts " + (pdfHexToUnicodeString(argument).map(show) ?? "-")
        case "N":
            return "tn " + show(pdfNormalizeToUnicodeDestination(argument))
        case "C":
            return "tc "
                + (pdfHexToUnicodeScalar(argument).map { String(format: "%04X", $0) } ?? "-")
        case "U":
            return "tu " + (pdfFindUsecmapName(argument) ?? "-")
        default:
            return nil
        }
    }
}
