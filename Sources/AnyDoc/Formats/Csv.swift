/// CSV and friends (semicolon, tab, pipe delimited).
///
/// Field content is preserved as written (RFC 4180: spaces are part of the
/// field); only control characters are cleaned. Encoding is detected from
/// the BOM (UTF-8, UTF-16LE/BE), then UTF-8, then Windows-1252. The
/// delimiter is chosen by trial-parsing candidates and scoring record
/// consistency, so delimiters inside quoted fields don't skew the choice. The
/// format marks no header row, so the shape of the data decides whether the
/// first record is one.

func parseCsv(_ bytes: [UInt8]) throws -> Document {
    let text = decodeCsvBytes(bytes)
    let input = Array(text.utf8)
    let delimiter = sniffDelimiter(input)

    var reader = CsvRecordReader(bytes: input, delimiter: delimiter)
    var rows: [[Cell]] = []
    while let record = reader.next() {
        let cells = record.map { Cell.fromInlines([.plain(cleanText($0))]) }
        rows.append(cells)
    }

    var doc = Document()
    var table = Table.fromRows(rows, headerRows: 0, kind: .data)
    table.headerRows = resolveHeaderRows(table, declared: 0)
    if !table.grid.isEmpty {
        doc.blocks.append(.table(table))
    }
    return doc
}

private func decodeCsvBytes(_ bytes: [UInt8]) -> String {
    if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
        return decodeUtf16(bytes[...], littleEndian: true)
    }
    if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
        return decodeUtf16(bytes[...], littleEndian: false)
    }
    var slice = bytes[...]
    if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
        slice = bytes[3...]
    }
    if let s = validateUtf8(slice) {
        return s
    }
    return decodeWindows1252(slice)
}

/// Trial-parse each candidate over the leading records and score by field
/// consistency; comma wins ties.
func sniffDelimiter(_ bytes: [UInt8]) -> UInt8 {
    let candidates: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: ";"), 0x09, UInt8(ascii: "|")]
    var best: (UInt8, UInt32) = (UInt8(ascii: ","), 0)
    for d in candidates {
        // Sample complete records: sampling physical lines would cut a quoted
        // multiline field in half.
        var reader = CsvRecordReader(bytes: bytes, delimiter: d)
        var counts: [Int] = []
        while counts.count < 20, let record = reader.next() {
            counts.append(record.count)
        }
        if counts.isEmpty { continue }
        // Modal field count and how dominant it is. Frequency ties break
        // toward the wider record shape so the choice never depends on map
        // iteration order.
        var tally: [Int: UInt32] = [:]
        for c in counts {
            tally[c, default: 0] += 1
        }
        let (modal, freq) = tally.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })!
        if modal < 2 {
            continue // a delimiter that never splits carries no signal
        }
        // Consistency first, then wider records break the tie.
        let score = freq * 1000 + UInt32(min(modal, 500))
        if score > best.1 {
            best = (d, score)
        }
    }
    return best.0
}

/// Streaming record reader over UTF-8 bytes, matching the Rust `csv` crate's
/// lenient defaults (`flexible`, no headers, `"` quoting with `""` escapes,
/// CRLF terminators): empty lines yield no record, quoting is recognized only
/// at field start, a closing quote followed by ordinary bytes resumes the
/// field unquoted, and EOF inside quotes ends the record.
struct CsvRecordReader {
    let bytes: [UInt8]
    let delimiter: UInt8
    private var pos = 0

    private static let quote = UInt8(ascii: "\"")
    private static let cr = UInt8(ascii: "\r")
    private static let lf = UInt8(ascii: "\n")

    init(bytes: [UInt8], delimiter: UInt8) {
        self.bytes = bytes
        self.delimiter = delimiter
    }

    mutating func next() -> [String]? {
        // Skip empty lines between records; a terminator run yields nothing.
        while pos < bytes.count, bytes[pos] == Self.cr || bytes[pos] == Self.lf {
            pos += 1
        }
        if pos >= bytes.count {
            return nil
        }
        var record: [String] = []
        var field: [UInt8] = []
        while true {
            if pos >= bytes.count {
                record.append(String(decoding: field, as: UTF8.self))
                return record
            }
            // Quoting is only recognized at the exact start of a field.
            if field.isEmpty, bytes[pos] == Self.quote {
                if endsField(afterQuoted: &field, in: &record) {
                    return record
                }
                continue
            }
            let b = bytes[pos]
            pos += 1
            if b == delimiter {
                record.append(String(decoding: field, as: UTF8.self))
                field = []
            } else if b == Self.cr || b == Self.lf {
                if b == Self.cr, pos < bytes.count, bytes[pos] == Self.lf {
                    pos += 1
                }
                record.append(String(decoding: field, as: UTF8.self))
                return record
            } else {
                field.append(b)
            }
        }
    }

    /// Consume a quoted field body starting at the opening quote. Returns
    /// `true` when the field also ended the record (terminator or EOF), with
    /// the field already appended; `false` when parsing continues (field
    /// ended at a delimiter, or resumed unquoted after the closing quote).
    private mutating func endsField(afterQuoted field: inout [UInt8], in record: inout [String]) -> Bool {
        pos += 1 // opening quote
        while pos < bytes.count {
            let b = bytes[pos]
            pos += 1
            if b != Self.quote {
                field.append(b)
                continue
            }
            // A quote inside a quoted field: doubled means a literal quote.
            if pos < bytes.count, bytes[pos] == Self.quote {
                field.append(Self.quote)
                pos += 1
                continue
            }
            // Closing quote: delimiter ends the field, a terminator ends the
            // record, and anything else (lenient mode) resumes the field
            // unquoted with that byte included.
            if pos >= bytes.count {
                record.append(String(decoding: field, as: UTF8.self))
                return true
            }
            let after = bytes[pos]
            if after == delimiter {
                pos += 1
                record.append(String(decoding: field, as: UTF8.self))
                field = []
                return false
            }
            if after == Self.cr || after == Self.lf {
                pos += 1
                if after == Self.cr, pos < bytes.count, bytes[pos] == Self.lf {
                    pos += 1
                }
                record.append(String(decoding: field, as: UTF8.self))
                return true
            }
            field.append(after)
            pos += 1
            return false
        }
        // EOF inside the quoted field.
        record.append(String(decoding: field, as: UTF8.self))
        return true
    }
}
