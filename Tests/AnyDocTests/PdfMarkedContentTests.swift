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

    // MARK: ActualText

    @Test func aDeclaredTextReplacesTheGlyphsThatDrewIt() {
        // The section says what the text really is; the glyphs are whatever
        // the font happened to draw, and are not extracted at all.
        let result = runs("/Span << /ActualText (fi) >> BDC " + text(700, "XY") + "EMC")
        #expect(result.map(\.text) == ["fi"])
    }

    @Test func aDeclaredTextTakesTheSectionsOwnId() {
        let source = "/Span << /ActualText (lig) /MCID 9 >> BDC " + text(700, "XY") + "EMC"
        #expect(runs(source).map(\.mcid) == [9])
    }

    @Test func theFirstGlyphsPositionIsPreferredToTheSections() {
        // A `Td` between the `BDC` and the first glyph may have moved to the
        // right line, leaving the `BDC` position on the previous one.
        let source =
            "/Span << /ActualText (moved) >> BDC BT /F1 12 Tf 100 760 Td 0 -60 Td (XY) Tj ET EMC"
        #expect(runs(source).first?.y == 700)
    }

    @Test func aSectionWithNoGlyphsStillEmits() {
        // Nothing was drawn, so the `BDC` position is all there is.
        let result = runs("/Span << /ActualText (alone) >> BDC EMC")
        #expect(result.map(\.text) == ["alone"])
    }

    @Test func whitespaceOnlyDeclaredTextIsDropped() {
        #expect(runs("/Span << /ActualText ( ) >> BDC " + text(700, "XY") + "EMC").isEmpty)
    }

    @Test func textOutsideTheSectionIsUnaffected() {
        let source =
            text(720, "before") + "/Span << /ActualText (middle) >> BDC " + text(700, "XY")
            + "EMC " + text(680, "after")
        #expect(runs(source).map(\.text) == ["before", "middle", "after"])
    }

    @Test func nestedSectionsEmitInnermostFirst() {
        // Each closes at its own `EMC`, so the inner one is emitted first —
        // and the glyphs between them belong to neither.
        let source =
            "/Span << /ActualText (outer) >> BDC " + text(720, "AB")
            + "/Span << /ActualText (inner) >> BDC " + text(700, "CD") + "EMC "
            + text(680, "EF") + "EMC"
        #expect(runs(source).map(\.text) == ["inner", "outer"])
    }

    @Test func theOuterSectionInheritsTheLastCapturedPosition() {
        // The position state is a single slot rather than one per level, so
        // an inner section resets it and the outer one ends up reporting
        // wherever the glyphs after the inner section sat. Pinned because it
        // looks like a bug and is reproduced deliberately.
        let source =
            "/Span << /ActualText (outer) >> BDC " + text(720, "AB")
            + "/Span << /ActualText (inner) >> BDC " + text(700, "CD") + "EMC "
            + text(680, "EF") + "EMC"
        let result = runs(source)
        #expect(result.first(where: { $0.text == "outer" })?.y == 680)
    }

    @Test func declaredTextIsPutThroughLigatureExpansion() {
        // A PDF literal string is a *byte* string, so the ligature has to be
        // given as UTF-16BE with a byte-order mark — writing U+FB01 into a
        // Swift source literal would put its UTF-8 bytes in the stream and
        // they would decode as Latin-1 mojibake, which is what a first
        // attempt at this test did.
        var bytes = Array("/Span << /ActualText (".utf8)
        // o, f, U+FB01 (fi), c, e — which expands back to "office".
        bytes += [0xFE, 0xFF, 0x00, 0x6F, 0x00, 0x66, 0xFB, 0x01, 0x00, 0x63, 0x00, 0x65]
        bytes += Array((") >> BDC " + text(700, "XY") + "EMC").utf8)
        let result = pdfExtractTextRuns(pdfParseContentStream(bytes)) { _, raw in
            String(decoding: raw, as: UTF8.self)
        }
        #expect(result.map(\.text) == ["office"])
    }

    @Test func arrayShowsAlsoCarryTheId() {
        // The second emission point — `TJ` — has to tag its runs too.
        let source = "/Span << /MCID 6 >> BDC BT /F1 12 Tf 100 700 Td [(a) -200 (b)] TJ ET EMC"
        #expect(runs(source).allSatisfy { $0.mcid == 6 })
    }
}
