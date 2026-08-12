import Testing

@testable import AnyDoc

/// The markdown-level text-quality detectors, pinned without the oracle.
@Suite struct PdfTextQualityTests {
    private let english =
        "the quick brown fox jumps over the lazy dog while the committee "
        + "reviewed every certificate and signed the report "

    /// Rotate the alphabet within itself: a substitution cipher that stays in
    /// the same case block.
    private func shifted(_ text: String, by amount: UInt32) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x61 && scalar.value <= 0x7A {
                out.append(Unicode.Scalar((scalar.value - 0x61 + amount) % 26 + 0x61)!)
            } else if scalar.value >= 0x41 && scalar.value <= 0x5A {
                out.append(Unicode.Scalar((scalar.value - 0x41 + amount) % 26 + 0x41)!)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Shift down through the printable range, so lowercase lands in the
    /// uppercase block — what a broken CMap actually produces.
    private func straddled(_ text: String, by amount: UInt32) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x61 && scalar.value <= 0x7A {
                out.append(Unicode.Scalar(scalar.value - amount)!)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    private func repeated(_ text: String, _ times: Int) -> String {
        String(repeating: text, count: times)
    }

    // MARK: replacement characters and dollars

    @Test func anyReplacementCharacterIsAnIssue() {
        #expect(pdfDetectEncodingIssues("a replacement lurks here: \u{FFFD}"))
        #expect(!pdfDetectEncodingIssues("clean text with no problems"))
    }

    @Test func dollarsBetweenLettersAreABrokenCMap() {
        #expect(pdfHasDollarAsSpacePattern(repeated("a$b ", 25)))
        #expect(pdfDetectEncodingIssues(repeated("a$b ", 25)))
    }

    @Test func aPriceListIsNotABrokenCMap() {
        let prices =
            "price $10 and $20 and $30 and $40 and $50 and $60 and $70 and $80 "
            + "and $90 and $100 and $110 and $120"
        #expect(!pdfHasDollarAsSpacePattern(prices))
    }

    @Test func tenDollarsOrFewerNeverTrigger() {
        // The pattern needs more than ten dollar signs before it looks at
        // them at all, however suggestive they are.
        #expect(!pdfHasDollarAsSpacePattern(repeated("a$b ", 10)))
        #expect(pdfHasDollarAsSpacePattern(repeated("a$b ", 11)))
    }

    // MARK: the cipher discriminator

    private func stats(_ text: String) -> PdfCipherGarbleStats {
        var stats = PdfCipherGarbleStats()
        stats.add(text)
        return stats
    }

    @Test func cleanEnglishIsNotGarbled() {
        #expect(!stats(repeated(english, 4)).looksGarbled())
        #expect(!pdfDetectEncodingIssues(repeated(english, 4)))
    }

    @Test func aShiftedAlphabetIsCaught() {
        // The letters are a permutation of English: the same frequency shape,
        // the wrong positions.
        let garbled = shifted(repeated(english, 4), by: 7)
        #expect(stats(garbled).looksGarbled())
        #expect(pdfDetectEncodingIssues(garbled))
    }

    @Test func aCaseStraddlingShiftIsCaught() {
        let garbled = straddled(repeated(english, 4), by: 30)
        #expect(stats(garbled).looksGarbled())
    }

    @Test func twoHundredLettersAreNeededBeforeAnyVerdict() {
        // Below the floor the statistics mean nothing, so nothing is claimed.
        let short = String(shifted(repeated(english, 4), by: 7).prefix(150))
        #expect(!stats(short).looksGarbled())
    }

    @Test func vowelsAboveThirtyPercentClearThePage() {
        // Real Latin-script text keeps vowels up even when acronym-heavy, so
        // this exits before either signal is consulted.
        let vowelRich = repeated("aeiou", 100)
        #expect(stats(vowelRich).looksGarbled() == false)
    }

    @Test func nonLatinDominantTextIsLeftAlone() {
        let japanese = repeated("日本語のテキストがここにあります", 30)
        #expect(!stats(japanese).looksGarbled())
    }

    @Test func dnaAndHexDumpsAreNotRoutedToOcr() {
        // Unlike English, but with a profile too steep to be a permutation of
        // it — the shape half of the second signal is what saves them.
        #expect(!stats(repeated("ACGT", 300)).looksGarbled())
        #expect(!stats(repeated("0123456789abcdef", 60)).looksGarbled())
    }

    @Test func camelCaseIdentifiersAreNotCaseShiftGarble() {
        #expect(!stats(repeated("camelCaseIdentifier ", 60)).looksGarbled())
    }

    @Test func emptyTextScoresAPerfectCosine() {
        // Nothing is condemned for having no letters.
        #expect(stats("").englishCosine() == 1.0)
        #expect(stats("").englishShapeCosine() == 1.0)
        #expect(!pdfDetectEncodingIssues(""))
    }

    @Test func bigramsCountOnlyInsideRunsOfLetters() {
        // The chain resets at every non-ASCII-letter character, so a word
        // boundary is not a bigram.
        #expect(stats("abc").letterBigrams == 2)
        #expect(stats("a b c").letterBigrams == 0)
        #expect(stats("aB").caseShiftBigrams == 1)
        #expect(stats("Ab").caseShiftBigrams == 0)
    }

    @Test func accentedLatinCountsSeparatelyFromOtherScripts() {
        let sample = stats("naïve café 日本")
        #expect(sample.latinExtendedLetters == 2)
        #expect(sample.nonLatinLetters == 2)
        // n,a,v,e + c,a,f — the accented letters are not ASCII.
        #expect(sample.asciiLetters == 7)
    }
}
