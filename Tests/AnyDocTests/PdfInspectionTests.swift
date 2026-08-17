import Foundation
import Testing

@testable import AnyDoc

/// The public inspection API.
///
/// Its whole reason for existing is that a scanned document and an empty one
/// both convert to `""`. These check the distinction the string cannot make,
/// against real corpus documents where one is available and constructed ones
/// otherwise.
@Suite struct PdfInspectionTests {
    private func bytes(_ name: String) -> [UInt8]? {
        guard let root = ProcessInfo.processInfo.environment["ANYDOC_PDF_CORPUS"],
            !root.isEmpty,
            let data = FileManager.default.contents(atPath: root + "/" + name)
        else { return nil }
        return [UInt8](data)
    }

    @Test func aScanReportsWhyItIsEmpty() throws {
        guard let data = bytes("image-template.pdf") else { return }
        let converted = try AnyDoc.markdownInspectingPdf(data)

        // The string alone says nothing. The inspection says everything.
        #expect(converted.markdown.isEmpty)
        #expect(converted.inspection.isUnreadableWithoutOcr)
        #expect(converted.inspection.ocrRecommended)
        #expect(converted.inspection.pagesNeedingOcr == [1])
        #expect(converted.inspection.ocrReasonsByPage[1] == ["scanned"])
    }

    /// The complement, and the reason `isUnreadableWithoutOcr` is not just
    /// `markdown.isEmpty`: a genuinely empty page is *readable*, it simply
    /// has nothing on it, and sending it to OCR would waste the work.
    @Test func anEmptyPageIsNotAnUnreadableOne() throws {
        guard let data = bytes("empty-page.pdf") else { return }
        let converted = try AnyDoc.markdownInspectingPdf(data)
        #expect(converted.markdown.isEmpty)
        // It classifies as scanned — no text operators at all — but its
        // reason is `no_text` rather than `scanned`, which is the signal
        // that there is nothing to recover.
        #expect(converted.inspection.ocrReasonsByPage[1] == ["no_text"])
    }

    @Test func aTextDocumentNeedsNothing() throws {
        guard let data = bytes("md-headings.pdf") ?? bytes("md-table-rects.pdf") else { return }
        let converted = try AnyDoc.markdownInspectingPdf(data)
        #expect(!converted.markdown.isEmpty)
        #expect(converted.inspection.kind == .textBased)
        #expect(!converted.inspection.isUnreadableWithoutOcr)
        #expect(!converted.inspection.ocrRecommended)
        #expect(converted.inspection.pagesNeedingOcr.isEmpty)
    }

    /// A readable document with one unreadable page — the case the detector's
    /// third phase exists for. The document converts, and the inspection
    /// still names the page that came out as nonsense.
    @Test func aReadableDocumentCanStillNameABadPage() throws {
        guard let data = bytes("detector-type3-only.pdf") else { return }
        let inspection = try AnyDoc.inspectPdf(data)
        #expect(inspection.kind == .textBased)
        #expect(inspection.pagesNeedingOcr == [1])
        #expect(inspection.ocrReasonsByPage[1] == ["suspected_garbled_text"])
    }

    /// `inspectPdf` and the pair must agree — they are two entry points to
    /// one detector, and a refactor could easily leave one behind.
    @Test func inspectingAloneMatchesInspectingWhileConverting() throws {
        guard let data = bytes("mixed-image-and-text.pdf") else { return }
        #expect(try AnyDoc.inspectPdf(data) == AnyDoc.markdownInspectingPdf(data).inspection)
    }

    @Test func theMarkdownMatchesThePlainEntryPoint() throws {
        guard let data = bytes("md-table-rects.pdf") else { return }
        #expect(
            try AnyDoc.markdownInspectingPdf(data).markdown
                == AnyDoc.markdown(data, format: .pdf))
    }
}
