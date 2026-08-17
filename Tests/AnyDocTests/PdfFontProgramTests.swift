import Foundation
import Testing

@testable import AnyDoc

/// Embedded font programs found and read.
///
/// These assert that the *program is located at all*, which is the part a
/// refactor can silently drop: the pipeline would go on producing raw glyph
/// ids, which look like text and pass every check that does not compare
/// against the reference.
@Suite struct PdfFontProgramTests {
    private func programs(_ name: String) -> [String: PdfTrueTypeCMap]? {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_PDF_CORPUS"],
            let data = FileManager.default.contents(atPath: path + "/" + name),
            var document = try? PdfDocument(bytes: [UInt8](data)),
            let page = pdfDocumentPages(&document).first
        else { return nil }
        return pdfPageFontPrograms(&document, page)
    }

    @Test func aTrueTypeProgramIsFoundInFontFile2() throws {
        guard let found = programs("font-embedded-cmap.pdf") else { return }
        #expect(!found.isEmpty, "no font program located")
        // The font maps glyph 3 to `H`, which is what makes the document
        // read as `Hi!` rather than as three control characters.
        #expect(found.values.first?.glyphToCharacter[3] == "H")
    }

    @Test func anOpenTypeProgramIsFoundInFontFile3() throws {
        // OpenType wraps CFF outlines in the same sfnt container, so its
        // `cmap` is found by the same parser — but only if `/FontFile3` is
        // consulted at all, which it was not until wave 112.
        guard let found = programs("font-opentype-cmap.pdf") else { return }
        #expect(!found.isEmpty, "no font program located in /FontFile3")
        #expect(found.values.first?.glyphToCharacter[3] == "O")
    }

    @Test func aFontWithNoProgramYieldsNothing() throws {
        // The ordinary case: a standard font names no program, and must not
        // be given a phantom one.
        guard let found = programs("md-headings.pdf") else { return }
        #expect(found.isEmpty)
    }
}
