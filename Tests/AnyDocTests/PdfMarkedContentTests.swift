import Testing

@testable import AnyDoc

/// Marked-content tracking in the extractor, pinned without the oracle.
@Suite struct PdfMarkedContentTests {
    private func runs(_ source: String) -> [PdfTextRun] {
        pdfExtractTextRuns(pdfParseContentStream(Array(source.utf8))) { _, bytes in
            String(decoding: bytes, as: UTF8.self)
        }
    }

    private func text(_ y: Int, _ body: String) -> String {
        "BT /F1 12 Tf 100 \(y) Td (\(body)) Tj ET "
    }

    @Test func untaggedTextCarriesNoId() {
        let result = runs(text(700, "plain"))
        #expect(result.count == 1)
        #expect(result[0].mcid == nil)
    }

    @Test func textInsideABeginDictionaryTakesItsId() {
        let result = runs("/Span << /MCID 3 >> BDC " + text(700, "tagged") + "EMC")
        #expect(result.map(\.mcid) == [3])
    }

    @Test func theIdAppliesOnlyBetweenTheOperators() {
        let source =
            text(720, "before") + "/Span << /MCID 4 >> BDC " + text(700, "inside") + "EMC "
            + text(680, "after")
        #expect(runs(source).map(\.mcid) == [nil, 4, nil])
    }

    @Test func theInnermostIdWins() {
        let source =
            "/Sect << /MCID 1 >> BDC " + text(720, "outer") + "/Span << /MCID 2 >> BDC "
            + text(700, "inner") + "EMC " + text(680, "again") + "EMC"
        #expect(runs(source).map(\.mcid) == [1, 2, 1])
    }

    @Test func aBeginMarkedContentCarriesNoIdOfItsOwn() {
        // `BMC` has no property dictionary, so content under it still belongs
        // to whatever enclosing element declared an id.
        let source =
            "/Sect << /MCID 5 >> BDC /Artifact BMC " + text(700, "under") + "EMC EMC"
        #expect(runs(source).map(\.mcid) == [5])
        // With nothing enclosing it, there is no id at all.
        #expect(runs("/Artifact BMC " + text(700, "artifact") + "EMC").map(\.mcid) == [nil])
    }

    @Test func aDictionaryWithoutAnIdKeyContributesNothing() {
        let source = "/Span << /Lang (en) >> BDC " + text(700, "untagged") + "EMC"
        #expect(runs(source).map(\.mcid) == [nil])
    }

    @Test func theSearchRunsOutwardsThroughEntriesWithoutIds() {
        // Only the outermost declares one, and two levels of nothing in
        // between do not hide it.
        let source =
            "/Sect << /MCID 20 >> BDC /Span << >> BDC /Span BMC " + text(700, "deep")
            + "EMC EMC EMC"
        #expect(runs(source).map(\.mcid) == [20])
    }

    @Test func propertiesGivenByNameYieldNoId() {
        // `/Span /P1 BDC` names an entry in the page's `/Properties`. Neither
        // the reference nor this port looks it up, so the content is
        // untagged — pinned because it looks like an oversight and is not
        // ours to fix.
        #expect(runs("/Span /P1 BDC " + text(700, "named") + "EMC").map(\.mcid) == [nil])
    }

    @Test func anUnbalancedEndDoesNotUnderflow() {
        #expect(runs("EMC EMC " + text(700, "after")).map(\.mcid) == [nil])
    }

    @Test func anUnclosedSectionRunsToTheEnd() {
        #expect(runs("/Span << /MCID 8 >> BDC " + text(700, "unclosed")).map(\.mcid) == [8])
    }

    @Test func siblingSectionsEachKeepTheirOwnId() {
        let source =
            "/Span << /MCID 10 >> BDC " + text(720, "one") + "EMC "
            + "/Span << /MCID 11 >> BDC " + text(700, "two") + "EMC "
            + "/Span << /MCID 12 >> BDC " + text(680, "three") + "EMC"
        #expect(runs(source).map(\.mcid) == [10, 11, 12])
    }

    @Test func theIdSurvivesIntoLayoutItems() {
        let source = "/Span << /MCID 3 >> BDC " + text(700, "tagged") + "EMC"
        #expect(pdfLayoutItems(runs(source)).map(\.mcid) == [3])
    }

    @Test func arrayShowsAlsoCarryTheId() {
        // The second emission point — `TJ` — has to tag its runs too.
        let source = "/Span << /MCID 6 >> BDC BT /F1 12 Tf 100 700 Td [(a) -200 (b)] TJ ET EMC"
        #expect(runs(source).allSatisfy { $0.mcid == 6 })
    }
}
