import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the standalone detector helpers against
/// `distribute_pages`, `page_ocr_reasons` and `estimate_page_count_from_bytes`.
@Suite struct PdfDetectorProbeTests {
    @Test func detectorHelpersMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/detector-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/detector-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, block) in blocks.enumerated() where index < expected.count {
            var ours = ""
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                let p = line.split(separator: " ", omittingEmptySubsequences: false)
                guard let tag = p.first else { continue }
                switch tag {
                case "D" where p.count >= 3:
                    let count = UInt32(p[1]) ?? 0
                    let total = UInt32(p[2]) ?? 0
                    ours += "d"
                    for page in pdfDistributePages(count, total: total) { ours += " \(page)" }
                    ours += "\n"
                case "A" where p.count >= 8:
                    let analysis = PdfPageAnalysis(
                        textOperatorCount: UInt32(p[1]) ?? 0,
                        hasImages: p[2] == "1",
                        hasTemplateImage: p[3] == "1",
                        uniqueTextCharacters: UInt32(p[4]) ?? 0,
                        hasVectorText: p[5] == "1",
                        hasIdentityHNoToUnicode: p[6] == "1",
                        hasOnlyType3Fonts: p[7] == "1")
                    ours += "a"
                    for reason in pdfPageOcrReasons(analysis) { ours += " \(reason)" }
                    ours += "\n"
                case "B":
                    let hex = p.count >= 2 ? String(p[1]) : ""
                    var bytes: [UInt8] = []
                    var scalars = Array(hex.unicodeScalars)
                    var offset = 0
                    while offset + 1 < scalars.count {
                        let pair = String(String.UnicodeScalarView(scalars[offset...offset + 1]))
                        bytes.append(UInt8(pair, radix: 16) ?? 0)
                        offset += 2
                    }
                    ours += "b \(pdfEstimatePageCountFromBytes(bytes))\n"
                default:
                    continue
                }
            }

            if ours != expected[index] {
                mismatches.append(
                    "case \(index)\n    ours: \(ours.replacingOccurrences(of: "\n", with: " | "))"
                        + "\n    rust: "
                        + expected[index].replacingOccurrences(of: "\n", with: " | "))
            }
        }
        print("pdf detector probe: \(blocks.count) cases compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) detector divergences:\n\(report)")
    }
}
