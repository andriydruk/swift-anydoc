import Testing

@testable import AnyDoc

/// The ToUnicode string helpers: hex destinations to text.
@Suite struct PdfToUnicodeTextTests {
    @Test func hexCodesAreParsedAfterTrimming() {
        #expect(pdfParseHexU16("0041") == 0x41)
        #expect(pdfParseHexU16("  0041  ") == 0x41)
        #expect(pdfParseHexU16("ffff") == 0xFFFF)
        // Out of range, malformed, and empty all fail rather than saturate.
        #expect(pdfParseHexU16("10000") == nil)
        #expect(pdfParseHexU16("004G") == nil)
        #expect(pdfParseHexU16("") == nil)
        #expect(pdfParseHexU16("0x41") == nil)
    }

    @Test func destinationsAreUtf16BigEndian() {
        #expect(pdfHexToUnicodeString("0041") == "A")
        #expect(pdfHexToUnicodeString("00410042") == "AB")
        // White space inside the hex is ignored wherever it falls.
        #expect(pdfHexToUnicodeString("00 41") == "A")
        #expect(pdfHexToUnicodeString("0 041") == "A")
    }

    @Test func surrogatePairsSurviveAndLoneHalvesDoNot() {
        // Treating each four-digit chunk as a scalar would lose this.
        #expect(pdfHexToUnicodeString("D83CDF1F") == "\u{1F31F}")
        #expect(pdfHexToUnicodeString("D800DC00") == "\u{10000}")
        // An unpaired half fails the whole conversion — `String::from_utf16`
        // rejects rather than substituting, and two bytes cannot fall
        // through to the one-byte path.
        #expect(pdfHexToUnicodeString("D83C") == nil)
        #expect(pdfHexToUnicodeString("DF1F") == nil)
        #expect(pdfHexToUnicodeString("0041D83C") == nil)
    }

    @Test func aSingleByteIsAcceptedWhenItIsPrintable() {
        // No specification allows a one-byte destination; producers write
        // them anyway, and the reference would rather have the character.
        #expect(pdfHexToUnicodeString("41") == "A")
        #expect(pdfHexToUnicodeString("20") == " ")
        // Tab and newline are readmitted by name; other controls are not.
        #expect(pdfHexToUnicodeString("09") == "\t")
        #expect(pdfHexToUnicodeString("0A") == "\n")
        for control in ["00", "1F", "7F", "80"] {
            #expect(pdfHexToUnicodeString(control) == nil, "\(control)")
        }
    }

    @Test func malformedHexIsRejectedOutright() {
        for hex in ["004", "", "004G", "0066006600690"] {
            #expect(pdfHexToUnicodeString(hex) == nil, "\(hex)")
        }
    }

    @Test func aWhitespaceListCollapsesToOneCharacter() {
        // A destination naming every acceptable space becomes one — but only
        // when a control character is among them, which is the malformed
        // signature. Tab wins if present.
        #expect(pdfHexToUnicodeString("00200009") == "\t")
        #expect(pdfHexToUnicodeString("00090020") == "\t")
        #expect(pdfNormalizeToUnicodeDestination(" \n") == " ")
        #expect(pdfNormalizeToUnicodeDestination("\t\n") == "\t")
        // Ordinary spaces are not a list, so they survive.
        #expect(pdfNormalizeToUnicodeDestination("  ") == "  ")
        #expect(pdfNormalizeToUnicodeDestination("   ") == "   ")
    }

    @Test func aHyphenListCollapsesOnlyWithASoftHyphen() {
        #expect(pdfHexToUnicodeString("002D00AD") == "-")
        #expect(pdfHexToUnicodeString("00AD2010") == "-")
        #expect(pdfNormalizeToUnicodeDestination("-\u{00ad}") == "-")
        // Without the soft hyphen the run is left alone.
        #expect(pdfNormalizeToUnicodeDestination("-\u{2010}") == "-\u{2010}")
        // And a hyphen beside anything else is ordinary text.
        #expect(pdfNormalizeToUnicodeDestination("x\u{00ad}") == "x\u{00ad}")
    }

    @Test func ordinaryMultiCharacterMappingsAreUntouched() {
        // A ligature expanding to three letters must survive intact.
        #expect(pdfNormalizeToUnicodeDestination("ffi") == "ffi")
        #expect(pdfNormalizeToUnicodeDestination("a b") == "a b")
        #expect(pdfNormalizeToUnicodeDestination("A") == "A")
    }

    @Test func aScalarDestinationMustBeExactlyOne() {
        #expect(pdfHexToUnicodeScalar("0041") == 0x41)
        #expect(pdfHexToUnicodeScalar("D83CDF1F") == 0x1F31F)
        // Longer is rejected rather than truncated — a range's base has to
        // be one character for the arithmetic after it to mean anything.
        #expect(pdfHexToUnicodeScalar("00410042") == nil)
        #expect(pdfHexToUnicodeScalar("") == nil)
        // ...unless normalisation has already collapsed it to one.
        #expect(pdfHexToUnicodeScalar("002D00AD") == 0x2D)
    }

    @Test func theUsecmapNameIsTheTokenBeforeTheOperator() {
        #expect(pdfFindUsecmapName("/Adobe-Japan1-UCS2 usecmap") == "Adobe-Japan1-UCS2")
        #expect(pdfFindUsecmapName("  /Name  usecmap  ") == "Name")
        #expect(pdfFindUsecmapName("line one\n/Name usecmap\nline three") == "Name")
        // Only a slash-prefixed name counts, and only on the same line.
        #expect(pdfFindUsecmapName("Adobe usecmap") == nil)
        #expect(pdfFindUsecmapName("/Name\nusecmap") == nil)
        #expect(pdfFindUsecmapName("usecmap") == nil)
        #expect(pdfFindUsecmapName("no cmap here") == nil)
        #expect(pdfFindUsecmapName("") == nil)
    }
}
