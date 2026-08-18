// The simple-font base encodings.
//
// The corpus covers these end to end; these tests pin the entries that
// distinguish one table from another, so a wrong table cannot pass by
// agreeing on ASCII — which all three do, for every code below 0x80.
import Testing

@testable import AnyDoc

@Suite struct PdfBaseEncodingTests {
    /// `0xE9` is the single most diagnostic code: three encodings, three
    /// different characters, and the one that says whether a port has
    /// confused StandardEncoding with Latin-1.
    @Test func theTablesDisagreeWhereItMatters() {
        #expect(pdfStandardEncodingTable[0xE9] == "\u{00D8}")  // Oslash
        #expect(pdfWinAnsiEncodingTable[0xE9] == "\u{00E9}")  // eacute
        #expect(pdfMacRomanEncodingTable[0xE9] == "\u{00C8}")  // Egrave
    }

    /// StandardEncoding leaves most of the upper half unassigned, and an
    /// unassigned code is dropped rather than rendered.
    @Test func standardEncodingLeavesMuchOfTheUpperHalfUnassigned() {
        for code: UInt8 in [0x80, 0x92, 0xA0, 0xC0, 0xF0, 0xFC, 0xFF] {
            #expect(pdfStandardEncodingTable[code] == nil)
        }
        #expect(pdfStandardEncodingTable.count == 149)
        // The other two assign nearly everything above 0x20.
        #expect(pdfWinAnsiEncodingTable.count == 224)
        #expect(pdfMacRomanEncodingTable.count == 223)
    }

    /// The three agree across printable ASCII **except at two codes**, which
    /// is why a document of ordinary text cannot tell them apart and why the
    /// corpus needed a fixture drawing high bytes before this gap was
    /// visible at all.
    @Test func theTablesAgreeOnPrintableAsciiApartFromTwoQuotes() {
        for code in UInt8(0x20)...UInt8(0x7E) where code != 0x27 && code != 0x60 {
            let standard = pdfStandardEncodingTable[code]
            #expect(standard != nil)
            #expect(pdfWinAnsiEncodingTable[code] == standard, "code \(code)")
            #expect(pdfMacRomanEncodingTable[code] == standard, "code \(code)")
        }
    }

    /// The two exceptions. StandardEncoding puts *typographic* quotes at the
    /// ASCII apostrophe and backtick — code 39 is `quoteright` and code 96 is
    /// `quoteleft` — so a font with no `/Encoding` renders `'` as `\u{2019}`.
    /// Assumed otherwise when these tests were first written, and the
    /// measured tables said no.
    @Test func standardEncodingPutsTypographicQuotesAtTheAsciiCodes() {
        #expect(pdfStandardEncodingTable[0x27] == "\u{2019}")
        #expect(pdfStandardEncodingTable[0x60] == "\u{2018}")
        #expect(pdfWinAnsiEncodingTable[0x27] == "\u{0027}")
        #expect(pdfWinAnsiEncodingTable[0x60] == "\u{0060}")
        #expect(pdfMacRomanEncodingTable[0x27] == "\u{0027}")
        #expect(pdfMacRomanEncodingTable[0x60] == "\u{0060}")
    }

    /// Some codes carry two characters: one code, one glyph, two scalars.
    @Test func ligatureCodesMapToTwoCharacters() {
        #expect(pdfStandardEncodingTable[0xAE] == "fi")
        #expect(pdfStandardEncodingTable[0xAF] == "fl")
        #expect(pdfMacRomanEncodingTable[0xDE] == "fi")
        #expect(pdfMacRomanEncodingTable[0xDF] == "fl")
    }

    /// An unrecognised name — or none — is StandardEncoding.
    @Test func anUnnamedEncodingIsStandard() {
        #expect(pdfBaseEncodingTable(named: nil)[0xE9] == "\u{00D8}")
        #expect(pdfBaseEncodingTable(named: "PDFDocEncoding")[0xE9] == "\u{00D8}")
        #expect(pdfBaseEncodingTable(named: "WinAnsiEncoding")[0xE9] == "\u{00E9}")
        #expect(pdfBaseEncodingTable(named: "MacRomanEncoding")[0xE9] == "\u{00C8}")
    }
}
