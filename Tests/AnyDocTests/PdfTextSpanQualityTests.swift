import Testing

@testable import AnyDoc

/// Span-level text-quality detection, pinned without the oracle.
@Suite struct PdfTextSpanQualityTests {
    private func repeated(_ text: String, _ times: Int) -> String {
        String(repeating: text, count: times)
    }

    // MARK: replacement characters

    @Test func replacementRunsNeedTwoAdjacentOrThreeTotal() {
        #expect(pdfHasReplacementTextRun("\u{FFFD}\u{FFFD}"))
        #expect(pdfHasReplacementTextRun("\u{FFFD} a \u{FFFD} b \u{FFFD}"))
        #expect(!pdfHasReplacementTextRun("\u{FFFD} a"))
        #expect(!pdfHasReplacementTextRun("\u{FFFD} a \u{FFFD}"))
    }

    @Test func replacementStatsCountBothTotalAndLongestRun() {
        let stats = pdfReplacementTextStats("a\u{FFFD}\u{FFFD}\u{FFFD}b\u{FFFD}")
        #expect(stats.replacements == 4)
        #expect(stats.longestRun == 3)
    }

    @Test func replacementsAreOnlyAWeakSignal() {
        // Strong issues condemn a span; replacement characters merely feed
        // the page's accumulated evidence.
        #expect(pdfTextSpanIssueKind("\u{FFFD}\u{FFFD}") == .replacement)
        #expect(pdfTextSpanIssueKind("ab\u{E000}\u{E001}\u{E002}cd") == .strong)
    }

    @Test func anEmptySpanHasNoIssue() {
        #expect(pdfTextSpanIssueKind("") == nil)
        #expect(pdfTextSpanIssueKind("   ") == nil)
        #expect(!pdfTextSpanHasDecodingIssue("ordinary words"))
    }

    // MARK: page-level replacement evidence

    @Test func aShortBrokenPageNeedsOnlyTwoAdjacentReplacements() {
        let evidence = PdfPageTextQualityEvidence(
            characters: 40, replacementCharacters: 2, replacementSpans: 1,
            longestReplacementRun: 2)
        #expect(pdfPageReplacementEvidenceNeedsOcr(evidence))
    }

    @Test func aTextHeavyPageNeedsDensityNotJustCount() {
        // A page thick with mathematics legitimately produces a few, and
        // forcing OCR on it would be worse than the damage.
        var evidence = PdfPageTextQualityEvidence(
            characters: 10_000, replacementCharacters: 12, replacementSpans: 1,
            longestReplacementRun: 2)
        #expect(!pdfPageReplacementEvidenceNeedsOcr(evidence))
        // The same count in a tenth of the text does qualify.
        evidence.characters = 200
        #expect(pdfPageReplacementEvidenceNeedsOcr(evidence))
    }

    @Test func repeatedSpansAndLongRunsAreTheOtherTwoRoutes() {
        let repeatedSpans = PdfPageTextQualityEvidence(
            characters: 200, replacementCharacters: 5, replacementSpans: 3,
            longestReplacementRun: 1)
        #expect(pdfPageReplacementEvidenceNeedsOcr(repeatedSpans))
        let longRun = PdfPageTextQualityEvidence(
            characters: 200, replacementCharacters: 8, replacementSpans: 1,
            longestReplacementRun: 8)
        #expect(pdfPageReplacementEvidenceNeedsOcr(longRun))
    }

    @Test func noReplacementsMeansNoEvidence() {
        #expect(
            !pdfPageReplacementEvidenceNeedsOcr(
                PdfPageTextQualityEvidence(characters: 100, replacementCharacters: 0)))
    }

    // MARK: private use

    @Test func threePrivateUseCharactersInARowAreEnough() {
        #expect(pdfHasPrivateUseTextRun("\u{E000}\u{E001}\u{E002}"))
        #expect(!pdfHasPrivateUseTextRun("\u{E000}\u{E001}"))
    }

    @Test func aMajorityOfPrivateUseAlsoQualifies() {
        // Five characters or more, at least two private-use, and half of them.
        #expect(pdfHasPrivateUseTextRun("a\u{E000}b\u{E001}\u{E002}"))
        #expect(!pdfHasPrivateUseTextRun("abcd\u{E000}efgh\u{E001}"))
    }

    @Test func whitespaceBreaksTheRunButNotTheMajority() {
        // Spaced-out damage reads as three runs of one rather than a run of
        // three — so the run rule does not fire, but half the non-whitespace
        // characters are private-use and the majority rule does.
        #expect(pdfHasPrivateUseTextRun("x\u{E000} y\u{E001} z\u{E002}"))
        // Dilute it and neither rule applies.
        #expect(!pdfHasPrivateUseTextRun("xx\u{E000} yy\u{E001} zz\u{E002}"))
    }

    @Test func allThreePrivateUseAreasCount() {
        #expect(pdfIsPrivateUseScalar("\u{E000}"))
        #expect(pdfIsPrivateUseScalar("\u{F0000}"))
        #expect(pdfIsPrivateUseScalar("\u{100000}"))
        #expect(!pdfIsPrivateUseScalar("a"))
    }

    // MARK: C1 controls

    @Test func aTokenThickWithControlsIsCidDamage() {
        #expect(pdfTokenHasCidControl("ab\u{80}\u{81}cd"))
        // One control is not enough, whatever the length.
        #expect(!pdfTokenHasCidControl("ab\u{80}cdef"))
        // Nor is a token under five characters.
        #expect(!pdfTokenHasCidControl("a\u{80}\u{81}"))
    }

    @Test func anyTokenOnTheLineCanTriggerIt() {
        #expect(pdfHasCidControlToken("clean words then ab\u{80}\u{81}cd"))
        #expect(!pdfHasCidControlToken("clean words throughout"))
    }

    // MARK: garbage text

    @Test func symbolSoupIsGarbage() {
        #expect(pdfIsGarbageText(repeated("!?,;:()", 12)))
        #expect(pdfIsGarbageText(repeated("@@@!!!???$$$%%%^^^&&&(((", 3)))
    }

    @Test func theReferencesOwnExampleNoLongerTriggersIt() {
        // The doc comment cites `----1-.-.-.___  --.-. .._ I_---.` as the
        // motivating case, but hyphens are on the Markdown-syntax skip list
        // and underscore runs are decorative leaders, so almost nothing in it
        // is counted and it falls under the fifty-character floor. Verified
        // against the reference, which agrees — this is upstream behaviour
        // drifting from its own documentation, not a porting error.
        #expect(!pdfIsGarbageText(repeated("----1-.-.-.___  --.-. .._ I_---.", 3)))
    }

    @Test func aTableOfContentsLeaderIsLayoutNotDamage() {
        // Three or more dots in a row are skipped entirely, so a leader does
        // not drag the ratio down.
        #expect(!pdfIsGarbageText("Chapter one" + repeated(".", 40) + "7"))
    }

    @Test func markdownSyntaxIsNeverCountedAgainstThePdf() {
        // These characters are ours, not the document's.
        #expect(!pdfIsGarbageText(repeated("#", 60)))
        #expect(!pdfIsGarbageText(repeated("*|-#", 30)))
    }

    @Test func fiftyCharactersAreNeededBeforeAnyVerdict() {
        #expect(!pdfIsGarbageText("-.-.-.!!!"))
    }

    @Test func nonAsciiNumeralsCountAsAlphanumeric() {
        // Rust's `is_alphanumeric` is by general category, not ASCII digits.
        #expect(pdfIsAlphanumericScalar("Ⅳ"))
        #expect(pdfIsAlphanumericScalar("½"))
        #expect(pdfIsAlphanumericScalar("٣"))
        #expect(!pdfIsAlphanumericScalar("·"))
    }

    // MARK: CID garbage

    @Test func c1ControlsAloneMarkCidGarbage() {
        #expect(pdfIsCidGarbage("abcde\u{80}\u{81}"))
    }

    @Test func highLatinWithoutAsciiLettersIsMojibake() {
        // CID values in 0x80…0xFF reinterpreted as accented Latin, which is
        // what a CJK document does when its mapping fails.
        let mojibake = String((0..<60).map { Character(Unicode.Scalar(0xC0 + UInt32($0 % 48))!) })
        #expect(pdfIsCidGarbage(mojibake))
        // The same with plenty of ASCII letters is ordinary Western text.
        #expect(!pdfIsCidGarbage(mojibake + repeated("abcdefghij", 3)))
    }

    @Test func shortSpansAreNeverCidGarbage() {
        #expect(!pdfIsCidGarbage("2×()×"))
    }
}
