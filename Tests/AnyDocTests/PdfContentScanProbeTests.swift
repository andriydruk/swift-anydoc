import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the byte-level content scanner against
/// `scan_content_for_text_operators`, `extract_font_name_before_tf`,
/// `collect_text_chars_before` and `hex_val`.
@Suite struct PdfContentScanProbeTests {
    @Test func contentScanningMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/contentscan-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/contentscan-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let expected = expectedText.split(separator: "\n").filter { !$0.isEmpty }.map(String.init)
        let answered = cases.compactMap { answer(for: $0) }
        #expect(answered.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var verdicts: [String: Int] = [:]
        for (index, ours) in answered.enumerated() where index < expected.count {
            verdicts[String(ours.prefix(2)), default: 0] += 1
            if ours != expected[index] {
                mismatches.append("    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        let shape = verdicts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
        print("pdf content-scan probe: \(answered.count) cases compared — \(shape)")
        let report = mismatches.prefix(5).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) content-scan divergences:\n\(report)")
    }

    private func decode(_ text: String) -> [UInt8] {
        Array(
            text.replacingOccurrences(of: "~", with: " ")
                .replacingOccurrences(of: "^", with: "\n")
                .replacingOccurrences(of: "%", with: "\t").utf8)
    }

    private func hex(_ bytes: Set<UInt8>) -> String {
        bytes.sorted().map { String(format: "%02x", $0) }.joined()
    }

    private func answer(for line: String) -> String? {
        let space = line.firstIndex(of: " ")
        let tag = space.map { String(line[line.startIndex..<$0]) } ?? line
        let rest = space.map { String(line[line.index(after: $0)...]) } ?? ""
        let content = decode(rest)

        switch tag {
        case "S":
            var characters: Set<UInt8> = []
            var fonts: Set<[UInt8]> = []
            let scan = pdfScanContentForTextOperators(
                content, uniqueCharacters: &characters, usedFontNames: &fonts)
            let names = fonts.map { String(decoding: $0, as: UTF8.self) }.sorted()
            return "sc t=\(scan.textOperators) i=\(scan.imageCount) p=\(scan.pathOperators) "
                + "f=\(scan.fontChanges) c=\(hex(characters)) n=\(names.joined(separator: ","))"
        case "F":
            // The reference probe appends `Tf ` and asks at the join.
            var padded = content
            padded.append(contentsOf: Array("Tf ".utf8))
            let name = pdfExtractFontNameBeforeTf(padded, at: content.count)
            return "sf " + (name.map { String(decoding: $0, as: UTF8.self) } ?? "-")
        case "C":
            var characters: Set<UInt8> = []
            pdfCollectTextCharactersBefore(
                content, at: content.count, into: &characters)
            return "sx \(hex(characters))"
        case "H":
            let value = pdfHexValue(content.first ?? 0)
            return "sh " + (value.map(String.init) ?? "-")
        default:
            return nil
        }
    }
}
