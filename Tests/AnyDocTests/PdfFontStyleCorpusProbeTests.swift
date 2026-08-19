// Per-font style flags across the whole corpus, against the reference's own
// answers.
//
// `PdfFontFileStyleProbeTests` already checks these functions over a small
// hand-built font corpus. This runs them over every document instead, and it
// exists because of what wave 151 established: the Markdown reflects a
// descriptor's `/Flags` only when some run happens to be emphasised, so a
// document whose text is all regular can carry a wrong italic verdict and
// still compare byte-identical.
//
// Gated on `ANYDOC_PDF_CORPUS`, reading `<name>.pdf.fontstyle` beside each
// document; without the dumps the suite skips.
import Foundation
import Testing

@testable import AnyDoc

@Suite struct PdfFontStyleCorpusProbeTests {
    @Test func fontStyleFlagsMatchTheReferenceAcrossTheCorpus() throws {
        guard let root = ProcessInfo.processInfo.environment["ANYDOC_PDF_CORPUS"],
            !root.isEmpty
        else { return }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root) else { return }

        var mismatches: [String] = []
        var compared = 0
        var fontsSeen = 0
        for name in names.filter({ $0.hasSuffix(".pdf") }).sorted() {
            let path = root + "/" + name
            guard let expected = try? String(contentsOfFile: path + ".fontstyle", encoding: .utf8),
                let data = manager.contents(atPath: path)
            else { continue }

            var document: PdfDocument
            do { document = try PdfDocument(bytes: [UInt8](data)) } catch { continue }

            var ours = ""
            for (index, page) in pdfDocumentPages(&document).enumerated() {
                // The reference keys pages by its own numbering, which starts
                // at one and follows tree order — the same order as ours.
                let number = index + 1
                guard let resources = document.value(page, "Resources")?.asDictionary,
                    let fonts = document.value(resources, "Font")?.asDictionary
                else { continue }
                for key in fonts.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                    let resourceName = String(decoding: key, as: UTF8.self)
                    guard let font = document.value(fonts, resourceName)?.asDictionary else {
                        ours += "f \(number) \(resourceName) missing\n"
                        continue
                    }
                    var cache = PdfFontStyleCache()
                    let style = pdfDescriptorStyleFlags(&document, font, cache: &cache)
                    let objectNumber = pdfFontFileObjectNumber(&document, font)
                    fontsSeen += 1
                    ours += "f \(number) \(resourceName)"
                        + " \(style.italic ? 1 : 0) \(style.bold ? 1 : 0)"
                        + " \(objectNumber.map(String.init) ?? "-")\n"
                }
            }

            compared += 1
            if ours != expected {
                mismatches.append(
                    "\(name)\n      ours: \(ours.debugDescription)"
                        + "\n      rust: \(expected.debugDescription)")
            }
        }

        // A gate pointing somewhere without `.fontstyle` dumps compares
        // nothing and reports green, which is the failure this assertion
        // exists to prevent — and `fontsSeen` guards the subtler version:
        // wave 152 shipped this oracle when every font in the corpus scored
        // `0 0`, so it agreed on 131 documents while deciding nothing.
        #expect(compared > 0, "no .fontstyle dumps beside the corpus — run scripts/run-probes.sh")
        #expect(fontsSeen > 0, "the corpus has no fonts to compare")

        print("fontstyle: \(compared) compared, \(mismatches.count) differ, \(fontsSeen) fonts")
        for line in mismatches.prefix(6) { print(line) }
        #expect(mismatches.isEmpty)
    }
}
