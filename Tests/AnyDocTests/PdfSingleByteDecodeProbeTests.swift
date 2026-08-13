import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the single-byte decoding fallbacks against
/// `extractor/fonts.rs`.
@Suite struct PdfSingleByteDecodeProbeTests {
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

    private func hex(_ text: String) -> String {
        Array(text.utf8).map { String(format: "%02x", $0) }.joined()
    }

    private func text(_ hexString: String) -> String {
        String(decoding: bytes(fromHex: hexString), as: UTF8.self)
    }

    @Test func singleByteFallbacksMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/singlebyte-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/singlebyte-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        let expected = expectedText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, line) in cases.enumerated() where index < expected.count {
            let p = line.split(separator: " ").map(String.init)
            var ours = ""
            switch p[0] {
            case "B" where p.count >= 3:
                ours =
                    "b "
                    + hex(pdfDecodeSingleByteRun(bytes(fromHex: p[1]), useCp1252: p[2] == "1"))
            case "N" where p.count >= 3:
                ours =
                    "n "
                    + hex(pdfNormaliseCp1252Controls(text(p[1]), useCp1252: p[2] == "1"))
            case "U" where p.count >= 3:
                let name = p[1] == "-" ? nil : text(p[1])
                let result = pdfShouldUseCp1252(baseFontName: name, isType0CidFont: p[2] == "1")
                ours = "u \(result ? 1 : 0)"
            case "P" where p.count >= 2:
                ours = "p " + hex(pdfCleanSymbolPua(text(p[1])))
            case "S" where p.count >= 3:
                let name = p[2] == "-" ? nil : text(p[2])
                let result = pdfDecodeSymbolFallback(bytes(fromHex: p[1]), baseFontName: name)
                ours = "s " + (result.map(hex) ?? "-")
            case "T" where p.count >= 2:
                ours = "t \(pdfScoreText(text(p[1])))"
            case "C" where p.count >= 3:
                ours =
                    "c "
                    + hex(pdfChooseBestCmapDecode(primary: text(p[1]), remapped: text(p[2])))
            default:
                continue
            }
            if ours != expected[index] {
                mismatches.append(
                    "case \(index) (\(line))\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        print("pdf single-byte probe: \(cases.count) cases compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) single-byte divergences:\n\(report)")
    }
}
