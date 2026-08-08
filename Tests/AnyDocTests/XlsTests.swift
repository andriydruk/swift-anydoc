// BIFF8 record and value decoding, the parts of the binary workbook path
// that the fixture corpus alone would leave unexercised.
import Testing

@testable import AnyDoc

@Suite struct BiffRecordTests {
    /// A record's declared length frames it; a `CONTINUE` (0x003C) that
    /// follows is folded in rather than surfaced as its own record.
    @Test func continueRecordsFoldIntoTheirOwner() throws {
        var stream: [UInt8] = []
        stream += [0xFC, 0x00, 0x03, 0x00, 1, 2, 3]  // SST, 3 bytes
        stream += [0x3C, 0x00, 0x02, 0x00, 4, 5]  // CONTINUE, 2 bytes
        stream += [0x3C, 0x00, 0x01, 0x00, 6]  // CONTINUE, 1 byte
        stream += [0x0A, 0x00, 0x00, 0x00]  // EOF
        var iterator = BiffRecordIterator(stream)
        var record = try #require(try iterator.next())
        #expect(record.type == 0x00FC)
        #expect(Array(record.data) == [1, 2, 3])
        #expect(record.continuations.count == 2)
        // The macro captures its argument immutably, so the mutating step
        // happens first and its result is what gets asserted.
        var advanced = record.continueRecord()
        #expect(advanced)
        #expect(Array(record.data) == [4, 5])
        advanced = record.continueRecord()
        #expect(advanced)
        #expect(Array(record.data) == [6])
        advanced = record.continueRecord()
        #expect(!advanced)
        let next = try #require(try iterator.next())
        #expect(next.type == 0x000A)
        #expect(try iterator.next() == nil)
    }

    /// A record whose payload runs past the end of the stream is malformed,
    /// not a clean stop — recovering there would silently drop everything
    /// after it.
    @Test func truncatedRecordsThrow() {
        var iterator = BiffRecordIterator([0x03, 0x02, 0xFF, 0x00, 1, 2])
        #expect(throws: ConvertError.self) { try iterator.next() }
        var shortHeader = BiffRecordIterator([0x03, 0x02])
        #expect(throws: ConvertError.self) { try shortHeader.next() }
    }

    @Test func skipCrossesContinuations() throws {
        var record = BiffRecord(
            type: 0, data: [1, 2, 3][...], continuations: [[4, 5][...], [6, 7, 8][...]])
        // Three bytes from the payload, two from the first continuation,
        // one from the second — which is where the cursor lands.
        try record.skip(6)
        #expect(Array(record.data) == [7, 8])
        #expect(throws: ConvertError.self) { try record.skip(99) }
    }
}

@Suite struct XlsValueTests {
    /// RK packs either a 30-bit integer or the top 30 bits of a double,
    /// either optionally divided by 100.
    @Test func rkValuesDecode() {
        func rk(_ ixfe: UInt16, _ word: UInt32) -> SheetValue {
            var bytes: [UInt8] = [UInt8(ixfe & 0xFF), UInt8(ixfe >> 8)]
            bytes += [
                UInt8(word & 0xFF), UInt8((word >> 8) & 0xFF), UInt8((word >> 16) & 0xFF),
                UInt8((word >> 24) & 0xFF),
            ]
            return rkValue(bytes[...], [], false)
        }
        // Integer, no division: value << 2 | 0b10.
        #expect(formatSheetValue(rk(0, UInt32(bitPattern: (42 << 2) | 0b10))) == "42")
        // Integer with the /100 flag, not a multiple of 100: becomes a double.
        #expect(formatSheetValue(rk(0, UInt32(bitPattern: (4250 << 2) | 0b11))) == "42.5")
        // Integer with the /100 flag and a clean multiple: stays an integer.
        #expect(formatSheetValue(rk(0, UInt32(bitPattern: (4200 << 2) | 0b11))) == "42")
        // Negative integers keep their sign through the arithmetic shift.
        #expect(formatSheetValue(rk(0, UInt32(bitPattern: (-17 << 2) | 0b10))) == "-17")
        // A double keeps only its top 30 mantissa bits, so it is lossy.
        let bits = 1.5.bitPattern
        #expect(formatSheetValue(rk(0, UInt32(truncatingIfNeeded: bits >> 32) & 0xFFFF_FFFC)) == "1.5")
    }

    /// An integer cell prints without a decimal point; a double goes through
    /// the spreadsheet float rules.
    @Test func integersAndDoublesPrintDifferently() {
        #expect(formatSheetValue(.int(42)) == "42")
        #expect(formatSheetValue(.int(-1)) == "-1")
        #expect(formatSheetValue(.float(42)) == "42")
        #expect(formatSheetValue(.float(42.5)) == "42.5")
    }

    @Test func biffErrorCodesMapToNames() {
        let expected: [(UInt8, String)] = [
            (0x00, "Null"), (0x07, "Div0"), (0x0F, "Value"), (0x17, "Ref"), (0x1D, "Name"),
            (0x24, "Num"), (0x2A, "NA"), (0x2B, "GettingData"),
        ]
        for (code, name) in expected {
            #expect(cellErrorValue(code).map(formatSheetValue) == "#\(name)")
        }
        // An unlisted code is not an error value the reference recognizes.
        #expect(cellErrorValue(0x99) == nil)
    }

    @Test func reservedFormatCodesClassify() {
        for code in UInt16(14)...UInt16(22) {
            #expect(builtinFormatByCode(code) == .dateTime)
        }
        #expect(builtinFormatByCode(45) == .dateTime)
        #expect(builtinFormatByCode(47) == .dateTime)
        #expect(builtinFormatByCode(46) == .timeDelta)
        #expect(builtinFormatByCode(0) == .other)
        #expect(builtinFormatByCode(164) == .other)
    }
}

@Suite struct XlsStringTests {
    /// BIFF8 strings carry a flag choosing between one byte per character
    /// and UTF-16LE.
    @Test func biff8StringsDecodeBothWidths() {
        // cch = 5, flags = 0 (compressed), then five ASCII bytes.
        var compressed: [UInt8] = [5, 0, 0]
        compressed += Array("plain".utf8)
        #expect(parseXlUnicodeString(compressed[...], .utf16le, .biff8) == "plain")

        // cch = 2, flags = 1 (uncompressed), then two UTF-16LE units.
        let uncompressed: [UInt8] = [2, 0, 1, 0x14, 0x04, 0x10, 0x04]
        #expect(parseXlUnicodeString(uncompressed[...], .utf16le, .biff8) == "ДА")
    }

    /// A compressed byte is the low half of a UTF-16 unit, so it maps to the
    /// scalar of that value — not through any legacy code page.
    @Test func compressedBytesAreLatin1() {
        let bytes: [UInt8] = [0xE9, 0xFF]
        let decoded = XlsEncoding.utf16le.decode(bytes[...], 2, highByte: false)
        #expect(decoded.text == "\u{E9}\u{FF}")
        #expect(decoded.chars == 2)
        #expect(decoded.bytes == 2)
    }

    /// A declared character count longer than the data available stops at
    /// the data, reporting how much it actually consumed.
    @Test func shortStreamsStopAtTheirEnd() {
        let bytes: [UInt8] = [0x41, 0x42]
        let decoded = XlsEncoding.utf16le.decode(bytes[...], 10, highByte: false)
        #expect(decoded.text == "AB")
        #expect(decoded.chars == 2)
        let wide = XlsEncoding.utf16le.decode(bytes[...], 10, highByte: true)
        #expect(wide.chars == 1)
        #expect(wide.bytes == 2)
    }

    /// A pre-BIFF8 workbook names a single-byte code page and has no
    /// per-string width flag.
    @Test func legacyWorkbooksUseTheirCodepage() {
        let bytes: [UInt8] = [0xC4, 0xE0]
        let decoded = XlsEncoding.singleByte(.windows1251).decode(bytes[...], 2, highByte: nil)
        #expect(decoded.text == "Да")
    }
}
