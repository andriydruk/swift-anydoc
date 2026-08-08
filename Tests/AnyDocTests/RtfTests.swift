// Ported from src/formats/rtf/{lexer,mod,table}.rs tests, plus regression
// coverage for divergences the corruption sweep surfaced.
import Testing

@testable import AnyDoc

private func rtf(_ source: String) -> [UInt8] {
    Array(source.utf8)
}

private func markdown(_ source: String) throws -> String {
    try AnyDoc.markdown(rtf(source), format: .rtf)
}

/// A backslash, assembled rather than written, so control words in these
/// tests cannot be mistaken for the source file's own escape sequences.
private let bs = String(UnicodeScalar(92))

/// A `\uN` control word with its fallback character.
private func u(_ n: Int, _ fallback: String = "?") -> String {
    "\(bs)u\(n)\(fallback)"
}

/// Wrap body text in a minimal RTF document.
private func doc(_ body: String) -> String {
    "{\(bs)rtf1 \(body)\(bs)par}"
}

@Suite struct RtfLexerTests {
    @Test func binPayloadConsumedRaw() {
        // Payload bytes are braces and backslashes; they must not lex.
        var lexer = RtfLexer(rtf(#"{\rtf1 a\bin5 }}{\\x b}"#))
        var bin: [UInt8] = []
        var opens = 0
        var closes = 0
        while let token = lexer.next() {
            switch token {
            case .bin(let payload): bin.append(contentsOf: payload)
            case .open: opens += 1
            case .close: closes += 1
            default: break
            }
        }
        #expect(bin == Array(#"}}{\\"#.utf8))
        #expect(opens == 1)
        #expect(closes == 1)
    }

    @Test func backslashBeforeALineBreakIsOneParagraphMark() {
        for source in ["{\\rtf1 a\\\nb}", "{\\rtf1 a\\\r\nb}", "{\\rtf1 a\\\rb}"] {
            var lexer = RtfLexer(rtf(source))
            var pars = 0
            var symbols = 0
            while let token = lexer.next() {
                switch token {
                case .word("par", nil): pars += 1
                case .symbol: symbols += 1
                default: break
                }
            }
            #expect(pars == 1, "source: \(rustDebugString(source))")
            #expect(symbols == 0, "source: \(rustDebugString(source))")
        }
    }

    @Test func destinationExtraction() {
        let source = rtf(#"{\rtf1{\*\listtable{\list\listid5}}{\fonttbl{\f0 Arial;}} body}"#)
        let lists = rtfDestinationGroups(source, "listtable")
        #expect(lists.count == 1)
        #expect(lists.first?.starts(with: Array(#"{\list"#.utf8)) == true)
        #expect(rtfDestinationGroups(source, "fonttbl").count == 1)
    }

    /// A `\binN` whose payload runs past the end of the buffer must clamp,
    /// not read out of bounds or hang.
    @Test func binPastEndOfInputClamps() {
        var lexer = RtfLexer(rtf(#"{\rtf1 a\bin999999 short}"#))
        var sawBin = false
        while let token = lexer.next() {
            if case .bin(let payload) = token {
                sawBin = true
                #expect(payload.count <= 7)
            }
        }
        #expect(sawBin)
    }

    /// A control-word parameter too wide for the reference's i32 saturates.
    @Test func oversizedParametersSaturate() {
        var lexer = RtfLexer(rtf(#"{\rtf1 \fs99999999999999999999 x}"#))
        var seen: Int32?
        while let token = lexer.next() {
            if case .word("fs", let param) = token { seen = param }
        }
        #expect(seen == Int32.max)
    }
}

@Suite struct RtfTests {
    @Test func missingListTableKeepsListtextMarker() throws {
        // A \ls with no list-table definition degrades to a bullet, but the
        // captured \listtext (the marker Word displays) must stay visible.
        let doc = try parseRtf(
            rtf(#"{\rtf1 \pard{\listtext 1.\tab}\ls5 one\par \pard{\listtext 2.\tab}\ls5 two\par}"#))
        guard case .list(let list) = doc.blocks.first else {
            Issue.record("expected a list, got \(doc.blocks)")
            return
        }
        #expect(list.items[0].markerLabel == "1.")
        #expect(list.items[1].markerLabel == "2.")
    }

    @Test func midParagraphPageAndColumnBreaksKeepTheWordBoundary() throws {
        // \page and \column carry no paragraph mark: without a break of
        // their own the text on either side would run together.
        for source in [#"{\rtf1 Alfa\page Beta\par}"#, #"{\rtf1 Alfa\column Beta\par}"#] {
            #expect(try markdown(source) == "Alfa\\\nBeta\n", "source: \(source)")
        }
    }

    @Test func backslashBeforeALineBreakBreaksTheParagraph() throws {
        // The paragraph mark Cocoa's RTF writer emits instead of `\par`.
        for source in [
            "{\\rtf1 Alpha\\\nBeta\\\nGamma\\\n}", "{\\rtf1 Alpha\\\r\nBeta\\\rGamma\\\r\n}",
        ] {
            #expect(
                try markdown(source) == "Alpha\n\nBeta\n\nGamma\n",
                "source: \(rustDebugString(source))")
        }
    }

    @Test func bodyTextBeforeATableStaysOutOfTheFirstCell() throws {
        let source = "{\\rtf1 Intro\\\n\\trowd\\cellx2000\\cellx4000 A\\cell B\\cell\\row}"
        let out = try markdown(source)
        #expect(out.hasPrefix("Intro\n\n|"), "\(out)")
    }

    @Test func styledRunsStopBeforeTablesAndWorkInsideCells() throws {
        let source = "{\(bs)rtf1\(bs)ansi"
            + "{\(bs)stylesheet{\(bs)s0 Normal;}{\(bs)s1 Source Code;}}"
            + "\(bs)pard\(bs)plain\(bs)s1 before table\(bs)par"
            + "\(bs)trowd\(bs)cellx2000\(bs)pard\(bs)plain\(bs)intbl\(bs)s1 first\(bs)par"
            + " second\(bs)cell\(bs)row}"
        let doc = try parseRtf(rtf(source))
        guard doc.blocks.count == 2, case .codeBlock(_, let before) = doc.blocks[0],
            case .table(let table) = doc.blocks[1]
        else {
            Issue.record("unexpected block order: \(doc.blocks)")
            return
        }
        #expect(before == "before table")
        guard case .origin(let cell) = table.grid[0][0],
            cell.blocks.count == 1, case .codeBlock(_, let inside) = cell.blocks[0]
        else {
            Issue.record("unexpected cell blocks: \(table.grid[0][0])")
            return
        }
        #expect(inside == "first\nsecond")
    }

    @Test func pictHexPayloadBecomesAnAsset() throws {
        let doc = try parseRtf(rtf(#"{\rtf1 before {\pict\pngblip 89504e470d0a1a0a} after}"#))
        #expect(doc.assets.count == 1, "assets: \(doc.assets)")
        #expect(doc.assets.first?.mediaType == "image/png")
        #expect(doc.assets.first?.bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)
    }

    @Test func pictPropertySubgroupsDoNotContaminateThePayload() throws {
        let doc = try parseRtf(
            rtf(
                #"{\rtf1 {\pict{\*\picprop{\sp{\sn wzDescription}{\sv abcdef}}}\pngblip 89504e470d0a1a0a}}"#
            ))
        #expect(doc.assets.count == 1, "assets: \(doc.assets)")
        #expect(doc.assets.first?.bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)
    }

    @Test func nonshppictFallbackIsNotExtractedTwice() throws {
        let doc = try parseRtf(
            rtf(#"{\rtf1 {\*\shppict{\pict\pngblip 89504e47}}{\nonshppict{\pict\wmetafile8 0102}}}"#))
        #expect(doc.assets.count == 1, "only the preferred picture: \(doc.assets)")
        #expect(doc.assets.first?.mediaType == "image/png")
    }

    @Test func notAnRtfFileIsRejected() {
        #expect(throws: ConvertError.self) { try parseRtf(rtf("not rtf at all")) }
        #expect(throws: ConvertError.self) { try parseRtf([]) }
    }

    /// Regression: the override table consumes both its list id and its `\ls`
    /// on every flush. Leaving a half-filled pair behind let a later,
    /// unrelated `\listoverride` inherit the stale id and define a list the
    /// reference leaves undefined. Found by the corruption sweep.
    @Test func halfFilledListOverrideDoesNotLeakItsIdForward() throws {
        // The first override names a list id but never its \ls; the second
        // names an \ls but no id. Neither is complete, so neither defines a
        // list and the item falls back to its literal \listtext marker.
        let source = #"""
            {\rtf1{\*\listtable{\list\listid100{\listlevel\levelnfc0\leveltext\'02\'00.;\
            \levelnumbers\'01;}}}{\*\listoverridetable{\listoverride\listid100}\
            {\listoverride\ls7}}\pard{\listtext 9.\tab}\ls7\ilvl0 item\par}
            """#
            .replacingOccurrences(of: "\\\n", with: "")
        let doc = try parseRtf(rtf(source))
        guard case .list(let list) = doc.blocks.first else {
            Issue.record("expected a list, got \(doc.blocks)")
            return
        }
        #expect(list.marker == .bullet)
        #expect(list.items.first?.markerLabel == "9.")
    }
}

@Suite struct RtfEncodingTests {
    @Test func codepageSelectsTheDocumentEncoding() throws {
        // \ansicpg1251 plus a cyrillic-charset font: both routes must decode
        // the same bytes to the same text.
        var bytes = Array(#"{\rtf1\ansi\ansicpg1251{\fonttbl{\f0\fcharset204 A;}}\f0 "#.utf8)
        bytes.append(contentsOf: [0xC4, 0xE0])  // "Да" in windows-1251
        bytes.append(contentsOf: Array(#"\par}"#.utf8))
        #expect(try AnyDoc.markdown(bytes, format: .rtf) == "Да\n")
    }

    @Test func hexEscapesUseTheSelectedCodepage() throws {
        let source = #"{\rtf1\ansi\ansicpg1251{\fonttbl{\f0\fcharset204 A;}}\f0 \'c4\'e0\par}"#
        #expect(try markdown(source) == "Да\n")
    }

    @Test func unmappedPositionsBecomeReplacementCharacters() {
        // windows-1253 leaves 0xAA, 0xD2 and 0xFF unmapped; the WHATWG index
        // is what decides, and it maps many C1 positions rather than leaving
        // holes (windows-1250 has none at all).
        #expect(LegacyEncoding.windows1253.decode([0xAA, 0xD2, 0xFF]) == "\u{FFFD}\u{FFFD}\u{FFFD}")
        #expect(LegacyEncoding.windows1250.high.allSatisfy { $0 != 0 })
        // A mapped C1 position decodes to that control, not to U+FFFD.
        #expect(LegacyEncoding.windows1250.decode([0x81]) == "\u{81}")
    }

    @Test func asciiIsIdenticalInEveryPage() {
        for encoding in [
            LegacyEncoding.windows874, .windows1250, .windows1251, .windows1252, .windows1253,
            .windows1254, .windows1255, .windows1256, .windows1257, .windows1258,
        ] {
            let ascii = Array(UInt8(0)...UInt8(127))
            #expect(
                encoding.decode(ascii).unicodeScalars.map(\.value) == ascii.map(UInt32.init),
                "\(encoding.name) altered the ASCII range")
            #expect(encoding.high.count == 128)
        }
    }

    @Test func unknownCodepagesAndCharsetsFallBack() {
        #expect(codepageEncoding(65001) == .windows1252)
        #expect(codepageEncoding(0) == .windows1252)
        #expect(codepageEncoding(1251) == .windows1251)
        // Charsets 0 and 1 defer to the document's own page.
        #expect(charsetEncoding(0, default: .windows1251) == .windows1251)
        #expect(charsetEncoding(1, default: .windows1250) == .windows1250)
        #expect(charsetEncoding(99, default: .windows1253) == .windows1253)
        #expect(charsetEncoding(204, default: .windows1252) == .windows1251)
    }

    /// `\uN` carries code points above U+7FFF as negative 16-bit values, and
    /// pairs of them as UTF-16 surrogates.
    @Test func unicodeEscapesDecode() throws {
        #expect(try markdown(doc(u(1055) + u(1088) + u(1080))) == "При\n")
        // Word writes anything past U+7FFF as a negative 16-bit value:
        // -3600 + 65536 = 0xF1F0.
        #expect(try markdown(doc(u(-3600))) == "\u{F1F0}\n")
        // A surrogate pair combines into one astral scalar.
        #expect(try markdown(doc(u(55349) + u(56485))) == "\u{1D4A5}\n")
        // A lone high surrogate is held and never emitted.
        #expect(try markdown(doc(u(55349) + "tail")) == "tail\n")
    }

    /// `\ucN` sets how many fallback characters follow each `\uN`.
    @Test func unicodeFallbackSkipHonorsUc() throws {
        #expect(try markdown(doc(bs + "uc3" + u(1055) + "xxtail")) == "Пtail\n")
        // With \uc0 there is no fallback to skip, and the space after the
        // control word is the word's own delimiter.
        #expect(try markdown(doc(bs + "uc0" + u(1055, "") + " tail")) == "Пtail\n")
    }
}

@Suite struct ShiftJisTests {
    /// The WHATWG algorithm's three regions: ASCII, halfwidth katakana, and
    /// lead/trail pairs resolved through the `index jis0208` table.
    @Test func decodesEachRegion() {
        let sjis = LegacyEncoding.shiftJis
        #expect(sjis.decode(Array("plain ASCII".utf8)) == "plain ASCII")
        // 0xA1...0xDF are halfwidth katakana, one byte each.
        #expect(sjis.decode([0xB1, 0xB2, 0xB3]) == "ｱｲｳ")
        // Lead/trail pairs: 0x82 0xA0 is HIRAGANA A, 0x93 0xFA is 日.
        #expect(sjis.decode([0x82, 0xA0]) == "あ")
        #expect(sjis.decode([0x93, 0xFA, 0x96, 0x7B]) == "日本")
        // Both trail-byte ranges resolve, on either side of the 0x7F gap:
        // the offset applied to the trail byte differs across it.
        #expect(sjis.decode([0x81, 0x40]) == "\u{3000}")
        #expect(sjis.decode([0x81, 0x80]) == "\u{00F7}")
    }

    /// Bytes that name nothing become U+FFFD rather than disappearing.
    @Test func unmappedSequencesReplace() {
        let sjis = LegacyEncoding.shiftJis
        // A lead byte with no trail byte at all.
        #expect(sjis.decode([0x82]) == "\u{FFFD}")
        // A lead byte followed by an invalid trail: the trail byte is not
        // consumed, so it is reprocessed on its own (here, a space).
        #expect(sjis.decode([0x82, 0x20]) == "\u{FFFD} ")
        // 0xA0 and 0xFD...0xFF are not lead bytes.
        #expect(sjis.decode([0xA0]) == "\u{FFFD}")
        #expect(sjis.decode([0xFD]) == "\u{FFFD}")
        // A pointer inside the index that the index leaves unmapped.
        #expect(sjis.decode([0x82, 0x40]) == "\u{FFFD}")
    }

    /// Pointers 8836...10715 map straight into the private use area rather
    /// than through the index.
    @Test func privateUseRangeIsArithmetic() {
        // lead 0xF0, trail 0x40 -> pointer 8836 -> U+E000.
        #expect(LegacyEncoding.shiftJis.decode([0xF0, 0x40]) == "\u{E000}")
    }

    /// The code page and font charset both select it.
    @Test func selectedByCodepageAndCharset() {
        #expect(codepageEncoding(932) == .shiftJis)
        #expect(charsetEncoding(128, default: .windows1252) == .shiftJis)
    }
}
