import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the markdown-level text-quality detectors against
/// `detect_encoding_issues`, `has_dollar_as_space_pattern` and the
/// `CipherGarbleStats` internals.
@Suite struct PdfTextQualityProbeTests {
    @Test func textQualityDetectorsMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/textquality-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/textquality-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var garbled = 0
        for (index, block) in blocks.enumerated() where index < expected.count {
            let hex = block.trimmingCharacters(in: .whitespacesAndNewlines)
            var bytes: [UInt8] = []
            let scalars = Array(hex.unicodeScalars)
            var offset = 0
            while offset + 1 < scalars.count {
                bytes.append(
                    UInt8(String(String.UnicodeScalarView(scalars[offset...offset + 1])), radix: 16)
                        ?? 0)
                offset += 2
            }
            let text = String(decoding: bytes, as: UTF8.self)

            var stats = PdfCipherGarbleStats()
            stats.add(text)
            if stats.looksGarbled() { garbled += 1 }
            let ours =
                "q \(pdfDetectEncodingIssues(text) ? 1 : 0) "
                + "\(pdfHasDollarAsSpacePattern(text) ? 1 : 0) "
                + "\(stats.asciiLetters) \(stats.asciiVowels) \(stats.latinExtendedLetters) "
                + "\(stats.nonLatinLetters) \(stats.letterBigrams) \(stats.caseShiftBigrams) "
                + String(format: "%.9f", stats.englishCosine()) + " "
                + String(format: "%.9f", stats.englishShapeCosine()) + " "
                + "\(stats.looksGarbled() ? 1 : 0)\n"

            if ours != expected[index] {
                mismatches.append("case \(index)\n    ours: \(ours)    rust: \(expected[index])")
            }
        }
        print("pdf text-quality probe: \(blocks.count) cases compared, \(garbled) garbled")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) text-quality divergences:\n\(report)")
    }
}
