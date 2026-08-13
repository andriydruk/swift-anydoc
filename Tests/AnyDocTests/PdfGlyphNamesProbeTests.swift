import Foundation
import Testing

@testable import AnyDoc

/// Differential check of glyph-name resolution against `glyph_to_char`, over
/// every name the reference's table holds plus the fallback forms.
@Suite struct PdfGlyphNamesProbeTests {
    @Test func glyphNameResolutionMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/glyphname-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/glyphname-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n", omittingEmptySubsequences: false)
        let expected = expectedText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var resolved = 0
        for (index, name) in cases.enumerated() where index < expected.count {
            let scalar = pdfGlyphToScalar(String(name))
            if scalar != nil { resolved += 1 }
            let ours =
                scalar.map { "g " + String($0.value, radix: 16, uppercase: true) } ?? "g -"
            if ours != expected[index] {
                mismatches.append(
                    "\(name)\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        print("pdf glyph-name probe: \(cases.count) names compared, \(resolved) resolved")
        let report = mismatches.prefix(5).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) glyph-name divergences:\n\(report)")
    }
}
