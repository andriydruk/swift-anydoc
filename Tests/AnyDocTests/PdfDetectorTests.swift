import Testing

@testable import AnyDoc

/// The standalone detector helpers, pinned without the oracle.
@Suite struct PdfDetectorTests {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: page-count fallback

    @Test func pageDictionariesAreCounted() {
        #expect(pdfEstimatePageCountFromBytes(bytes("/Type /Page\n/Type /Page\n")) == 2)
    }

    @Test func theTreeNodeIsNotAPage() {
        // `/Pages` is the page-tree node. The whole of the distinction is the
        // delimiter test after `Page`: `s` is not one.
        #expect(pdfEstimatePageCountFromBytes(bytes("/Type /Pages\n")) == 0)
        #expect(pdfEstimatePageCountFromBytes(bytes("/Type /PageX")) == 0)
        #expect(
            pdfEstimatePageCountFromBytes(bytes("/Type /Page\n/Type /Pages\n/Type /Page\n")) == 2)
    }

    @Test func aNameRunningToTheEndOfTheBufferCounts() {
        // There is no byte after it to disqualify it.
        #expect(pdfEstimatePageCountFromBytes(bytes("/Type /Page")) == 1)
    }

    @Test func structuralDelimitersEndTheName() {
        #expect(pdfEstimatePageCountFromBytes(bytes("/Type/Page/Type/Page")) == 2)
        #expect(pdfEstimatePageCountFromBytes(bytes("/Type/Page(")) == 1)
        #expect(pdfEstimatePageCountFromBytes(bytes("/Type/Page%")) == 1)
    }

    @Test func allSixWhitespaceBytesAreSkipped() {
        #expect(pdfEstimatePageCountFromBytes(bytes("/Type \t\r\n\u{0C}/Page ") ) == 1)
        // A null byte counts as whitespace in PDF, unlike most languages.
        #expect(pdfEstimatePageCountFromBytes([0x2F, 0x54, 0x79, 0x70, 0x65, 0x00]
            + bytes("/Page")) == 1)
    }

    @Test func truncatedAndEmptyBuffersAreSafe() {
        #expect(pdfEstimatePageCountFromBytes(bytes("/Type")) == 0)
        #expect(pdfEstimatePageCountFromBytes(bytes("/Typ")) == 0)
        #expect(pdfEstimatePageCountFromBytes([]) == 0)
    }

    @Test func unrelatedTypesAreIgnored() {
        #expect(
            pdfEstimatePageCountFromBytes(bytes("/Type /Font /Type /Page /Type /XObject")) == 1)
    }

    // MARK: byte helpers

    @Test func nameDelimitersAreTheStructuralBytes() {
        for byte in bytes("()<>[]{}/%") { #expect(pdfIsNameDelimiterByte(byte)) }
        for byte in [UInt8(0), 0x09, 0x0A, 0x0C, 0x0D, 0x20] {
            #expect(pdfIsWhitespaceByte(byte))
            #expect(pdfIsNameDelimiterByte(byte))
        }
        #expect(!pdfIsNameDelimiterByte(UInt8(ascii: "s")))
        // A vertical tab is *not* PDF whitespace, unlike a form feed.
        #expect(!pdfIsWhitespaceByte(0x0B))
    }

    @Test func findingBytesRespectsTheStartOffset() {
        let haystack = bytes("abcabc")
        #expect(pdfFindBytes(haystack, bytes("abc")) == 0)
        #expect(pdfFindBytes(haystack, bytes("abc"), from: 1) == 3)
        #expect(pdfFindBytes(haystack, bytes("abc"), from: 4) == nil)
        #expect(pdfFindBytes(haystack, bytes("zz")) == nil)
        #expect(pdfFindBytes([], bytes("a")) == nil)
    }

    // MARK: page sampling

    @Test func theFirstAndLastPageAreAlwaysSampled() {
        // One page between the ends: step is (10 − 2) / 2 = 4, so index 5.
        #expect(pdfDistributePages(3, total: 10) == [1, 5, 10])
        #expect(pdfDistributePages(5, total: 10) == [1, 3, 5, 7, 10])
    }

    @Test func askingForEveryPageGivesEveryPage() {
        #expect(pdfDistributePages(10, total: 10) == Array(1...10))
        #expect(pdfDistributePages(11, total: 10) == Array(1...10))
    }

    @Test func askingForNoneGivesNone() {
        #expect(pdfDistributePages(0, total: 10).isEmpty)
        #expect(pdfDistributePages(0, total: 0).isEmpty)
    }

    @Test func aZeroPageDocumentSamplesNothing() {
        #expect(pdfDistributePages(2, total: 0).isEmpty)
    }

    @Test func collidingIndicesShortenTheResult() {
        // Integer spacing means computed indices can coincide on a small
        // document, and the result is simply shorter than asked for.
        #expect(pdfDistributePages(1, total: 10) == [1])
        #expect(pdfDistributePages(2, total: 10) == [1, 10])
        #expect(pdfDistributePages(4, total: 5) == [1, 2, 3, 5])
    }

    // MARK: OCR reasons

    @Test func undecodableFontsOutrankMissingText() {
        // These persist even when a text layer is present — extracting it
        // yields garbage rather than nothing, which is harder to notice.
        var analysis = PdfPageAnalysis()
        analysis.textOperatorCount = 5
        analysis.uniqueTextCharacters = 9
        analysis.hasIdentityHNoToUnicode = true
        #expect(pdfPageOcrReasons(analysis) == [PdfOcrReason.suspectedGarbledText])
        analysis.hasIdentityHNoToUnicode = false
        analysis.hasOnlyType3Fonts = true
        #expect(pdfPageOcrReasons(analysis) == [PdfOcrReason.suspectedGarbledText])
    }

    @Test func garbledTextAndVectorTextCanBothApply() {
        var analysis = PdfPageAnalysis()
        analysis.hasOnlyType3Fonts = true
        analysis.hasVectorText = true
        #expect(
            pdfPageOcrReasons(analysis)
                == [PdfOcrReason.suspectedGarbledText, PdfOcrReason.vectorText])
    }

    @Test func aBarePageWithNoTextIsNoText() {
        #expect(pdfPageOcrReasons(PdfPageAnalysis()) == [PdfOcrReason.noText])
    }

    @Test func anImageBackedPageWithoutTextIsScanned() {
        var analysis = PdfPageAnalysis()
        analysis.hasImages = true
        #expect(pdfPageOcrReasons(analysis) == [PdfOcrReason.scanned])
        analysis.hasImages = false
        analysis.hasTemplateImage = true
        #expect(pdfPageOcrReasons(analysis) == [PdfOcrReason.scanned])
    }

    @Test func textOperatorsWithoutCharactersAreNotExtractableText() {
        // Both halves are required: operators that draw nothing readable
        // leave the page as good as blank.
        var analysis = PdfPageAnalysis()
        analysis.textOperatorCount = 5
        #expect(pdfPageOcrReasons(analysis) == [PdfOcrReason.noText])
        analysis.textOperatorCount = 0
        analysis.uniqueTextCharacters = 9
        #expect(pdfPageOcrReasons(analysis) == [PdfOcrReason.noText])
    }

    @Test func aPageWithRealTextStillReportsScannedWhenAsked() {
        // The function answers "why would this need OCR", not "does it" — a
        // page with text and an image falls through to `scanned`.
        var analysis = PdfPageAnalysis()
        analysis.textOperatorCount = 5
        analysis.uniqueTextCharacters = 9
        analysis.hasImages = true
        #expect(pdfPageOcrReasons(analysis) == [PdfOcrReason.scanned])
    }
}
