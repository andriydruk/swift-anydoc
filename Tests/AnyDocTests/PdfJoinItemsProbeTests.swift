import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the join decision against `should_join_items`.
@Suite struct PdfJoinItemsProbeTests {
    @Test func joinDecisionsMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(contentsOfFile: path + "/join-cases.txt", encoding: .utf8),
            let expectedText = try? String(contentsOfFile: path + "/join-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        let expected = expectedText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var joined = 0
        for (index, line) in cases.enumerated() where index < expected.count {
            let p = line.split(separator: " ", omittingEmptySubsequences: false)
            guard p.count >= 11 else { continue }
            func make(_ base: Int) -> PdfLayoutItem {
                PdfLayoutItem(
                    text: p[base + 4].replacingOccurrences(of: "~", with: " "),
                    x: Float(p[base]) ?? 0, y: 700, width: Float(p[base + 1]) ?? 0,
                    fontSize: Float(p[base + 2]) ?? 0, fontName: String(p[base + 3]))
            }
            let threshold = Float(p[0]) ?? 0.10
            let result = pdfShouldJoinItems(
                previous: make(1), current: make(6), singleCharacterThreshold: threshold)
            if result { joined += 1 }
            let ours = "j \(result ? 1 : 0)"
            if ours != expected[index] {
                mismatches.append("case \(index): \(line)\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        print("pdf join probe: \(cases.count) cases compared, \(joined) joined")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) join divergences:\n\(report)")
    }
}
