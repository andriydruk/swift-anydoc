import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the `/Differences` array against
/// `parse_encoding_dictionary`.
@Suite struct PdfEncodingDifferencesProbeTests {
    @Test func differencesParsingMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/difference-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/difference-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n", omittingEmptySubsequences: false)
        let answers = expectedText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        // Two lines of answer per case.
        #expect(answers.count == cases.count * 2, "case and answer counts disagree")

        var mismatches: [String] = []
        var mapped = 0
        for (index, line) in cases.enumerated() where index * 2 + 1 < answers.count {
            var baseFont: String?
            var items: [PdfObject] = []
            for token in line.split(separator: " ") where !token.isEmpty {
                if token.hasPrefix("@") {
                    baseFont = String(token.dropFirst())
                } else if token.hasPrefix("/") {
                    items.append(.name(Array(token.dropFirst().utf8)))
                } else if let value = Int64(token) {
                    items.append(.integer(value))
                } else {
                    items.append(.null)
                }
            }

            let result = pdfParseEncodingDifferences(items, baseFontName: baseFont)
            mapped += result.map.count
            var ours = "d"
            for code in result.map.keys.sorted() {
                ours += " \(code):" + String(result.map[code]!.value, radix: 16, uppercase: true)
            }
            var gids = "g"
            for code in result.gidCodes { gids += " \(code)" }

            if ours != answers[index * 2] || gids != answers[index * 2 + 1] {
                mismatches.append(
                    "case \(index) (\(line))\n    ours: \(ours) | \(gids)\n"
                        + "    rust: \(answers[index * 2]) | \(answers[index * 2 + 1])")
            }
        }
        print("pdf differences probe: \(cases.count) cases compared, \(mapped) codes mapped")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) differences divergences:\n\(report)")
    }
}
