import Foundation
import Testing

@testable import AnyDoc

/// Differential check of script classification, RTL detection and
/// visual-order reversal against `text_utils.rs`.
@Suite struct PdfBidiTextProbeTests {
    private func hex(_ text: String) -> String {
        Array(text.utf8).map { String(format: "%02x", $0) }.joined()
    }

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

    @Test func bidiHelpersMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(contentsOfFile: path + "/bidi-cases.txt", encoding: .utf8),
            let expectedText = try? String(contentsOfFile: path + "/bidi-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var rtlCount = 0
        for (index, block) in blocks.enumerated() where index < expected.count {
            let raw = bytes(fromHex: block.trimmingCharacters(in: .whitespacesAndNewlines))
            let text = String(decoding: raw, as: UTF8.self)

            let cjk = text.unicodeScalars.filter(pdfIsCjkScalarValue).count
            let rtl = text.unicodeScalars.filter(pdfIsRtlScalar).count
            let forms = text.unicodeScalars.filter(pdfIsArabicPresentationForm).count
            let isRtl = pdfIsRtlText([text])
            if isRtl { rtlCount += 1 }
            var ours = "t \(cjk) \(rtl) \(forms) \(isRtl ? 1 : 0) "
            ours += "\(pdfIsCidFontName(text) ? 1 : 0) "
            ours += hex(pdfReverseVisualArabic(text)) + "\n"
            ours += "d " + hex(pdfDecodeTextString(raw)) + "\n"

            if ours != expected[index] {
                mismatches.append("case \(index)\n    ours: \(ours)    rust: \(expected[index])")
            }
        }
        print("pdf bidi probe: \(blocks.count) cases compared, \(rtlCount) right-to-left")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) bidi divergences:\n\(report)")
    }
}
