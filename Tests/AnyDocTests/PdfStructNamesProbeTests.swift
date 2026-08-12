import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the bare-struct-name repair against
/// `fix_bare_struct_names`.
@Suite struct PdfStructNamesProbeTests {
    @Test func structNameRepairMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/structname-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/structname-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n", omittingEmptySubsequences: false)
        let expected = expectedText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var repaired = 0
        for (index, line) in cases.enumerated() where index < expected.count {
            var bytes: [UInt8] = []
            let scalars = Array(line.unicodeScalars)
            var offset = 0
            while offset + 1 < scalars.count {
                bytes.append(
                    UInt8(String(String.UnicodeScalarView(scalars[offset...offset + 1])), radix: 16)
                        ?? 0)
                offset += 2
            }
            let fixed = pdfFixBareStructNames(bytes)
            let changed = fixed != bytes
            if changed { repaired += 1 }
            let hex = fixed.map { String(format: "%02x", $0) }.joined()
            let ours = "n \(changed ? 1 : 0) \(hex)"
            if ours != expected[index] {
                mismatches.append("case \(index)\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        print("pdf struct-name probe: \(cases.count) cases compared, \(repaired) repaired")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) struct-name divergences:\n\(report)")
    }
}
