import Testing

@testable import AnyDoc

/// The byte-level content scanner detection runs before anything is decoded.
@Suite struct PdfContentScanTests {
    private func scan(_ stream: String) -> (
        scan: PdfContentScan, characters: Set<UInt8>, fonts: [String]
    ) {
        var characters: Set<UInt8> = []
        var fonts: Set<[UInt8]> = []
        let result = pdfScanContentForTextOperators(
            Array(stream.utf8), uniqueCharacters: &characters, usedFontNames: &fonts)
        return (result, characters, fonts.map { String(decoding: $0, as: UTF8.self) }.sorted())
    }

    private func text(_ characters: Set<UInt8>) -> String {
        String(decoding: characters.sorted(), as: UTF8.self)
    }

    @Test func textOperatorsAreCountedAndTheirStringsRead() {
        let hello = scan("(Hello) Tj")
        #expect(hello.scan.textOperators == 1)
        #expect(text(hello.characters) == "Helo")
        // Hex strings and `TJ` arrays reach the same place.
        #expect(text(scan("<48656C6C6F> Tj").characters) == "Helo")
        #expect(text(scan("[(A)-200(B)] TJ").characters) == "AB")
    }

    @Test func anOperatorRunIntoItsOperandStillCounts() {
        // `Tj` needs white space or the end of the stream after it...
        #expect(scan("(Hello)Tj").scan.textOperators == 1)
        // ...but `Tf` also accepts an opening delimiter, because writers run
        // it straight into the next operand.
        for stream in ["/F1 12 Tf[<01>] TJ", "/F1 12 Tf(x) Tj", "/F1 12 Tf<01> Tj"] {
            #expect(scan(stream).scan.fontChanges == 1, "\(stream)")
        }
        #expect(scan("/F1 12 Tf/F2 10 Tf (y) Tj").fonts == ["F1", "F2"])
    }

    @Test func pathOperatorsMustStandAloneAsWords() {
        #expect(scan("m l c h f S s B F").scan.pathOperators == 9)
        // Letters inside words are not operators.
        #expect(scan("mm ll form").scan.pathOperators == 0)
        // `rg` is a colour operator, not a rectangle.
        #expect(scan("0 0 1 rg 10 10 m").scan.pathOperators == 1)
    }

    @Test func theTwoByteOperatorsCountOnce() {
        // `re` is one operator, and so is `f*` — the `f` inside it does not
        // also count, because a lone `f` needs white space after it.
        #expect(scan("10 10 100 100 re f").scan.pathOperators == 2)
        #expect(scan("10 10 100 100 re f*").scan.pathOperators == 2)
        #expect(scan("f* f f*").scan.pathOperators == 3)
    }

    @Test func imagesAreNeverCountedHere() {
        // `Do` invokes any XObject, forms included, so it is deliberately
        // ignored — and the image count is always zero.
        let result = scan("q 1 0 0 1 0 0 cm /Im0 Do Q")
        #expect(result.scan.imageCount == 0)
        #expect(result.scan.textOperators == 0)
        #expect(result.scan.pathOperators == 0)
    }

    @Test func anEmptyStreamScansToNothing() {
        #expect(scan("").scan == PdfContentScan())
        // A bare operator name with no operand is still an operator.
        #expect(scan("Tj").scan.textOperators == 1)
        #expect(scan("T").scan == PdfContentScan())
    }

    // MARK: - the font name before Tf

    private func fontName(_ prefix: String) -> String {
        var content = Array(prefix.utf8)
        let position = content.count
        content.append(contentsOf: Array("Tf ".utf8))
        return pdfExtractFontNameBeforeTf(content, at: position)
            .map { String(decoding: $0, as: UTF8.self) } ?? "-"
    }

    @Test func theFontNameIsReadBackwardsPastTheSize() {
        #expect(fontName("/F1 12 ") == "F1")
        #expect(fontName("/F1 12") == "F1")
        #expect(fontName("/Helvetica-Bold 9.5 ") == "Helvetica-Bold")
        #expect(fontName("/F1 -12 ") == "F1")
        #expect(fontName("/F1 .5 ") == "F1")
        #expect(fontName("/F1  12  ") == "F1")
        #expect(fontName("BT /F1 12 ") == "F1")
    }

    @Test func aNameWithNoSizeLosesItsLastDigit() {
        // There is no size to skip, so the backward scan eats the trailing
        // `1` as one — `/F1 ` yields `F`. The reference's behaviour, and a
        // reason `Tf` without an operand is not worth trusting.
        #expect(fontName("/F1 ") == "F")
        #expect(fontName("/F1") == "F")
    }

    @Test func aMalformedOperandAbandonsTheSearch() {
        for prefix in ["F1 12 ", "12 ", "/ 12 ", "", "/F1(x) 12 "] {
            #expect(fontName(prefix) == "-", "\(prefix)")
        }
        // A preceding string is fine as long as the name itself is clean.
        #expect(fontName("(text) /F1 12 ") == "F1")
        // Name escapes are not decoded.
        #expect(fontName("/F#20A 12 ") == "F#20A")
    }

    // MARK: - the characters before Tj

    private func characters(_ operand: String) -> String {
        var found: Set<UInt8> = []
        let content = Array(operand.utf8)
        pdfCollectTextCharactersBefore(content, at: content.count, into: &found)
        return String(decoding: found.sorted(), as: UTF8.self)
    }

    @Test func literalHexAndArrayOperandsAreAllRead() {
        #expect(characters("(abc) ") == "abc")
        #expect(characters("<414243> ") == "ABC")
        #expect(characters("[(a)(b)] ") == "ab")
        #expect(characters("[<41>(b)] ") == "Ab")
        #expect(characters("[(a) -200 (b)] ") == "ab")
    }

    @Test func nestingAndEscapesAreHonoured() {
        // The scan finds the *matching* open paren, then takes every byte
        // between — inner delimiters included, since it collects rather than
        // parses. `(a(b)c)` yields the parentheses as characters too.
        #expect(characters("(a(b)c) ") == "()abc")
        // An escaped closing paren does not end the string.
        #expect(characters("(a\\)b) ").contains("b"))
    }

    @Test func whiteSpaceIsNeverCollected() {
        #expect(characters("(  ) ") == "")
        #expect(characters("() ") == "")
        #expect(characters("<> ") == "")
        #expect(characters("[] ") == "")
        // A hex pair may also decode *to* white space, which is dropped —
        // a distinction the literal branch does not make.
        #expect(characters("<0920> ") == "")
        #expect(characters("<0041> ") == "A")
    }

    @Test func malformedHexIsSkippedPairByPair() {
        // White space inside a hex string is stripped before pairing.
        #expect(characters("<41 42> ") == "AB")
        // An odd trailing digit is dropped, and non-hex decodes to nothing.
        #expect(characters("<414> ") == "A")
        #expect(characters("<41zz> ") == "A")
    }

    @Test func anOperandThatIsNotAStringYieldsNothing() {
        for operand in ["abc ", "", "   "] {
            #expect(characters(operand) == "", "\(operand)")
        }
    }

    @Test func hexDigitsConvertInBothCases() {
        #expect(pdfHexValue(UInt8(ascii: "0")) == 0)
        #expect(pdfHexValue(UInt8(ascii: "9")) == 9)
        #expect(pdfHexValue(UInt8(ascii: "a")) == 10)
        #expect(pdfHexValue(UInt8(ascii: "F")) == 15)
        #expect(pdfHexValue(UInt8(ascii: "g")) == nil)
        #expect(pdfHexValue(UInt8(ascii: "/")) == nil)
    }
}
