import Testing

@testable import AnyDoc

/// The classification branches and the sampling strategies.
///
/// The differential probe covers the whole detector against 77 documents and
/// reaches all four kinds and all four OCR reasons. These pin the parts a
/// corpus cannot isolate: the exact ratio threshold, each strategy's page
/// selection, and the phase-3 rule that flags a page in an otherwise
/// text-based document.
@Suite struct PdfDocumentDetectorTests {
    /// The default config's values are load-bearing and easy to drift.
    @Test func theDefaultConfigMatchesTheReference() {
        let config = PdfDetectionConfig()
        #expect(config.minimumTextOperatorsPerPage == 3)
        #expect(config.textPageRatioThreshold == 0.6)
        // Sampling eight, not early exit: a report with an image-only cover
        // would otherwise be judged on its cover alone.
        #expect(config.strategy == .sample(8))
    }

    /// `distribute_pages` is what `.sample(n)` selects with, and the first
    /// and last page are always included — the cover and the back matter are
    /// the two most likely to be unrepresentative.
    @Test func samplingAlwaysIncludesTheFirstAndLastPage() {
        let chosen = pdfDistributePages(4, total: 20)
        #expect(chosen.first == 1)
        #expect(chosen.last == 20)
        #expect(chosen.count == 4)
    }

    @Test func samplingMoreThanExistsGivesEveryPage() {
        #expect(pdfDistributePages(8, total: 3) == [1, 2, 3])
    }

    /// Phase 3: a page whose fonts cannot decode is flagged even when the
    /// document as a whole is text-based. This is the case that matters —
    /// a readable document with two unreadable pages — and a detector that
    /// only listed pages for scanned documents would miss it entirely.
    @Test func anUndecodablePageIsFlaggedInATextBasedDocument() {
        var analysis = PdfPageAnalysis()
        analysis.textOperatorCount = 20
        analysis.uniqueTextCharacters = 12
        analysis.hasIdentityHNoToUnicode = true
        // The page reports garbled text rather than "scanned": there *is* a
        // text layer, and extracting it yields nonsense rather than nothing.
        #expect(pdfPageOcrReasons(analysis) == [PdfOcrReason.suspectedGarbledText])
    }

    /// A page with neither text nor images is `no_text`, not `scanned`.
    /// The distinction is real: one is a blank page, the other is a picture
    /// of a page, and only the second is worth sending to OCR.
    @Test func aBlankPageIsNoTextRatherThanScanned() {
        #expect(pdfPageOcrReasons(PdfPageAnalysis()) == [PdfOcrReason.noText])

        var scanned = PdfPageAnalysis()
        scanned.hasTemplateImage = true
        #expect(pdfPageOcrReasons(scanned) == [PdfOcrReason.scanned])
    }

    /// Both leading reasons can hold at once, so the result is a list rather
    /// than a single verdict.
    @Test func undecodableAndOutlinedTextBothReport() {
        var analysis = PdfPageAnalysis()
        analysis.hasOnlyType3Fonts = true
        analysis.hasVectorText = true
        #expect(
            pdfPageOcrReasons(analysis)
                == [PdfOcrReason.suspectedGarbledText, PdfOcrReason.vectorText])
    }
}
