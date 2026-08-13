import Testing

@testable import AnyDoc

/// Single-byte decoding fallbacks, pinned without the oracle.
@Suite struct PdfSingleByteDecodeTests {
    @Test func withoutTheWindowsReadingAByteIsItsOwnValue() {
        for byte: UInt8 in [0x41, 0x80, 0x92, 0xFF] {
            #expect(pdfDecodeSingleByte(byte, useCp1252: false).value == UInt32(byte))
        }
    }

    @Test func onlyTheControlRangeDiffers() {
        #expect(pdfDecodeSingleByte(0x80, useCp1252: true) == "\u{20AC}")
        #expect(pdfDecodeSingleByte(0x92, useCp1252: true) == "\u{2019}")
        // Outside 0x80–0x9F the byte is its own value either way.
        #expect(pdfDecodeSingleByte(0x41, useCp1252: true) == "A")
        #expect(pdfDecodeSingleByte(0xE9, useCp1252: true).value == 0xE9)
    }

    @Test func theUnassignedCodepageSlotsFallThrough() {
        // 0x81, 0x8D, 0x8F, 0x90 and 0x9D have no Windows-1252 meaning, so
        // they keep their Latin-1 value rather than being rejected.
        for byte: UInt8 in [0x81, 0x8D, 0x8F, 0x90, 0x9D] {
            #expect(pdfDecodeSingleByte(byte, useCp1252: true).value == UInt32(byte))
        }
    }

    @Test func controlsAreReDecodedAfterTheFact() {
        // Text from a `/ToUnicode` map can still land in the C1 block.
        #expect(pdfNormaliseCp1252Controls("a\u{0092}b", useCp1252: true) == "a\u{2019}b")
        #expect(pdfNormaliseCp1252Controls("a\u{0092}b", useCp1252: false) == "a\u{0092}b")
        #expect(pdfNormaliseCp1252Controls("plain", useCp1252: true) == "plain")
    }

    // MARK: which fonts get the Windows reading

    @Test func mostFontsDo() {
        #expect(pdfShouldUseCp1252(baseFontName: "Helvetica", isType0CidFont: false))
        #expect(pdfShouldUseCp1252(baseFontName: "ABCDEF+Helvetica", isType0CidFont: false))
        // A font with no name does too: the guess is right more often than not.
        #expect(pdfShouldUseCp1252(baseFontName: nil, isType0CidFont: false))
    }

    @Test func aCidFontNeverDoes() {
        // Its codes are not bytes.
        #expect(!pdfShouldUseCp1252(baseFontName: "Helvetica", isType0CidFont: true))
        #expect(!pdfShouldUseCp1252(baseFontName: nil, isType0CidFont: true))
    }

    @Test func texFontsDoNot() {
        // They put ligatures in the same byte range, so reading them as
        // Windows-1252 turns `deficiente` into `de…ciente`.
        for name in ["CMR10", "cmr10", "ABCDEF+CMR10", "ecrm1000", "msam10", "ttdc"] {
            #expect(!pdfShouldUseCp1252(baseFontName: name, isType0CidFont: false))
        }
    }

    @Test func symbolFontsDoNot() {
        for name in ["Symbol", "MathJax", "NotoEmoji", "DingbatsX", "SymbolMT"] {
            #expect(!pdfShouldUseCp1252(baseFontName: name, isType0CidFont: false))
        }
    }

    @Test func theLastPlusSeparatesTheSubsetTag() {
        // `rsplit_once`, so a name with two is stripped to the final part.
        #expect(!pdfShouldUseCp1252(baseFontName: "A+B+CMR10", isType0CidFont: false))
    }

    // MARK: the private-use area

    @Test func theOffsetIsRemovedAcrossTheRange() {
        #expect(pdfCleanSymbolPua("\u{F041}") == "A")
        #expect(pdfCleanSymbolPua("\u{F020}") == " ")
        #expect(pdfCleanSymbolPua("a\u{F041}b") == "aAb")
    }

    @Test func theBulletAndCheckmarkCodesAreNamedOutright() {
        for value in ["\u{F0A1}", "\u{F0A7}", "\u{F0B7}"] {
            #expect(pdfCleanSymbolPua(value) == "\u{2022}")
        }
        #expect(pdfCleanSymbolPua("\u{F0FC}") == "\u{2713}")
    }

    @Test func belowTheOffsetTheCodepointIsLeftAlone() {
        // Removing it would give a control character.
        #expect(pdfCleanSymbolPua("\u{F01F}") == "\u{F01F}")
        #expect(pdfCleanSymbolPua("\u{F000}") == "\u{F000}")
    }

    @Test func textWithNoPrivateUseIsUntouched() {
        #expect(pdfCleanSymbolPua("plain") == "plain")
    }

    @Test func theSymbolFallbackIsTheInverse() {
        let encoded = pdfDecodeSymbolFallback([0x41, 0x42], baseFontName: "Symbol")
        #expect(encoded == "\u{F041}\u{F042}")
        // And it round-trips through the fold.
        #expect(pdfCleanSymbolPua(encoded!) == "AB")
    }

    @Test func theSymbolFallbackNeedsASymbolFontAndPrintableBytes() {
        #expect(pdfDecodeSymbolFallback([0x41], baseFontName: "Helvetica") == nil)
        #expect(pdfDecodeSymbolFallback([0x41], baseFontName: nil) == nil)
        // Control bytes are dropped, so an all-control run yields nothing.
        #expect(pdfDecodeSymbolFallback([0x00, 0x1F], baseFontName: "Symbol") == nil)
        #expect(pdfDecodeSymbolFallback([], baseFontName: "Symbol") == nil)
    }

    // MARK: scoring

    @Test func knownWordsDominateTheScore() {
        #expect(pdfScoreText("the and of") > pdfScoreText("xxx yyy zzz"))
    }

    @Test func aLongWordlessRunIsPenalised() {
        // The shape of a wrong single-byte decoding: plausible letters in
        // implausible arrangements.
        let letters = String(repeating: "x", count: 20)
        #expect(pdfScoreText(letters) == 20 - 15)
    }

    @Test func cjkCountsAsLettersRatherThanNoise() {
        #expect(pdfScoreText("\u{65E5}\u{672C}\u{8A9E}") > 0)
    }

    @Test func replacementCharactersCountHeavilyAgainst() {
        #expect(pdfScoreText("\u{FFFD}\u{FFFD}\u{FFFD}") < 0)
    }

    @Test func aRemappedDecodingMustWinByMoreThanThree() {
        // A near-tie is not evidence enough to overrule what the font said.
        #expect(pdfChooseBestCmapDecode(primary: "abc", remapped: "abd") == "abc")
        #expect(
            pdfChooseBestCmapDecode(primary: String(repeating: "x", count: 20),
                remapped: "the and of to in") == "the and of to in")
    }

    @Test func anEmptyDecodingLosesToAnything() {
        #expect(pdfChooseBestCmapDecode(primary: "", remapped: "abc") == "abc")
        #expect(pdfChooseBestCmapDecode(primary: "abc", remapped: "") == "abc")
        #expect(pdfChooseBestCmapDecode(primary: "", remapped: "") == "")
    }
}
