import Testing

@testable import AnyDoc

/// NFKC and ligature expansion, pinned without the oracle.
@Suite struct PdfNfkcTests {
    // MARK: normalisation

    @Test func compatibilityFormsAreFolded() {
        #expect(pdfNfkc("\u{FB01}") == "fi")
        #expect(pdfNfkc("\u{FF21}") == "A")  // fullwidth A
        #expect(pdfNfkc("\u{00BD}") == "1\u{2044}2")  // one half
    }

    @Test func marksComposeOntoTheirStarter() {
        #expect(pdfNfkc("e\u{0301}") == "\u{00E9}")
        #expect(pdfNfkc("\u{00E9}") == "\u{00E9}")
    }

    @Test func multiplyAccentedLettersComposeInSteps() {
        // U+01D5 decomposes to three scalars but composes from two — the
        // pair table has to come from the one-step decomposition, which is
        // what a first attempt at the generator got wrong.
        #expect(pdfNfkc("U\u{0308}\u{0304}") == "\u{01D5}")
        #expect(pdfNfkc("\u{01D5}") == "\u{01D5}")
    }

    @Test func marksAreOrderedByCombiningClass() {
        // A cedilla (202) sorts before an acute (230) whatever order they
        // arrive in, so both spellings normalise alike.
        #expect(pdfNfkc("a\u{0301}\u{0327}") == pdfNfkc("a\u{0327}\u{0301}"))
    }

    @Test func equalClassMarksKeepTheirOrder() {
        // Two marks of the same class do not commute, so these stay distinct.
        #expect(pdfNfkc("a\u{0301}\u{0308}") != pdfNfkc("a\u{0308}\u{0301}"))
    }

    @Test func anInterveningMarkBlocksComposition() {
        // `q` has no precomposed form with a dot above, so the dot stays a
        // separate mark — and being of the same class as the acute, it then
        // stands between the acute and the starter and blocks it too. Three
        // scalars out.
        #expect(pdfNfkc("q\u{0307}\u{0301}").unicodeScalars.count == 3)
        // Where the first mark *does* compose, the second is no longer
        // blocked by it but simply has no pair of its own.
        #expect(pdfNfkc("a\u{0325}\u{0301}").unicodeScalars.map(\.value) == [0x1E01, 0x301])
        // And where both steps have pairs, everything collapses to one.
        #expect(pdfNfkc("o\u{0328}\u{0304}").unicodeScalars.map(\.value) == [0x1ED])
    }

    @Test func hangulIsHandledArithmetically() {
        // Jamo compose into a syllable, and a syllable is already normal.
        #expect(pdfNfkc("\u{1100}\u{1161}") == "\u{AC00}")
        #expect(pdfNfkc("\u{1100}\u{1161}\u{11A8}") == "\u{AC01}")
        #expect(pdfNfkc("\u{AC00}") == "\u{AC00}")
    }

    @Test func normalisationIsIdempotent() {
        for sample in ["e\u{0301}", "\u{FB03}", "U\u{0308}\u{0304}", "\u{1100}\u{1161}"] {
            #expect(pdfNfkc(pdfNfkc(sample)) == pdfNfkc(sample))
        }
    }

    @Test func plainTextIsUntouched() {
        #expect(pdfNfkc("") == "")
        #expect(pdfNfkc("ordinary words") == "ordinary words")
    }

    @Test func combiningClassesComeFromTheTable() {
        #expect(pdfCombiningClass(0x0301) == 230)
        #expect(pdfCombiningClass(0x0327) == 202)
        #expect(pdfCombiningClass(0x0041) == 0)
    }

    // MARK: ligature expansion

    @Test func latinLigaturesExpandExplicitly() {
        #expect(pdfExpandLigatures("of\u{FB01}ce") == "office")
        #expect(pdfExpandLigatures("\u{FB00}\u{FB02}\u{FB03}\u{FB04}") == "ffflffiffl")
        #expect(pdfExpandLigatures("\u{FB05}\u{FB06}") == "stst")
    }

    @Test func invisibleCharactersAreStripped() {
        for invisible in ["\u{00AD}", "\u{200B}", "\u{FEFF}", "\u{200C}", "\u{200D}", "\u{2060}"]
        {
            #expect(pdfExpandLigatures("a\(invisible)b") == "ab")
        }
    }

    @Test func typographicSpacesBecomeOrdinaryOnes() {
        #expect(pdfExpandLigatures("a\u{2000}b\u{2009}c") == "a b c")
    }

    @Test func theNonBreakingSpaceSurvives() {
        // Downstream spacing depends on it being distinct, which is exactly
        // why NFKC is not applied to everything.
        #expect(pdfExpandLigatures("a\u{00A0}b") == "a\u{00A0}b")
    }

    @Test func controlCharactersAreRemovedButWhitespaceIsKept() {
        #expect(pdfExpandLigatures("a\u{0000}b\u{0001}c") == "abc")
        #expect(pdfExpandLigatures("a\tb\nc\rd") == "a\tb\nc\rd")
    }

    @Test func arabicPresentationFormsAreNormalisedAndReversed() {
        // The forms fold to base letters, and the text was in visual order,
        // so the result is reversed.
        let expanded = pdfExpandLigatures("\u{FB50}\u{FE70}")
        #expect(!expanded.unicodeScalars.contains(where: pdfIsArabicPresentationForm))
        #expect(!expanded.isEmpty)
    }

    @Test func arabicWithoutPresentationFormsIsLeftAlone() {
        // No forms means the text was already in logical order.
        let arabic = "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}"
        #expect(pdfExpandLigatures(arabic) == arabic)
    }
}
