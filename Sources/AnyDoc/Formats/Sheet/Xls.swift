/// Binary Excel workbooks (`.xls`, BIFF5/BIFF8) over the MS-CFB container.
///
/// A port of the slice of calamine's `xls.rs` (MIT) that anydoc uses: sheet
/// names, cell values and merged regions. The whole workbook is parsed at
/// open time, as the reference does, because BIFF records for every sheet
/// live in one stream and the sheet boundaries are byte offsets into it.
///
/// Formula *token* parsing is deliberately absent — anydoc never asks for
/// formulas, only for the cached values that accompany them.

/// One BIFF record: its type, its payload, and the payloads of any
/// `CONTINUE` records that follow it.
struct BiffRecord {
    var type: UInt16
    var data: ArraySlice<UInt8>
    var continuations: [ArraySlice<UInt8>]

    /// Move to the next continuation payload. False when none remain.
    mutating func continueRecord() -> Bool {
        if continuations.isEmpty { return false }
        data = continuations.removeFirst()
        return true
    }

    /// Skip `len` bytes, crossing into continuations as needed.
    mutating func skip(_ len: Int) throws {
        var remaining = len
        while remaining > 0 {
            if data.isEmpty, !continueRecord() {
                throw ConvertError.malformed("unreadable workbook: continue record too short")
            }
            let take = min(remaining, data.count)
            data = data.dropFirst(take)
            remaining -= take
        }
    }
}

/// Walks a BIFF stream, folding `CONTINUE` (0x003C) records into the record
/// they extend.
struct BiffRecordIterator {
    private let bytes: [UInt8]
    private var pos: Int

    init(_ bytes: [UInt8], at offset: Int = 0) {
        self.bytes = bytes
        self.pos = min(max(offset, 0), bytes.count)
    }

    /// The next record, or `nil` at a clean end of stream. A record whose
    /// header or payload runs past the end is a malformed stream, not an
    /// early stop: the reference fails the whole workbook there, and
    /// recovering instead would silently drop the records that follow.
    mutating func next() throws -> BiffRecord? {
        if pos == bytes.count { return nil }
        guard pos + 4 <= bytes.count else {
            throw ConvertError.malformed("unreadable workbook: end of stream (record header)")
        }
        let type = readU16(bytes, pos)
        let len = Int(readU16(bytes, pos + 2))
        guard pos + 4 + len <= bytes.count else {
            throw ConvertError.malformed("unreadable workbook: end of stream (record length)")
        }
        let data = bytes[(pos + 4)..<(pos + 4 + len)]
        pos += 4 + len

        var continuations: [ArraySlice<UInt8>] = []
        while pos + 4 <= bytes.count, readU16(bytes, pos) == 0x003C {
            let contLen = Int(readU16(bytes, pos + 2))
            guard pos + 4 + contLen <= bytes.count else {
                throw ConvertError.malformed(
                    "unreadable workbook: end of stream (continue record length)")
            }
            continuations.append(bytes[(pos + 4)..<(pos + 4 + contLen)])
            pos += 4 + contLen
        }
        return BiffRecord(type: type, data: data, continuations: continuations)
    }

    /// Stop the walk without treating the remaining bytes as truncated: the
    /// EOF record ends a substream, and what follows belongs to the next one.
    mutating func finish() {
        pos = bytes.count
    }
}

// Little-endian reads that return 0 rather than trapping past the end: BIFF
// payloads are attacker-controlled and every field is length-checked by its
// own record handler.

private func readU16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
    guard at >= 0, at + 2 <= bytes.count else { return 0 }
    return UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
}

func readU16(_ bytes: ArraySlice<UInt8>, _ at: Int) -> UInt16 {
    let i = bytes.startIndex + at
    guard at >= 0, i + 2 <= bytes.endIndex else { return 0 }
    return UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
}

private func readU32(_ bytes: ArraySlice<UInt8>, _ at: Int) -> UInt32 {
    let i = bytes.startIndex + at
    guard at >= 0, i + 4 <= bytes.endIndex else { return 0 }
    return UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8) | (UInt32(bytes[i + 2]) << 16)
        | (UInt32(bytes[i + 3]) << 24)
}

private func readI32(_ bytes: ArraySlice<UInt8>, _ at: Int) -> Int32 {
    Int32(bitPattern: readU32(bytes, at))
}

func readF64(_ bytes: ArraySlice<UInt8>, _ at: Int) -> Double {
    let i = bytes.startIndex + at
    guard at >= 0, i + 8 <= bytes.endIndex else { return 0 }
    var bits: UInt64 = 0
    for k in (0..<8).reversed() {
        bits = (bits << 8) | UInt64(bytes[i + k])
    }
    return Double(bitPattern: bits)
}

/// BIFF version. Only the string layouts differ in the slice anydoc uses.
enum Biff {
    case biff2, biff3, biff4, biff5, biff8

    var isBiff8: Bool { self == .biff8 }
}

/// How a workbook's byte strings decode. BIFF8 declares code page 1200
/// (UTF-16LE) and carries a per-string compressed/uncompressed flag;
/// earlier versions name a legacy single-byte page.
enum XlsEncoding {
    case utf16le
    case singleByte(LegacyEncoding)
    /// A multi-byte legacy page the port has not reached yet (Phase 5's
    /// remaining CJK work); text decodes as windows-1252 and says so.
    case unsupportedMultiByte

    static func forCodepage(_ codepage: UInt16) -> XlsEncoding {
        switch codepage {
        case 1200, 0: return .utf16le
        case 932: return .singleByte(.shiftJis)
        case 936, 949, 950: return .unsupportedMultiByte
        case 65001: return .singleByte(.windows1252)  // UTF-8: ASCII-compatible
        default: return .singleByte(codepageEncoding(UInt32(codepage)))
        }
    }

    /// The effective high-byte flag: a single-byte page has no such
    /// distinction, everything else defaults to compressed.
    private func effectiveHighByte(_ highByte: Bool?) -> Bool? {
        if let highByte { return highByte }
        switch self {
        case .singleByte: return nil
        case .utf16le, .unsupportedMultiByte: return false
        }
    }

    /// Decode `len` characters from `stream`, returning the text plus how
    /// many characters and bytes were consumed.
    func decode(_ stream: ArraySlice<UInt8>, _ len: Int, highByte: Bool?)
        -> (text: String, chars: Int, bytes: Int)
    {
        switch effectiveHighByte(highByte) {
        case nil:
            let l = min(stream.count, len)
            let taken = Array(stream.prefix(l))
            guard case .singleByte(let encoding) = self else {
                return (String(decoding: taken, as: UTF8.self), l, l)
            }
            return (encoding.decode(taken), l, l)
        case .some(false):
            // Compressed: each byte is the low half of a UTF-16 unit.
            let l = min(stream.count, len)
            var out = String.UnicodeScalarView()
            out.reserveCapacity(l)
            for byte in stream.prefix(l) {
                out.append(Unicode.Scalar(byte))
            }
            return (String(out), l, l)
        case .some(true):
            let l = min(stream.count / 2, len)
            let taken = Array(stream.prefix(2 * l))
            return (decodeUtf16(taken[...], littleEndian: true), l, 2 * l)
        }
    }
}

/// A workbook parsed far enough to answer for every sheet.
struct XlsWorkbook {
    struct SheetData {
        var name: String
        var cells: [SheetCell]
        var mergedRegions: [SheetRegion]
    }

    private(set) var sheets: [SheetData] = []

    init(bytes: [UInt8]) throws {
        let file: CompoundFile
        do {
            file = try CompoundFile(bytes: bytes)
        } catch let e as ConvertError {
            throw ConvertError.malformed("unreadable workbook: \(e.message)")
        }
        // The workbook stream's name varies with the producer and its era.
        var stream: [UInt8]?
        for name in ["Workbook", "Book", "WORKBOOK", "BOOK"] {
            if let found = file.readStream([name]) {
                stream = found
                break
            }
        }
        guard let stream else {
            throw ConvertError.malformed("unreadable workbook: stream 'Workbook' not found")
        }
        if UInt64(stream.count) > Limits.maxEntryBytes {
            throw ConvertError.resourceLimit(
                limit: "max_entry_bytes",
                detail: "workbook stream declares \(stream.count) bytes")
        }
        try parse(stream)
    }

    private mutating func parse(_ stream: [UInt8]) throws {
        var sheetOffsets: [(offset: Int, name: String)] = []
        var strings: [String] = []
        var formatCodes: [UInt16: CellFormat] = [:]
        var xfs: [UInt16] = []
        var biff = Biff.biff8
        var encoding = XlsEncoding.utf16le
        var is1904 = false

        var globals = BiffRecordIterator(stream)
        while var record = try globals.next() {
            switch record.type {
            // FilePass: the workbook is encrypted.
            case 0x002F where readU16(record.data, 0) != 0:
                throw ConvertError.encrypted
            // CodePage
            case 0x0042:
                encoding = XlsEncoding.forCodepage(readU16(record.data, 0))
            // DateMode
            case 0x0022 where readU16(record.data, 0) == 1:
                is1904 = true
            // Format: a custom number-format code and its id.
            case 0x041E:
                if let parsed = parseFormatRecord(&record, encoding, biff) {
                    formatCodes[parsed.id] = detectCustomNumberFormat(parsed.code)
                }
            // XF: the cell format table, read for its number-format id only.
            case 0x00E0:
                guard record.data.count >= 4 else { break }
                xfs.append(readU16(record.data, 2))
            // BoundSheet8: a sheet's name and the offset of its BOF.
            case 0x0085:
                if let sheet = parseBoundSheet(&record, encoding, biff) {
                    sheetOffsets.append(sheet)
                }
            // BOF: fixes the BIFF version for everything that follows.
            case 0x0809:
                biff = parseBof(record.data)
            // SST: the shared string table.
            case 0x00FC:
                strings = try parseSst(&record, encoding)
            // EOF ends the globals substream.
            case 0x000A:
                globals.finish()
            default:
                break
            }
        }

        // A cell's `ixfe` indexes the XF table; the XF's number-format id
        // selects a custom code, or a reserved one when it names none.
        let formats: [CellFormat] = xfs.map { id in
            formatCodes[id] ?? builtinFormatByCode(id)
        }

        for sheet in sheetOffsets {
            var cells: [SheetCell] = []
            var merged: [SheetRegion] = []
            var formulaPos: (row: UInt32, col: UInt32) = (0, 0)
            var records = BiffRecordIterator(stream, at: sheet.offset)
            while let record = try records.next() {
                let data = record.data
                switch record.type {
                // Number
                case 0x0203:
                    guard data.count >= 14 else { break }
                    cells.append(
                        SheetCell(
                            row: UInt32(readU16(data, 0)), col: UInt32(readU16(data, 2)),
                            value: numericValue(
                                readF64(data, 6), formats[safe: Int(readU16(data, 4))], is1904)))
                // Label and RString: an inline string cell.
                case 0x0204, 0x00D6:
                    guard data.count >= 6 else { break }
                    let text = parseXlUnicodeString(data.dropFirst(6), encoding, biff)
                    cells.append(
                        SheetCell(
                            row: UInt32(readU16(data, 0)), col: UInt32(readU16(data, 2)),
                            value: .string(text)))
                // BoolErr
                case 0x0205:
                    guard data.count >= 8 else { break }
                    let i = data.startIndex
                    let value: SheetValue
                    switch data[i + 7] {
                    case 0x00:
                        value = .bool(data[i + 6] != 0)
                    case 0x01:
                        guard let error = cellErrorValue(data[i + 6]) else {
                            throw ConvertError.malformed(
                                "unreadable workbook: unrecognized error 0x"
                                    + String(data[i + 6], radix: 16))
                        }
                        value = error
                    case let discriminator:
                        throw ConvertError.malformed(
                            "unreadable workbook: unrecognized fError 0x"
                                + String(discriminator, radix: 16))
                    }
                    cells.append(
                        SheetCell(
                            row: UInt32(readU16(data, 0)), col: UInt32(readU16(data, 2)),
                            value: value))
                // String: the cached text of the formula in the record before.
                case 0x0207:
                    cells.append(
                        SheetCell(
                            row: formulaPos.row, col: formulaPos.col,
                            value: .string(parseXlUnicodeString(data, encoding, biff))))
                // RK: a packed number.
                case 0x027E:
                    guard data.count >= 10 else { break }
                    cells.append(
                        SheetCell(
                            row: UInt32(readU16(data, 0)), col: UInt32(readU16(data, 2)),
                            value: rkValue(data.dropFirst(4), formats, is1904)))
                // LabelSst: an index into the shared string table.
                case 0x00FD:
                    guard data.count >= 10 else { break }
                    let index = Int(readU32(data, 6))
                    if let text = strings[safe: index] {
                        cells.append(
                            SheetCell(
                                row: UInt32(readU16(data, 0)), col: UInt32(readU16(data, 2)),
                                value: .string(text)))
                    }
                // MulRk: a run of packed numbers across one row.
                case 0x00BD:
                    parseMulRk(data, into: &cells, formats, is1904)
                // MergeCells
                case 0x00E5:
                    parseMergeCells(data, into: &merged)
                // Formula: its cached value, unless that value is a string
                // (which arrives in the String record that follows).
                case 0x0006:
                    guard data.count >= 20 else { break }
                    formulaPos = (row: UInt32(readU16(data, 0)), col: UInt32(readU16(data, 2)))
                    let format = formats[safe: Int(readU16(data, 4))]
                    if let value = formulaCachedValue(data[(data.startIndex + 6)...], format, is1904)
                    {
                        cells.append(
                            SheetCell(row: formulaPos.row, col: formulaPos.col, value: value))
                    }
                case 0x000A:
                    records.finish()
                default:
                    break
                }
            }
            sheets.append(SheetData(name: sheet.name, cells: cells, mergedRegions: merged))
        }
    }
}

private func parseBof(_ data: ArraySlice<UInt8>) -> Biff {
    let version = readU16(data, 0)
    let dt = data.count >= 4 ? readU16(data, 2) : 0
    switch version {
    case 0x0200, 0x0002, 0x0007: return .biff2
    case 0x0300: return .biff3
    case 0x0400: return .biff4
    case 0x0500: return .biff5
    case 0x0600: return .biff8
    case 0: return dt == 0x1000 ? .biff5 : .biff8
    default: return .biff8
    }
}

/// BoundSheet8: the sheet's substream offset and its name.
private func parseBoundSheet(
    _ record: inout BiffRecord, _ encoding: XlsEncoding, _ biff: Biff
) -> (offset: Int, name: String)? {
    guard record.data.count >= 6 else { return nil }
    let offset = Int(readU32(record.data, 0))
    record.data = record.data.dropFirst(6)
    let name = parseShortString(&record, encoding, biff)
    return (offset: offset, name: name)
}

/// `ShortXLUnicodeString` [MS-XLS 2.5.240]: a one-byte character count,
/// then in BIFF8 a flags byte whose low bit marks uncompressed text.
private func parseShortString(
    _ record: inout BiffRecord, _ encoding: XlsEncoding, _ biff: Biff
) -> String {
    guard let first = record.data.first else { return "" }
    let cch = Int(first)
    record.data = record.data.dropFirst()
    var highByte: Bool?
    if biff.isBiff8 {
        guard let flags = record.data.first else { return "" }
        highByte = flags & 0x1 != 0
        record.data = record.data.dropFirst()
    }
    let decoded = encoding.decode(record.data, cch, highByte: highByte)
    record.data = record.data.dropFirst(decoded.bytes)
    return decoded.text
}

/// `XLUnicodeString` [MS-XLS 2.5.294]: a two-byte character count, then in
/// BIFF8 a flags byte.
func parseXlUnicodeString(
    _ data: ArraySlice<UInt8>, _ encoding: XlsEncoding, _ biff: Biff
) -> String {
    let headerLen = biff.isBiff8 ? 3 : 2
    guard data.count >= headerLen else { return "" }
    let cch = Int(readU16(data, 0))
    let highByte: Bool? = biff.isBiff8 ? (data[data.startIndex + 2] & 0x1 != 0) : nil
    return encoding.decode(data.dropFirst(headerLen), cch, highByte: highByte).text
}

/// Format record: a number-format id and its code string.
private func parseFormatRecord(
    _ record: inout BiffRecord, _ encoding: XlsEncoding, _ biff: Biff
) -> (id: UInt16, code: String)? {
    guard record.data.count >= 2 else { return nil }
    let id = readU16(record.data, 0)
    record.data = record.data.dropFirst(2)
    // BIFF8 stores the code as a full XLUnicodeString, earlier versions as
    // a short one.
    if biff.isBiff8 {
        guard record.data.count >= 3 else { return nil }
        let cch = Int(readU16(record.data, 0))
        let highByte = record.data[record.data.startIndex + 2] & 0x1 != 0
        let decoded = encoding.decode(record.data.dropFirst(3), cch, highByte: highByte)
        return (id: id, code: decoded.text)
    }
    return (id: id, code: parseShortString(&record, encoding, biff))
}

/// SST: `cstTotal`/`cstUnique` headers, then one rich extended string each.
private func parseSst(_ record: inout BiffRecord, _ encoding: XlsEncoding) throws -> [String] {
    guard record.data.count >= 8 else {
        throw ConvertError.malformed("unreadable workbook: sst record too short")
    }
    record.data = record.data.dropFirst(8)
    var out: [String] = []
    while !record.data.isEmpty || record.continueRecord() {
        out.append(try readRichExtendedString(&record, encoding))
    }
    return out
}

/// `XLUnicodeRichExtendedString` [MS-XLS 2.5.293].
private func readRichExtendedString(
    _ record: inout BiffRecord, _ encoding: XlsEncoding
) throws -> String {
    // A spec violation the reference tolerates: at minimum the count and
    // flags should be present.
    if record.data.isEmpty { return "" }
    guard record.data.count >= 3 else {
        throw ConvertError.malformed("unreadable workbook: rich extended string too short")
    }
    let cch = Int(readU16(record.data, 0))
    let flags = record.data[record.data.startIndex + 2]
    record.data = record.data.dropFirst(3)
    let highByte = flags & 0x1 != 0

    var formatRuns = 0
    if flags & 0x8 != 0 {
        guard record.data.count >= 2 else {
            throw ConvertError.malformed("unreadable workbook: rich string run count missing")
        }
        formatRuns = Int(readU16(record.data, 0))
        record.data = record.data.dropFirst(2)
    }
    var extRstBytes = 0
    if flags & 0x4 != 0 {
        guard record.data.count >= 4 else {
            throw ConvertError.malformed("unreadable workbook: rich string ext size missing")
        }
        extRstBytes = Int(readI32(record.data, 0))
        record.data = record.data.dropFirst(4)
    }
    let text = try readDbcs(&record, encoding, cch, highByte)
    // The run and phonetic blocks carry formatting, not content.
    guard formatRuns <= Int.max / 4 else {
        throw ConvertError.malformed("unreadable workbook: implausible rich string run count")
    }
    try record.skip(formatRuns * 4)
    guard extRstBytes >= 0 else {
        throw ConvertError.malformed("unreadable workbook: negative ext string size")
    }
    try record.skip(extRstBytes)
    return text
}

/// Read `len` characters, following `CONTINUE` records. Each continuation
/// restates the compressed/uncompressed flag in its first byte.
private func readDbcs(
    _ record: inout BiffRecord, _ encoding: XlsEncoding, _ len: Int, _ highByte: Bool
) throws -> String {
    var remaining = len
    var highByte = highByte
    var out = ""
    while remaining > 0 {
        let decoded = encoding.decode(record.data, remaining, highByte: highByte)
        out += decoded.text
        record.data = record.data.dropFirst(decoded.bytes)
        remaining -= decoded.chars
        if remaining > 0 {
            guard record.continueRecord(), let flags = record.data.first else {
                throw ConvertError.malformed("unreadable workbook: end of stream (dbcs)")
            }
            highByte = flags & 0x1 != 0
            record.data = record.data.dropFirst()
        }
        // A continuation that yields nothing would spin forever.
        if decoded.chars == 0 && decoded.bytes == 0 && record.data.isEmpty { return out }
    }
    return out
}

/// An RK value: a 30-bit integer or the top 30 bits of a double, either
/// optionally divided by 100.
func rkValue(
    _ rk: ArraySlice<UInt8>, _ formats: [CellFormat], _ is1904: Bool
) -> SheetValue {
    guard rk.count >= 6 else { return .empty }
    let i = rk.startIndex
    let d100 = (rk[i + 2] & 1) != 0
    let isInt = (rk[i + 2] & 2) != 0
    let format = formats[safe: Int(readU16(rk, 0))]

    var word = [UInt8](repeating: 0, count: 8)
    word[4] = rk[i + 2] & 0xFC
    word[5] = rk[i + 3]
    word[6] = rk[i + 4]
    word[7] = rk[i + 5]
    if isInt {
        let raw = Int64(readI32(word[4..<8], 0)) >> 2
        if d100 && raw % 100 != 0 {
            return numericValue(Double(raw) / 100.0, format, is1904)
        }
        return integerValue(d100 ? raw / 100 : raw, format, is1904)
    }
    let value = readF64(word[...], 0)
    return numericValue(d100 ? value / 100.0 : value, format, is1904)
}

private func parseMulRk(
    _ data: ArraySlice<UInt8>, into cells: inout [SheetCell], _ formats: [CellFormat],
    _ is1904: Bool
) {
    guard data.count >= 6 else { return }
    let row = UInt32(readU16(data, 0))
    let colFirst = Int(readU16(data, 2))
    let colLast = Int(readU16(data, data.count - 2))
    guard colLast >= colFirst, data.count == 6 + 6 * (colLast - colFirst + 1) else { return }
    var offset = 4
    for col in colFirst...colLast {
        cells.append(
            SheetCell(
                row: row, col: UInt32(col),
                value: rkValue(data[(data.startIndex + offset)..<(data.startIndex + offset + 6)],
                    formats, is1904)))
        offset += 6
    }
}

private func parseMergeCells(_ data: ArraySlice<UInt8>, into merged: inout [SheetRegion]) {
    let count = Int(readU16(data, 0))
    for i in 0..<count {
        let offset = 2 + i * 8
        guard offset + 8 <= data.count else { return }
        merged.append(
            SheetRegion(
                startRow: UInt32(readU16(data, offset)),
                startCol: UInt32(readU16(data, offset + 4)),
                endRow: UInt32(readU16(data, offset + 2)),
                endCol: UInt32(readU16(data, offset + 6))))
    }
}

/// A formula's cached value. `nil` means the value is a string that arrives
/// in the following String record.
private func formulaCachedValue(
    _ data: ArraySlice<UInt8>, _ format: CellFormat?, _ is1904: Bool
) -> SheetValue? {
    guard data.count >= 8 else { return nil }
    let i = data.startIndex
    // A cached non-numeric value is tagged by its first byte and marked by
    // 0xFFFF in the last two.
    if data[i + 6] == 0xFF, data[i + 7] == 0xFF {
        switch data[i] {
        case 0x00: return nil
        case 0x01: return .bool(data[i + 2] != 0)
        case 0x02: return cellErrorValue(data[i + 2])
        case 0x03: return .string("")
        default: return nil
        }
    }
    return numericValue(readF64(data, 0), format, is1904)
}

/// BIFF error codes to the model's error names.
func cellErrorValue(_ code: UInt8) -> SheetValue? {
    switch code {
    case 0x00: return .error("Null")
    case 0x07: return .error("Div0")
    case 0x0F: return .error("Value")
    case 0x17: return .error("Ref")
    case 0x1D: return .error("Name")
    case 0x24: return .error("Num")
    case 0x2A: return .error("NA")
    case 0x2B: return .error("GettingData")
    default: return nil
    }
}

/// A double under a number format: a date, a duration, or a plain number.
func numericValue(_ value: Double, _ format: CellFormat?, _ is1904: Bool) -> SheetValue {
    switch format {
    case .dateTime:
        return .dateTime(ExcelDateTime(value: value, isDuration: false, is1904: is1904))
    case .timeDelta:
        return .dateTime(ExcelDateTime(value: value, isDuration: true, is1904: is1904))
    default:
        return .float(value)
    }
}

/// An integer under a number format. Unlike a double, an integer that is not
/// a date stays an integer, which prints without a decimal point.
func integerValue(_ value: Int64, _ format: CellFormat?, _ is1904: Bool) -> SheetValue {
    switch format {
    case .dateTime:
        return .dateTime(ExcelDateTime(value: Double(value), isDuration: false, is1904: is1904))
    case .timeDelta:
        return .dateTime(ExcelDateTime(value: Double(value), isDuration: true, is1904: is1904))
    default:
        return .int(value)
    }
}

extension XlsWorkbook: SheetSource {
    var sheetNames: [String] { sheets.map(\.name) }

    func cells(ofSheet index: Int) throws -> [SheetCell] {
        sheets[safe: index]?.cells ?? []
    }

    func mergedRegions(ofSheet index: Int) throws -> [SheetRegion] {
        sheets[safe: index]?.mergedRegions ?? []
    }
}
