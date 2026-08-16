import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the ToUnicode stream parser against the
/// reference's `ToUnicodeCMap::parse`.
///
/// Wave 5 ported that function by *reimplementing* it as a byte scanner
/// rather than transliterating its helpers, and for ninety waves its only
/// check was a probe of its own design — which validated what the scanner
/// did, never what the reference did on the same input. Wave 96 found one
/// behaviour missing entirely as a result. This is the differential suite
/// that should have existed from the start.
///
/// The comparison is by **what the map answers**, not how it stores it: the
/// reference keeps ranges lazily where this port flattens them, so `lookup`
/// is the only fair basis.
@Suite struct PdfCMapParseProbeTests {
    @Test func cmapParsingMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/cmapparse-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/cmapparse-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n").map(String.init)
        let expected = expectedText.split(separator: "\n").filter { !$0.isEmpty }.map(String.init)
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, line) in cases.enumerated() where index < expected.count {
            guard let ours = answer(for: line) else { continue }
            if ours != expected[index] {
                mismatches.append(
                    "\(line.prefix(90))\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        print("pdf cmap-parse probe: \(cases.count) streams compared")
        let report = mismatches.prefix(10).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) cmap-parse divergences:\n\(report)")
    }

    private func answer(for line: String) -> String? {
        guard let separator = line.range(of: " ? ") else { return nil }
        let stream = String(line[line.startIndex..<separator.lowerBound])
            .replacingOccurrences(of: "~", with: " ")
            .replacingOccurrences(of: "^", with: "\n")
        let codes = String(line[separator.upperBound...])

        let cmap = parsePdfToUnicode(Array(stream.utf8))
        // The reference's `parse` returns `None` when nothing was mapped;
        // this port models that as an empty map rather than an optional.
        if cmap.isEmpty { return "cm -" }
        var out = "cm b\(cmap.codeByteLength)"
        for hex in codes.split(separator: ",") {
            let trimmed = String(hex).rustTrim()
            let code = UInt32(trimmed, radix: 16) ?? 0
            if let text = cmap.lookup(code) {
                let scalars = text.unicodeScalars.map { String(format: "%04X", $0.value) }
                    .joined(separator: ".")
                out += " \(trimmed)=\(scalars)"
            } else {
                out += " \(trimmed)=-"
            }
        }
        return out
    }
}
