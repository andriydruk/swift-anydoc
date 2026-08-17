import Foundation
import Testing

@testable import AnyDoc

/// The document-level garbage gate.
///
/// A document the detector calls text-based can still extract to rubbish:
/// fonts that defeated every rung of the decode ladder produce a stream of
/// symbols that is well-formed Markdown and means nothing. Returning it
/// would look like a successful conversion to every caller that does not
/// read it — the failure this project names first.
@Suite struct PdfGarbageGateTests {
    private func bytes(_ name: String) -> [UInt8]? {
        guard let root = ProcessInfo.processInfo.environment["ANYDOC_PDF_CORPUS"],
            !root.isEmpty,
            let data = FileManager.default.contents(atPath: root + "/" + name)
        else { return nil }
        return [UInt8](data)
    }

    @Test func aGarbledDocumentConvertsToNothingAndSaysWhy() throws {
        guard let data = bytes("garbled-text-document.pdf") else { return }
        let converted = try AnyDoc.markdownInspectingPdf(data)

        #expect(converted.markdown.isEmpty)
        #expect(converted.inspection.ocrRecommended)
        #expect(converted.inspection.pagesNeedingOcr == [1])
        #expect(converted.inspection.ocrReasonsByPage[1] == ["suspected_garbled_text"])
    }

    /// The two entry points **differ** here, and that is the design rather
    /// than a defect. `inspectPdf` is the detector's view, taken before any
    /// glyph is decoded, so it cannot know the text will come out as
    /// rubbish; only extraction reveals that.
    ///
    /// Wave 124 added a test asserting the two agree, on a document where
    /// they do. This one names the case where they cannot.
    @Test func inspectingAloneCannotSeeGarbledText() throws {
        guard let data = bytes("garbled-text-document.pdf") else { return }
        let cheap = try AnyDoc.inspectPdf(data)
        let full = try AnyDoc.markdownInspectingPdf(data).inspection

        // Both call it text-based: there is plenty of text, and the detector
        // never looks at what it says.
        #expect(cheap.kind == .textBased)
        #expect(full.kind == .textBased)
        // Only the extracting one knows the text is worthless.
        #expect(cheap.pagesNeedingOcr.isEmpty)
        #expect(full.pagesNeedingOcr == [1])
    }

    /// The gate must not fire on ordinary prose, which would delete good
    /// documents. `is_garbage_text` needs fifty counted characters with
    /// fewer than half alphanumeric.
    @Test func ordinaryProseIsNotGarbage() {
        #expect(!pdfIsGarbageText("The quick brown fox jumps over the lazy dog, twice over."))
        // Short strings are never garbage, however symbolic.
        #expect(!pdfIsGarbageText("∀∁∂∃"))
        // Markdown syntax this port adds is not counted against the document.
        #expect(!pdfIsGarbageText(String(repeating: "# Heading\n", count: 12)))
    }

    @Test func aStreamOfSymbolsIsGarbage() {
        #expect(pdfIsGarbageText(String(repeating: "∀∁∂∃∄∅", count: 12)))
    }
}
