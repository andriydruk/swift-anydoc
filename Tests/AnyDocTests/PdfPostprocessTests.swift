import Testing

@testable import AnyDoc

/// The Markdown cleanup passes. The differential probe proves equivalence
/// with the reference across tens of thousands of strings; these spell out
/// what each pass is *for*, and pin the two behaviours that look like bugs
/// and are deliberate.
@Suite struct PdfPostprocessTests {
    @Test func doubledSpacesCollapseWithinLines() {
        #expect(pdfCollapseConsecutiveSpaces("Vice  President") == "Vice President")
        // Leading indentation is preserved; only inner runs collapse.
        #expect(pdfCollapseConsecutiveSpaces("    a  b") == "    a b")
    }

    /// The reference guards its newline separator on "has anything been
    /// written yet" rather than "is this the first line", so leading blank
    /// lines disappear while interior ones survive. Reproduced deliberately.
    @Test func leadingBlankLinesVanish() {
        #expect(pdfCollapseConsecutiveSpaces("\nabc") == "abc")
        #expect(pdfCollapseConsecutiveSpaces("\n\n\n") == "")
        #expect(pdfCollapseConsecutiveSpaces("a\n\nb") == "a\n\nb")
    }

    @Test func strandedPunctuationRejoinsItsWord() {
        #expect(pdfRemoveSpacesBeforeSentencePunctuation("word .") == "word.")
        #expect(pdfRemoveSpacesBeforeSentencePunctuation("a , b") == "a, b")
        #expect(pdfRemoveSpacesBeforeSentencePunctuation("cell . | next") == "cell. | next")
        // Dot leaders and ellipses are left alone.
        #expect(pdfRemoveSpacesBeforeSentencePunctuation("see ... more") == "see ... more")
        // Mid-token punctuation is not a sentence end.
        #expect(pdfRemoveSpacesBeforeSentencePunctuation("3 .14") == "3 .14")
    }

    @Test func spacesBeforeClosingBracketsGo() {
        #expect(pdfRemoveSpacesBeforeClosingBrackets("[link ]") == "[link]")
        // Only one space is removed per bracket, as in the reference.
        #expect(pdfRemoveSpacesBeforeClosingBrackets("a  ]") == "a ]")
    }

    @Test func spacedHyphensCloseUpBetweenLetters() {
        #expect(pdfFixHyphenation("compound - word") == "compound-word")
        // A list marker has no letter before it, so it survives.
        #expect(pdfFixHyphenation("- list item") == "- list item")
        // Matches do not overlap, so the middle letter cannot start a second
        // match — `a - b - c` fixes the first hyphen only.
        #expect(pdfFixHyphenation("a - b - c") == "a-b - c")
    }

    @Test func dotLeadersCollapseGreedily() {
        #expect(pdfCollapseDotLeaders("Intro....1") == "Intro ... 1")
        // Six dots are one match, not four plus two.
        #expect(pdfCollapseDotLeaders("a......b") == "a ... b")
        // Three is an ellipsis.
        #expect(pdfCollapseDotLeaders("a...b") == "a...b")
    }

    @Test func standalonePageNumbersAreRecognised() {
        for line in ["1", "42", "1234", "Page 3", "Page 3 of 9", "3 of 12", "- 7 -", "page  of"] {
            #expect(pdfIsPageNumberLine(line), "\(line) should read as a page number")
        }
        for line in ["12345", "Introduction", "1.2 Scope", ""] {
            #expect(!pdfIsPageNumberLine(line), "\(line) should not read as a page number")
        }
    }

    /// Only an isolated page number is dropped — one inside a paragraph is
    /// part of the prose.
    @Test func pageNumbersGoOnlyWhenIsolated() {
        #expect(pdfRemovePageNumbers("para\n\n7\n\npara") == "para\n\n\npara")
        #expect(pdfRemovePageNumbers("para\n7\npara") == "para\n7\npara")
        #expect(pdfRemovePageNumbers("para\n7\n---") == "para\n---")
    }

    @Test func bareUrlsBecomeLinks() {
        #expect(
            pdfFormatUrls("see https://example.test/a here")
                == "see [https://example.test/a](https://example.test/a) here")
        // Trailing sentence punctuation stays outside the link.
        #expect(
            pdfFormatUrls("see https://example.test/a.")
                == "see [https://example.test/a](https://example.test/a).")
        // Already-linked URLs are left alone.
        let linked = "[text](https://example.test/a)"
        #expect(pdfFormatUrls(linked) == linked)
    }

    /// The whole pass, in the reference's order.
    @Test func theCleanupPassComposes() {
        let input = "Title\n\n\n\nSome  text with a stray .\n\n7\n\ncompound - word\n"
        #expect(pdfCleanMarkdown(input) == "Title\n\nSome text with a stray.\n\ncompound-word\n")
    }
}
