import Testing

@testable import AnyDoc

/// The `/Differences` array, pinned without the oracle.
@Suite struct PdfEncodingDifferencesTests {
    /// Build an array from a compact spelling: `65 /A /B`.
    private func items(_ source: String) -> [PdfObject] {
        source.split(separator: " ").compactMap { token in
            if token.hasPrefix("/") { return .name(Array(token.dropFirst().utf8)) }
            if let value = Int64(token) { return .integer(value) }
            return .null
        }
    }

    private func parse(_ source: String, font: String? = nil) -> PdfEncodingDifferences {
        pdfParseEncodingDifferences(items(source), baseFontName: font)
    }

    @Test func aNumberSetsTheCodeAndNamesFollowFromIt() {
        let result = parse("65 /A /B /C")
        #expect(result.map[65]?.value == 0x41)
        #expect(result.map[66]?.value == 0x42)
        #expect(result.map[67]?.value == 0x43)
    }

    @Test func aSecondNumberRestartsTheNumbering() {
        let result = parse("65 /A /B 200 /eacute /egrave")
        #expect(result.map[66]?.value == 0x42)
        #expect(result.map[200]?.value == 0xE9)
        #expect(result.map[201]?.value == 0xE8)
    }

    @Test func namesBeforeAnyNumberStartAtZero() {
        let result = parse("/A /B")
        #expect(result.map[0]?.value == 0x41)
        #expect(result.map[1]?.value == 0x42)
    }

    @Test func aCodePastAByteIsTruncated() {
        // `n as u8`, so 256 becomes 0 rather than being rejected.
        #expect(parse("256 /A").map[0]?.value == 0x41)
        #expect(parse("300 /A").map[44]?.value == 0x41)
    }

    @Test func theCodeWrapsAfterTwoHundredAndFiftyFive() {
        let result = parse("255 /A /B")
        #expect(result.map[255]?.value == 0x41)
        #expect(result.map[0]?.value == 0x42)
    }

    @Test func anUnresolvableNameIsSkippedButStillAdvances() {
        // The byte keeps whatever the base encoding gave it, and the *next*
        // name is not shifted onto it.
        let result = parse("65 /notaglyph /B")
        #expect(result.map[65] == nil)
        #expect(result.map[66]?.value == 0x42)
    }

    @Test func theGlyphNameFallbacksReachThrough() {
        let result = parse("65 /uni0041 /u00E9 /zero.tf")
        #expect(result.map[65]?.value == 0x41)
        #expect(result.map[66]?.value == 0xE9)
        #expect(result.map[67]?.value == 0x30)
    }

    @Test func rawGlyphIdsAreRecordedNotMapped() {
        // They index the embedded font's own tables and mean nothing without
        // it, so a caller can tell the text is undecodable rather than
        // silently wrong.
        let result = parse("65 /gid00053 /A /gid7")
        #expect(result.gidCodes == [65, 67])
        #expect(result.map[65] == nil)
        #expect(result.map[66]?.value == 0x41)
    }

    @Test func gidRequiresDigitsAfterThePrefix() {
        #expect(parse("65 /gidX").gidCodes.isEmpty)
        #expect(parse("65 /gid").gidCodes.isEmpty)
        #expect(parse("65 /gid1").gidCodes == [65])
    }

    @Test func thePrivateGlyphMappingIsFontScoped() {
        // `/gNNN` names are private, so the same name in another font means
        // something else.
        #expect(parse("65 /g431", font: "Aptos").map[65]?.value == 0xFB00)
        #expect(parse("65 /g431", font: "ABCDEF+Aptos").map[65]?.value == 0xFB00)
        #expect(parse("65 /g431", font: "aptos").map[65]?.value == 0xFB00)
        #expect(parse("65 /g431", font: "Helvetica").map[65] == nil)
        #expect(parse("65 /g431").map[65] == nil)
    }

    @Test func subsetPrefixesAreStripped() {
        #expect(pdfStripSubsetPrefix("ABCDEF+Aptos") == "Aptos")
        #expect(pdfStripSubsetPrefix("Aptos") == "Aptos")
        #expect(pdfStripSubsetPrefix("A+B+C") == "B+C")
    }

    @Test func aStrayValueDoesNotShiftTheNamesAfterIt() {
        let result = parse("65 /A null /B")
        #expect(result.map[66]?.value == 0x42)
    }

    @Test func aRepeatedCodeTakesTheLastName() {
        #expect(parse("65 /A 65 /B").map[65]?.value == 0x42)
    }

    @Test func anEmptyArrayYieldsNothing() {
        #expect(parse("").map.isEmpty)
        #expect(parse("").gidCodes.isEmpty)
    }

    @Test func ligatureScalarsAreTheFiveLatinOnes() {
        for value: UInt32 in 0xFB00...0xFB04 {
            #expect(pdfIsLigatureScalar(Unicode.Scalar(value)!))
        }
        #expect(!pdfIsLigatureScalar(Unicode.Scalar(0xFB05)!))
        #expect(!pdfIsLigatureScalar("a"))
    }
}
