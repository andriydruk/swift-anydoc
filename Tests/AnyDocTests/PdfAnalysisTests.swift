import Testing

@testable import AnyDoc

/// The analysis prologue: what the writer knows before it writes anything.
@Suite struct PdfAnalysisTests {
    private func line(
        _ text: String, y: Float, size: Float = 10, page: Int = 1, bold: Bool = false,
        mcid: Int? = nil, x: Float = 20
    ) -> PdfTextLine {
        var item = PdfLayoutItem(
            text: text, x: x, y: y, width: 40, fontSize: size, fontName: "F1")
        item.isBold = bold
        item.mcid = mcid
        return PdfTextLine(items: [item], y: y, page: page)
    }

    private func body(_ count: Int = 8) -> [PdfTextLine] {
        (0..<count).map {
            line("body line \($0) of ordinary running prose here", y: 700 - Float($0) * 20)
        }
    }

    @Test func theBaseSizeIsMeasuredUnlessGiven() {
        #expect(pdfAnalyseDocument(body()).baseSize == 10)
        var options = PdfMarkdownOptions()
        options.baseFontSize = 14
        #expect(pdfAnalyseDocument(body(), options: options).baseSize == 14)
    }

    @Test func dropCapsMergeBeforeTheTiersAreDiscovered() {
        // This is the ordering the prologue exists to fix. A 30pt drop cap
        // over 10pt body clears the 1.2× ratio gate, and `compute_heading_tiers`
        // has no minimum occupancy — so left in place it would define a tier
        // of its own that exactly one glyph reaches.
        let withCap =
            [line("Chapter One", y: 760), line("nce upon a time there was", y: 740)]
            + [line("O", y: 730, size: 30, x: 10)] + body()
        // Computed directly on the unmerged lines, the phantom tier is there.
        #expect(pdfHeadingTiers(withCap, bodySize: 10) == [30])
        // The prologue merges first, so it is not.
        let analysis = pdfAnalyseDocument(withCap)
        #expect(analysis.headingTiers.isEmpty)
        #expect(pdfLineText(analysis.lines[1]) == "Once upon a time there was")
    }

    @Test func wrappedTitlesAreOneLineByTheTimeTheWriterSeesThem() {
        let analysis = pdfAnalyseDocument(
            [line("About Glenair the", y: 780, size: 20), line("Interconnect Company", y: 760, size: 20)]
                + body())
        #expect(pdfLineText(analysis.lines[0]) == "About Glenair the Interconnect Company")
        #expect(analysis.lines.count == body().count + 1)
    }

    @Test func indexSetsReferToTheMergedLinesNotTheInput() {
        // Two lines in, one line out — so an index computed against the input
        // would point at the wrong line. Everything index-based is computed
        // after the merges for exactly this reason.
        let input =
            [line("About Glenair the", y: 780, size: 20), line("Interconnect Company", y: 760, size: 20)]
            + body()
        let analysis = pdfAnalyseDocument(input)
        #expect(analysis.lines.count < input.count)
        for index in analysis.isolatedLines { #expect(index < analysis.lines.count) }
    }

    @Test func theBoldMergeCanBeTurnedOff() {
        let run = (0..<2).map { line("A Short Bold Heading", y: 760 - Float($0) * 14, bold: true) }
        #expect(pdfAnalyseDocument(run + body()).lines.count == body().count + 1)
        #expect(
            pdfAnalyseDocument(run + body(), mergeWrappedBoldHeadings: false).lines.count
                == body().count + 2)
    }

    @Test func chartTextIsExcludedFromTheSequencePass() {
        let lines = [line("Chart Label Text Here", y: 500, x: 300)] + body()
        let regions = [1: [PdfImageRegion(x0: 280, y0: 480, x1: 600, y1: 520)]]
        #expect(pdfAnalyseDocument(lines).sequenceExcludedLines.isEmpty)
        #expect(
            pdfAnalyseDocument(lines, pageChartRegions: regions).sequenceExcludedLines.contains(0))
    }

    @Test func taggedNonHeadingContentIsExcludedFromTheSequencePass() {
        let lines = [line("Tagged Caption Line", y: 760, mcid: 5)] + body()
        #expect(
            pdfAnalyseDocument(lines, structRoles: [1: [5: .caption]])
                .sequenceExcludedLines.contains(0))
        // A tagged heading is not excluded — it is the thing being looked for.
        #expect(
            !pdfAnalyseDocument(lines, structRoles: [1: [5: .h2]])
                .sequenceExcludedLines.contains(0))
    }

    @Test func theOveruseAuditRunsOnTheMergedLines() {
        let many = (0..<30).map {
            line("tagged line \($0) of the document", y: 760 - Float($0) * 20, mcid: $0)
        }
        var headings: PdfStructRoleMap = [1: [:]]
        for index in 0..<30 { headings[1]![index] = .h2 }
        #expect(pdfAnalyseDocument(many, structRoles: headings).overusedHeadingLevels == [2])
        var paragraphs: PdfStructRoleMap = [1: [:]]
        for index in 0..<30 { paragraphs[1]![index] = .p }
        #expect(pdfAnalyseDocument(many, structRoles: paragraphs).overusedHeadingLevels.isEmpty)
    }

    @Test func anEmptyDocumentAnalysesToNothing() {
        let analysis = pdfAnalyseDocument([])
        #expect(analysis.lines.isEmpty)
        #expect(analysis.headingTiers.isEmpty)
        #expect(analysis.isolatedLines.isEmpty)
        #expect(analysis.sequenceHeadingLevels.isEmpty)
    }

    @Test func aZeroBaseSizeIsAppliedWithoutValidation() {
        // The reference takes the override as given. A zero makes every size
        // ratio infinite, which is reproduced rather than guarded.
        var options = PdfMarkdownOptions()
        options.baseFontSize = 0
        let analysis = pdfAnalyseDocument(body(), options: options)
        #expect(analysis.baseSize == 0)
        #expect(analysis.headingTiers == [10])
    }
}
