import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the CFF Name INDEX reader against `cff_font_name`.
@Suite struct PdfFontFileStyleProbeTests {
    @Test func cffFontNameMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/cffname-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/cffname-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n", omittingEmptySubsequences: false)
        let expected = expectedText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var named = 0
        for (index, hex) in cases.enumerated() where index < expected.count {
            let bytes = hexBytes(String(hex))
            let name = pdfCffFontName(bytes)
            if name != nil { named += 1 }
            let ours = name.map { "c " + Array($0.utf8).map { hexByte($0) }.joined() } ?? "c -"
            if ours != expected[index] {
                let shown = hex.count > 80 ? String(hex.prefix(80)) + "…" : String(hex)
                mismatches.append("\(shown)\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        print("pdf cff-name probe: \(cases.count) programs compared, \(named) named")
        let report = mismatches.prefix(5).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) CFF name divergences:\n\(report)")
    }

    /// Differential check of `descriptor_style_flags` and
    /// `get_font_file2_obj_num` over the hand-built font corpus.
    @Test func fontStyleFlagsMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_FONT_CORPUS"], !path.isEmpty
        else { return }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: path) else { return }
        let pdfs = names.filter { $0.hasSuffix(".pdf") }.sorted()
        #expect(!pdfs.isEmpty, "font corpus is empty")

        var mismatches: [String] = []
        var compared = 0
        var styled = 0
        for name in pdfs {
            let pdfPath = path + "/" + name
            let expectedPath = path + "/" + String(name.dropLast(4)) + ".expected"
            guard let expected = try? String(contentsOfFile: expectedPath, encoding: .utf8)
            else { continue }
            guard let data = manager.contents(atPath: pdfPath) else { continue }

            var lines: [String] = []
            if var document = try? PdfDocument(bytes: [UInt8](data)) {
                for (number, fonts) in pageFontDictionaries(&document) {
                    for (resource, entry) in fonts {
                        let style: PdfFontStyle
                        let key: UInt32?
                        if let font = pdfFontsResolveDictionary(&document, entry) {
                            var cache = PdfFontStyleCache()
                            style = pdfDescriptorStyleFlags(&document, font, cache: &cache)
                            key = pdfFontFileObjectNumber(&document, font)
                            if style != PdfFontStyle() { styled += 1 }
                            lines.append(
                                "f \(number) \(resource) \(style.italic ? 1 : 0) "
                                    + "\(style.bold ? 1 : 0) \(key.map(String.init) ?? "-")")
                        } else {
                            lines.append("f \(number) \(resource) missing")
                        }
                    }
                }
            } else {
                lines.append("error")
            }

            compared += 1
            let ours = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            if ours != expected {
                mismatches.append("\(name)\n    ours:\n\(ours)    rust:\n\(expected)")
            }
        }
        print("pdf font-style probe: \(compared) documents compared, \(styled) styled fonts")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) font-style divergences:\n\(report)")
    }

    /// Every page's `/Resources /Font` entries, in the order the probe emits
    /// them: pages by number, resource names sorted bytewise.
    private func pageFontDictionaries(
        _ document: inout PdfDocument
    ) -> [(Int, [(String, PdfObject)])] {
        var result: [(Int, [(String, PdfObject)])] = []
        for (index, pageID) in pdfPageObjectIds(&document).enumerated() {
            let page = document.object(pageID)
            guard let pageDictionary = page.asDictionary,
                let resourcesObject = pageDictionary["Resources"],
                let resources = pdfFontsResolveDictionary(&document, resourcesObject),
                let fontsObject = resources["Font"],
                let fonts = pdfFontsResolveDictionary(&document, fontsObject)
            else { continue }
            let sorted = fonts.entries.sorted { lexicographicallyPrecedes($0.key, $1.key) }
            result.append(
                (
                    index + 1,
                    sorted.map { (String(decoding: $0.key, as: UTF8.self), $0.value) }
                ))
        }
        return result
    }

    private func lexicographicallyPrecedes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.lexicographicallyPrecedes(b)
    }

    private func hexBytes(_ hex: String) -> [UInt8] {
        let characters = Array(hex.utf8)
        var bytes: [UInt8] = []
        var index = 0
        while index + 1 < characters.count {
            let high = hexValue(characters[index])
            let low = hexValue(characters[index + 1])
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    private func hexValue(_ byte: UInt8) -> UInt8 {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return 0
        }
    }

    private func hexByte(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}
