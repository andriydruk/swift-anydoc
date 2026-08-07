// Ported from src/model/list.rs, src/shared/text.rs, and
// src/render/markdown/anchors.rs tests.
import Testing
@testable import AnyDoc

@Suite struct ListMarkerTests {
    @Test func labelsCoverTheMarkerKinds() {
        #expect(MarkerKind.decimal.label(7) == "7.")
        #expect(MarkerKind.lowerAlpha.label(3) == "c.")
        #expect(MarkerKind.lowerAlpha.label(27) == "aa.")
        #expect(MarkerKind.upperAlpha.label(2) == "B.")
        #expect(MarkerKind.lowerRoman.label(4) == "iv.")
        #expect(MarkerKind.lowerRoman.label(1994) == "mcmxciv.")
        #expect(MarkerKind.upperRoman.label(9) == "IX.")
    }
}

@Suite struct CleanTextTests {
    @Test func joinControlsPreserved() {
        #expect(cleanText("می\u{200c}خواهم") == "می\u{200c}خواهم")
        #expect(cleanText("👨\u{200d}👩\u{200d}👧") == "👨\u{200d}👩\u{200d}👧")
    }

    @Test func layoutInvisiblesStripped() {
        #expect(cleanText("a\u{ad}b\u{200b}c\u{feff}d\u{a0}e") == "abcd e")
    }

    @Test func lineBreaksBecomeSpaces() {
        #expect(cleanText("a\r\nb\rc\nd") == "a b c d")
        #expect(cleanText("keep\ttab") == "keep\ttab")
    }
}

@Suite struct SlugTests {
    @Test func slugsKeepWordFormingCharacters() {
        #expect(gfmSlug("Hello World!") == "hello-world")
        #expect(gfmSlug("  leading and trailing  ") == "leading-and-trailing")
        #expect(gfmSlug("under_score and hy-phen") == "under_score-and-hy-phen")
        #expect(gfmSlug("C++ & Rust") == "c--rust")
        #expect(gfmSlug("étude précomposée") == "étude-précomposée")
        #expect(gfmSlug("combining n\u{0303} tilde") == "combining-n\u{0303}-tilde")
        #expect(gfmSlug("देवनागरी क्षि") == "देवनागरी-क्षि")
        #expect(gfmSlug("日本語の見出し") == "日本語の見出し")
    }

    @Test func connectorPunctuationIsKept() {
        #expect(gfmSlug("a‿b undertie") == "a‿b-undertie")
        #expect(gfmSlug("a⁀b tie") == "a⁀b-tie")
        #expect(gfmSlug("a＿b fullwidth") == "a＿b-fullwidth")
    }

    @Test func punctuationAndSymbolsDrop() {
        #expect(gfmSlug("quotes 'single' \"double\"") == "quotes-single-double")
        #expect(gfmSlug("copyright © and € and ∑") == "copyright--and--and-")
        #expect(gfmSlug("parens (and) [brackets]") == "parens-and-brackets")
    }

    @Test func emptySlugsBecomeSection() {
        #expect(gfmSlug("!!!") == "section")
        #expect(gfmSlug("") == "section")
    }

    @Test func duplicateSlugsGetNumericSuffixes() {
        var ids = UniqueIds()
        #expect(ids.claim(gfmSlug("dup")) == "dup")
        #expect(ids.claim(gfmSlug("dup")) == "dup-1")
        #expect(ids.claim(gfmSlug("dup")) == "dup-2")
    }
}

@Suite struct ErrorCodeTests {
    @Test func codesNameEveryVariant() {
        #expect(ConvertError.unsupported("").code == "unsupported")
        #expect(ConvertError.malformed("").code == "malformed")
        #expect(ConvertError.malformedPart("word/document.xml", "").code == "malformed")
        #expect(ConvertError.encrypted.code == "encrypted")
        #expect(ConvertError.resourceLimit(limit: "max_entry_bytes", detail: "").code == "resourceLimit")
        #expect(ConvertError.missingPart(part: "").code == "missingPart")
        #expect(ConvertError.io(IOError(errno: 2, detail: "No such file or directory")).code == "io")
    }
}
