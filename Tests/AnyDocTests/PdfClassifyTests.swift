import Testing

@testable import AnyDoc

/// The reference's own assertions for `markdown/classify.rs`, plus the
/// quirks this port had to reproduce deliberately.
@Suite struct PdfClassifyTests {

    // MARK: list items

    @Test func bulletsAndNumbersAreListItems() {
        for text in ["• Item one", "- Item two", "* Item three", "● Item", "○ x", "◦ x"] {
            #expect(pdfIsListItem(text), "\(text) should be a list item")
        }
        for text in ["1. First", "2) Second", "10. Tenth", "a. Letter item", "b) Letter", "(a) Paren"] {
            #expect(pdfIsListItem(text), "\(text) should be a list item")
        }
        #expect(!pdfIsListItem("Regular text"))
    }

    /// A bullet with no space after it is not a list item — the reference
    /// matches on `"• "`, space included.
    @Test func aBulletNeedsItsSpace() {
        #expect(!pdfIsListItem("•Item"))
        #expect(!pdfStartsWithBulletMarker("•Item"))
    }

    /// Only the first five characters are searched for the delimiter, so a
    /// number further into the line does not make a list.
    @Test func onlyTheFirstFiveCharactersCount() {
        #expect(!pdfIsListItem("Section 1. Introduction"))
        #expect(pdfIsListItem("12345. x") == false)  // delimiter is the 6th
        #expect(pdfIsListItem("1234. x"))
    }

    /// A leading delimiter with a digit behind it passes, because the
    /// reference tests `all()` over the empty run before the delimiter and
    /// an empty `all()` is true. Reproduced, not fixed.
    @Test func aLeadingDelimiterPassesAsTheReferenceDoes() {
        #expect(pdfIsListItem(".5 something"))
    }

    /// A parenthesised single character qualifies whatever that character
    /// is: the reference only checks that the third one closes the paren.
    @Test func anyParenthesisedCharacterQualifies() {
        #expect(pdfIsListItem("(a) Alpha"))
        #expect(pdfIsListItem("(§) Section"))
    }

    @Test func bulletMarkersAreNarrowerThanListItems() {
        #expect(pdfStartsWithBulletMarker("• Item"))
        #expect(pdfStartsWithBulletMarker("- Item"))
        // Numbered forms are section headings as often as list items, so the
        // heading classifier must not see them here.
        #expect(!pdfStartsWithBulletMarker("1. First"))
        #expect(!pdfStartsWithBulletMarker("a) Alpha"))
    }

    // MARK: list formatting

    @Test func bulletsBecomeDashes() {
        #expect(pdfFormatListItem("● Item") == "- Item")
        #expect(pdfFormatListItem("• Item") == "- Item")
        #expect(pdfFormatListItem("- Item") == "- Item")
        #expect(pdfFormatListItem("- existing") == "- existing")
        #expect(pdfFormatListItem("1. First") == "1. First")
    }

    /// A bullet inside a style run has to come out of the wrapper, or
    /// Markdown never sees a list.
    @Test func aBulletMovesOutOfItsStyleRun() {
        #expect(pdfFormatListItem("<u>● Item text</u>") == "- <u>Item text</u>")
        #expect(
            pdfFormatListItem("**● Fraud: Willing cooperation;**")
                == "- **Fraud: Willing cooperation;**")
        #expect(pdfFormatListItem("**● Label:** rest of line") == "- **Label:** rest of line")
        #expect(pdfFormatListItem("*● Italic:* rest") == "- *Italic:* rest")
    }

    /// The bullet is stripped without requiring a space, and what follows is
    /// trimmed — so a bullet run on its own collapses.
    @Test func aBareBulletFormatsToAnEmptyItem() {
        #expect(pdfFormatListItem("•") == "- ")
    }

    // MARK: captions

    @Test func captionsNeedAReferenceAfterFigureOrTable() {
        #expect(pdfIsCaptionLine("Figure 1: The pipeline"))
        #expect(pdfIsCaptionLine("Table 2.1"))
        #expect(pdfIsCaptionLine("FIGURE 3 — results"))
        #expect(pdfIsCaptionLine("Figure (a)"))
        #expect(pdfIsCaptionLine("Table #4"))
        // Without one, these are ordinary headings.
        #expect(!pdfIsCaptionLine("Table of Contents"))
        #expect(!pdfIsCaptionLine("Figure drawing for beginners"))
    }

    @Test func theAlwaysPrefixesMatchAlone() {
        for text in ["Source: BLS", "Fonte: IBGE", "Note: see appendix", "Fig. 2", "Gráfico 1"] {
            #expect(pdfIsCaptionLine(text), "\(text) should be a caption")
        }
        #expect(pdfIsCaptionLine("source: lowercase also matches"))
        #expect(!pdfIsCaptionLine("Sources of error"))
    }

    // MARK: code

    @Test func codeIsDetectedByKeywordsAndPunctuation() {
        #expect(pdfIsCodeLike("const x = 5;"))
        #expect(pdfIsCodeLike("function foo() {"))
        #expect(pdfIsCodeLike("import React from 'react'"))
        #expect(!pdfIsCodeLike("This is regular text."))
    }

    /// Three of `{}()[];=<>` is enough, which catches ordinary prose that
    /// happens to be punctuated that way. The reference accepts that and so
    /// does this port.
    @Test func punctuationAloneIsEnoughForTheReference() {
        #expect(pdfIsCodeLike("See (a), (b) and (c)"))
    }

    @Test func monospaceFontsAreRecognisedByName() {
        for name in ["Courier", "ABCDEF+Consolas-Bold", "JetBrainsMono-Regular", "DejaVu Sans Mono"]
        {
            #expect(pdfIsMonospaceFont(name), "\(name) should read as monospace")
        }
        #expect(!pdfIsMonospaceFont("Helvetica"))
    }

    // MARK: dot leaders

    @Test func dotLeadersNeedTwoGroupsOrFourInARow() {
        #expect(pdfHasDotLeaders("Chapter one .... 3"))
        #expect(pdfHasDotLeaders("A ... B ... 7"))
        // One group of exactly three is an ellipsis.
        #expect(!pdfHasDotLeaders("and so on ... then more"))
        #expect(!pdfHasDotLeaders("no dots here"))
    }

    // MARK: paragraph threshold

    /// Fewer than five gaps is not enough to call a median, so the fallback
    /// stands.
    @Test func tooFewGapsFallsBackToTheBodySize() {
        let lines = (0..<3).map { index in
            PdfTextLine(items: [], y: 700 - Float(index) * 12)
        }
        #expect(pdfParagraphThreshold(lines, bodySize: 10) == 18)
    }

    /// With enough gaps it is the median widened by a third, floored at one
    /// and a half body sizes.
    @Test func theThresholdIsTheWidenedMedianGap() {
        let lines = (0..<10).map { index in
            PdfTextLine(items: [], y: 700 - Float(index) * 20)
        }
        // Median gap 20 → 26, which clears the 15pt floor.
        #expect(pdfParagraphThreshold(lines, bodySize: 10) == 26)

        let tight = (0..<10).map { index in
            PdfTextLine(items: [], y: 700 - Float(index) * 10)
        }
        // Median 10 → 13, below the floor of 15.
        #expect(pdfParagraphThreshold(tight, bodySize: 10) == 15)
    }
}

/// The block loop: how classification, headings, lists and paragraphs
/// interact line by line.
@Suite struct PdfBlockLoopTests {
    /// A page of 12pt lines at a 14pt pitch, so the paragraph threshold
    /// settles near 18pt and a 40pt gap is unambiguously a break.
    private func lines(
        _ specification: [(String, Float, Float, Float, String)]
    ) -> [PdfTextLine] {
        specification.map { text, y, x, size, font in
            PdfTextLine(
                items: [
                    PdfLayoutItem(
                        text: text, x: x, y: y, width: Float(text.count) * size * 0.5,
                        fontSize: size, fontName: font)
                ], y: y)
        }
    }

    @Test func wrappedLinesJoinIntoOneParagraph() {
        var y: Float = 700
        var input: [(String, Float, Float, Float, String)] = []
        for text in ["The first line of prose", "wraps onto a second", "and then a third."] {
            input.append((text, y, 72, 12, "F"))
            y -= 14
        }
        let blocks = pdfBuildBlocks(lines(input))
        #expect(blocks == [.paragraph("The first line of prose wraps onto a second and then a third.")])
    }

    @Test func aLargeGapStartsANewParagraph() {
        let blocks = pdfBuildBlocks(
            lines([
                ("First paragraph here", 700, 72, 12, "F"),
                ("still the first one", 686, 72, 12, "F"),
                ("more of the first", 672, 72, 12, "F"),
                ("and yet more of it", 658, 72, 12, "F"),
                ("one more line still", 644, 72, 12, "F"),
                ("Second paragraph now", 560, 72, 12, "F"),
            ]))
        #expect(blocks.count == 2)
        #expect(blocks.last == .paragraph("Second paragraph now"))
    }

    @Test func listItemsGatherAndContinuationsJoinTheirItem() {
        let blocks = pdfBuildBlocks(
            lines([
                ("Intro line of prose", 700, 72, 12, "F"),
                ("• First item", 686, 72, 12, "F"),
                ("wrapped onto a second line", 672, 80, 12, "F"),
                ("• Second item", 658, 72, 12, "F"),
            ]))
        #expect(
            blocks == [
                .paragraph("Intro line of prose"),
                .list(["- First item wrapped onto a second line", "- Second item"]),
            ])
    }

    /// A line far to the left of the item's text is a new block, not a
    /// continuation of it.
    @Test func aLineOutdentedPastTheItemEndsTheList() {
        let blocks = pdfBuildBlocks(
            lines([
                ("• First item", 700, 200, 12, "F"),
                ("Back at the margin", 686, 72, 12, "F"),
            ]))
        #expect(blocks == [.list(["- First item"]), .paragraph("Back at the margin")])
    }

    @Test func captionsStandAlone() {
        let blocks = pdfBuildBlocks(
            lines([
                ("Some prose before", 700, 72, 12, "F"),
                ("Figure 1: the pipeline", 686, 72, 12, "F"),
                ("Some prose after", 672, 72, 12, "F"),
            ]))
        #expect(
            blocks == [
                .paragraph("Some prose before"),
                .caption("Figure 1: the pipeline"),
                .paragraph("Some prose after"),
            ])
    }

    @Test func monospaceLinesBecomeAFencedBlock() {
        let blocks = pdfBuildBlocks(
            lines([
                ("Explanation", 700, 72, 12, "F"),
                ("let x = 1", 686, 72, 12, "Courier"),
                ("let y = 2", 672, 72, 12, "Courier"),
                ("More prose", 658, 72, 12, "F"),
            ]))
        #expect(
            blocks == [
                .paragraph("Explanation"), .code(["let x = 1", "let y = 2"]),
                .paragraph("More prose"),
            ])
        #expect(pdfRenderMarkdown(blocks).contains("```\nlet x = 1\nlet y = 2\n```"))
    }

    /// Dot-leader lines are a contents list, so they break rather than run
    /// together into one long sentence.
    @Test func dotLeaderLinesBreakInsteadOfJoining() {
        let blocks = pdfBuildBlocks(
            lines([
                ("Chapter one .... 3", 700, 72, 12, "F"),
                ("Chapter two .... 9", 686, 72, 12, "F"),
            ]))
        #expect(blocks == [.paragraph("Chapter one .... 3\nChapter two .... 9")])
    }

    /// A bulleted line is never a heading, however large it is set.
    @Test func aBulletedLineIsNeverAHeading() {
        let blocks = pdfBuildBlocks(
            lines([
                ("Body text here", 700, 72, 10, "F"),
                ("More body text", 686, 72, 10, "F"),
                ("Still more body", 672, 72, 10, "F"),
                ("• A large bullet", 658, 72, 20, "F"),
            ]))
        #expect(blocks.contains { $0 == .list(["- A large bullet"]) })
        #expect(!blocks.contains { if case .heading = $0 { return true } else { return false } })
    }

    /// Too short, or too many words, and the font heuristic is not allowed to
    /// call it a heading.
    @Test func headingsAreGatedOnLengthAndWordCount() {
        func blocksFor(_ text: String) -> [PdfBlock] {
            pdfBuildBlocks(
                lines([
                    ("Body text here", 700, 72, 10, "F"),
                    ("More body text", 686, 72, 10, "F"),
                    ("Still more body", 672, 72, 10, "F"),
                    (text, 600, 72, 20, "F"),
                ]))
        }
        func hasHeading(_ blocks: [PdfBlock]) -> Bool {
            blocks.contains { if case .heading = $0 { return true } else { return false } }
        }
        #expect(hasHeading(blocksFor("A Real Heading")))
        #expect(!hasHeading(blocksFor("abc")), "three bytes is a fragment, not a heading")
        #expect(
            !hasHeading(blocksFor((1...16).map { "w\($0)" }.joined(separator: " "))),
            "sixteen words is prose, not a heading")
    }
}
