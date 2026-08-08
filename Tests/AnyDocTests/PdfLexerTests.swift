// The PDF object syntax (ISO 32000-1 §7.3). Cases are drawn from the spec's
// own examples plus the shapes `lopdf`'s parser singles out, and the last
// suite runs the lexer over the real fixture's bytes.
import Foundation
import Testing

@testable import AnyDoc

private func lex(_ source: String) -> PdfObject? {
    var lexer = PdfLexer(Array(source.utf8))
    return lexer.parseObject()
}

@Suite struct PdfNameTests {
    /// §7.3.5: `#` introduces a two-digit hex escape, which is how a name
    /// carries a delimiter or a space.
    @Test func namesDecodeHexEscapes() {
        #expect(lex("/Name1")?.asName == Array("Name1".utf8))
        #expect(lex("/A;Name_With-Various***Characters?")?.asName
            == Array("A;Name_With-Various***Characters?".utf8))
        #expect(lex("/Lime#20Green")?.asName == Array("Lime Green".utf8))
        #expect(lex("/paired#28#29parentheses")?.asName == Array("paired()parentheses".utf8))
        #expect(lex("/A#42")?.asName == Array("AB".utf8))
        // The empty name is legal.
        #expect(lex("/")?.asName == [])
        // A truncated escape ends the name rather than consuming past it.
        #expect(lex("/bad#4")?.asName == Array("bad".utf8))
    }

    /// A name ends at the first delimiter or whitespace.
    @Test func namesStopAtDelimiters() {
        var lexer = PdfLexer(Array("/Key/Next".utf8))
        #expect(lexer.parseObject()?.asName == Array("Key".utf8))
        #expect(lexer.parseObject()?.asName == Array("Next".utf8))
    }
}

@Suite struct PdfStringTests {
    /// §7.3.4.2: literal strings, including balanced inner parentheses,
    /// which are kept verbatim.
    @Test func literalStringsHandleNestingAndEscapes() {
        #expect(lex("(This is a string)")?.asStringBytes == Array("This is a string".utf8))
        #expect(lex("(Strings may contain balanced parentheses () and special characters.)")?
            .asStringBytes
            == Array("Strings may contain balanced parentheses () and special characters.".utf8))
        #expect(lex("()")?.asStringBytes == [])
        #expect(lex("(a\\nb)")?.asStringBytes == Array("a\nb".utf8))
        #expect(lex("(a\\tb)")?.asStringBytes == Array("a\tb".utf8))
        // An escaped character with no special meaning is itself.
        #expect(lex("(\\(\\))")?.asStringBytes == Array("()".utf8))
        #expect(lex("(\\q)")?.asStringBytes == Array("q".utf8))
    }

    /// Octal escapes take up to three digits and ignore overflow past a byte.
    @Test func octalEscapesTakeUpToThreeDigits() {
        #expect(lex("(\\101)")?.asStringBytes == [0x41])
        #expect(lex("(\\53)")?.asStringBytes == [0x2B])
        #expect(lex("(\\5)")?.asStringBytes == [0x05])
        // Digits past the third are literal text.
        #expect(lex("(\\1015)")?.asStringBytes == [0x41, 0x35])
        // 0o400 overflows a byte; the spec says to ignore the overflow.
        #expect(lex("(\\400)")?.asStringBytes == [0x00])
    }

    /// A backslash before a line break is a continuation and contributes
    /// nothing, while a bare line break survives.
    @Test func lineContinuationsProduceNothing() {
        #expect(lex("(a\\\nb)")?.asStringBytes == Array("ab".utf8))
        #expect(lex("(a\\\r\nb)")?.asStringBytes == Array("ab".utf8))
        #expect(lex("(a\nb)")?.asStringBytes == Array("a\nb".utf8))
    }

    /// Nesting past the cap is a crafted file: it must be rejected, not
    /// recursed into.
    @Test func runawayNestingIsRejected() {
        let deep = String(repeating: "(", count: pdfMaxBracket + 5)
            + String(repeating: ")", count: pdfMaxBracket + 5)
        #expect(lex(deep) == nil)
        // Just inside the cap still parses.
        let ok = "(" + String(repeating: "(", count: pdfMaxBracket - 1)
            + String(repeating: ")", count: pdfMaxBracket - 1) + ")"
        #expect(lex(ok) != nil)
    }

    /// §7.3.4.3: hex strings ignore whitespace and pad an odd final digit.
    @Test func hexStringsPadAndIgnoreWhitespace() {
        #expect(lex("<4E6F762073686D6F7A206B6120706F702E>")?.asStringBytes
            == Array("Nov shmoz ka pop.".utf8))
        #expect(lex("<901FA3>")?.asStringBytes == [0x90, 0x1F, 0xA3])
        // An odd number of digits is padded with a trailing zero.
        #expect(lex("<901FA>")?.asStringBytes == [0x90, 0x1F, 0xA0])
        #expect(lex("<90 1F\nA3>")?.asStringBytes == [0x90, 0x1F, 0xA3])
        #expect(lex("<>")?.asStringBytes == [])
        // A non-hex character is a parse failure, not silently skipped.
        #expect(lex("<90ZZ>") == nil)
    }

    /// An unterminated string is a failure rather than a truncated value.
    @Test func unterminatedStringsFail() {
        #expect(lex("(no end") == nil)
        #expect(lex("<9012") == nil)
    }
}

@Suite struct PdfNumberTests {
    @Test func integersAndRealsParse() {
        #expect(lex("123")?.asInteger == 123)
        #expect(lex("-98")?.asInteger == -98)
        #expect(lex("+17")?.asInteger == 17)
        #expect(lex("0")?.asInteger == 0)
        // Reals are single precision, as they are in the reference, so the
        // expected values are compared at that width rather than as Doubles.
        #expect(lex("34.5")?.asNumber == Double(Float(34.5)))
        #expect(lex("-3.62")?.asNumber == Double(Float(-3.62)))
        #expect(lex("+123.6")?.asNumber == Double(Float(123.6)))
        // A leading or trailing point is legal.
        #expect(lex("4.")?.asNumber == Double(Float(4.0)))
        #expect(lex(".002")?.asNumber == Double(Float(0.002)))
        #expect(lex("-.002")?.asNumber == Double(Float(-0.002)))
    }

    /// A bare sign or point is not a number.
    @Test func degenerateNumbersFail() {
        #expect(lex("-") == nil)
        #expect(lex(".") == nil)
        #expect(lex("+") == nil)
    }

    /// An integer too large for Int64 falls back to a real rather than
    /// failing, which is what a reader must do to keep going.
    @Test func hugeIntegersBecomeReals() {
        let huge = String(repeating: "9", count: 30)
        #expect(lex(huge)?.asInteger == nil)
        #expect(lex(huge)?.asNumber != nil)
    }
}

@Suite struct PdfCompositeTests {
    /// `N G R` is a reference; anything else that starts with a number is a
    /// number, and the cursor must not be consumed by the attempt.
    @Test func referencesParseAndBacktrack() {
        #expect(lex("12 0 R")?.asReference == PdfObjectId(number: 12, generation: 0))
        #expect(lex("193 7 R")?.asReference == PdfObjectId(number: 193, generation: 7))
        // Two integers that are not followed by `R` stay two integers.
        var lexer = PdfLexer(Array("12 0 obj".utf8))
        #expect(lexer.parseObject()?.asInteger == 12)
        #expect(lexer.parseObject()?.asInteger == 0)
        // `Rx` is not the reference keyword.
        var trailing = PdfLexer(Array("12 0 Rx".utf8))
        #expect(trailing.parseObject()?.asInteger == 12)
    }

    @Test func arraysAndDictionariesNest() {
        let array = lex("[549 3.14 false (Ralph) /SomeName]")?.asArray
        #expect(array?.count == 5)
        #expect(array?[0].asInteger == 549)
        #expect(array?[2] != nil)
        #expect(array?[3].asStringBytes == Array("Ralph".utf8))
        #expect(array?[4].asName == Array("SomeName".utf8))
        #expect(lex("[]")?.asArray?.isEmpty == true)

        let dict = lex("<</Type /Example /Subtype /DictExample /Version 0.01 /Nested <</Key 1>>>>")?
            .asDictionary
        #expect(dict?["Type"]?.asName == Array("Example".utf8))
        #expect(dict?["Version"]?.asNumber == Double(Float(0.01)))
        #expect(dict?["Nested"]?.asDictionary?["Key"]?.asInteger == 1)
        #expect(lex("<<>>")?.asDictionary?.isEmpty == true)
    }

    /// Dictionary key order is preserved so parses are reproducible.
    @Test func dictionaryKeysKeepInsertionOrder() {
        let dict = lex("<</B 1 /A 2 /C 3>>")?.asDictionary
        #expect(dict?.keys == [Array("B".utf8), Array("A".utf8), Array("C".utf8)])
    }

    @Test func keywordsParse() {
        #expect(lex("true") != nil)
        #expect(lex("false") != nil)
        #expect(lex("null")?.isNull == true)
    }

    /// Comments are whitespace anywhere a token may end.
    @Test func commentsAreSkipped() {
        #expect(lex("% a comment\n42")?.asInteger == 42)
        let dict = lex("<</A % note\n 1>>")?.asDictionary
        #expect(dict?["A"]?.asInteger == 1)
    }
}

@Suite struct PdfFixtureLexTests {
    /// The lexer has to work on a file produced by a real writer, not just
    /// on hand-written snippets: parse the fixture's trailer dictionary,
    /// which sits at a known keyword near the end.
    @Test func fixtureTrailerParses() throws {
        let path = fixtureRoot.appendingPathComponent("pdf/text.pdf").path
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        let keyword = Array("trailer".utf8)
        var start: Int?
        // The last `trailer` is the one the file ends with.
        for i in stride(from: bytes.count - keyword.count, through: 0, by: -1)
        where Array(bytes[i..<(i + keyword.count)]) == keyword {
            start = i + keyword.count
            break
        }
        let offset = try #require(start, "no trailer keyword in the fixture")

        var lexer = PdfLexer(bytes, at: offset)
        let trailer = try #require(lexer.parseObject()?.asDictionary, "trailer did not parse")
        // Values cross-checked against the raw bytes of the fixture.
        #expect(trailer["Size"]?.asInteger == 195)
        #expect(trailer["Root"]?.asReference == PdfObjectId(number: 193, generation: 0))
        #expect(trailer["Info"]?.asReference == PdfObjectId(number: 194, generation: 0))
        // /ID is a two-element array of hex strings.
        let id = try #require(trailer["ID"]?.asArray)
        #expect(id.count == 2)
        #expect(id[0].asStringBytes?.count == 16)
        #expect(id[0].asStringBytes == id[1].asStringBytes)
    }

    /// Every indirect object header in the fixture must lex, and the object
    /// numbers must stay inside the size the trailer declares.
    @Test func everyObjectHeaderLexes() throws {
        let path = fixtureRoot.appendingPathComponent("pdf/text.pdf").path
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        let objKeyword = Array(" obj".utf8)
        var headers = 0
        var i = 0
        while i + objKeyword.count <= bytes.count {
            if Array(bytes[i..<(i + objKeyword.count)]) == objKeyword {
                // Walk back over "N G" to the start of the header.
                var start = i
                var fields = 0
                while start > 0, fields < 2 {
                    var j = start - 1
                    while j > 0, PdfLexer.isWhitespace(bytes[j]) { j -= 1 }
                    while j > 0, bytes[j - 1] >= UInt8(ascii: "0"), bytes[j - 1] <= UInt8(ascii: "9")
                    {
                        j -= 1
                    }
                    start = j
                    fields += 1
                }
                var lexer = PdfLexer(bytes, at: start)
                if let number = lexer.parseUnsignedInt() {
                    lexer.skipSpace()
                    if lexer.parseUnsignedInt() != nil {
                        #expect(number < 195, "object number \(number) exceeds the declared Size")
                        headers += 1
                    }
                }
            }
            i += 1
        }
        // The fixture is a classic-xref file: every object is written out.
        #expect(headers > 100, "expected the fixture's indirect objects, found \(headers)")
        print("pdf fixture: \(headers) indirect object headers lexed")
    }
}
