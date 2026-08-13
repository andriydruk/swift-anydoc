import Foundation
import Testing

@testable import AnyDoc

/// Differential check of ligature expansion against `expand_ligatures`.
@Suite struct PdfLigaturesProbeTests {
    private func bytes(fromHex hex: String) -> [UInt8] {
        var result: [UInt8] = []
        let scalars = Array(hex.unicodeScalars)
        var offset = 0
        while offset + 1 < scalars.count {
            result.append(
                UInt8(String(String.UnicodeScalarView(scalars[offset...offset + 1])), radix: 16)
                    ?? 0)
            offset += 2
        }
        return result
    }

    @Test func ligatureExpansionMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/ligature-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/ligature-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n", omittingEmptySubsequences: false)
        let expected = expectedText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, line) in cases.enumerated() where index < expected.count {
            let text = String(decoding: bytes(fromHex: String(line)), as: UTF8.self)
            let expanded = pdfExpandLigatures(text)
            let hex = Array(expanded.utf8).map { String(format: "%02x", $0) }.joined()
            let ours = "l \(hex)"
            if ours != expected[index] {
                mismatches.append(
                    "case \(index) (\(line))\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        print("pdf ligature probe: \(cases.count) cases compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) ligature divergences:\n\(report)")
    }
}
