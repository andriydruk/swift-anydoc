/// Legacy code-page decoding for the formats that name one: RTF's
/// `\ansicpgN` and `\fcharsetN`, and binary DOC's character sets.
///
/// The single-byte Windows pages and shift_jis are implemented. The other
/// multi-byte CJK pages (gbk, euc-kr, big5) are not: a document selecting
/// one is decoded with the document's default page and the substitution is
/// logged, so the text is wrong but present rather than silently dropped.

/// A legacy code page: a single-byte table, or a multi-byte decoder.
struct LegacyEncoding: Equatable {
    /// The WHATWG label, used for identity and for logs.
    let name: String
    /// Scalars for bytes 0x80...0xFF; `0` marks an unmapped position. Empty
    /// for a multi-byte page, which decodes through `decode` instead.
    let high: [UInt16]
    /// Whether this page is the multi-byte shift_jis rather than a table.
    let isShiftJis: Bool

    init(name: String, high: [UInt16], isShiftJis: Bool = false) {
        self.name = name
        self.high = high
        self.isShiftJis = isShiftJis
    }

    static func == (a: LegacyEncoding, b: LegacyEncoding) -> Bool { a.name == b.name }

    /// shift_jis, decoded per the WHATWG algorithm.
    static let shiftJis = LegacyEncoding(name: "shift_jis", high: [], isShiftJis: true)

    /// Decode bytes, replacing unmapped positions with U+FFFD — the lossy
    /// behavior of the reference's `Encoding::decode`.
    func decode(_ bytes: [UInt8]) -> String {
        if isShiftJis {
            return decodeShiftJis(bytes)
        }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(bytes.count)
        for byte in bytes {
            out.append(scalar(byte))
        }
        return String(out)
    }

    /// The scalar one byte denotes. Meaningful only for single-byte pages;
    /// a multi-byte page needs the surrounding bytes.
    func scalar(_ byte: UInt8) -> Unicode.Scalar {
        if byte < 0x80 || high.isEmpty {
            return byte < 0x80 ? Unicode.Scalar(byte) : "\u{FFFD}"
        }
        let mapped = high[Int(byte - 0x80)]
        guard mapped != 0, let scalar = Unicode.Scalar(mapped) else {
            return "\u{FFFD}"
        }
        return scalar
    }
}

/// WHATWG shift_jis decoding: ASCII below 0x80, halfwidth katakana in
/// 0xA1...0xDF, and a lead/trail pair that resolves to an `index jis0208`
/// pointer — or, in one arithmetic range, straight to a private-use scalar.
private func decodeShiftJis(_ bytes: [UInt8]) -> String {
    var out = String.UnicodeScalarView()
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        let byte = bytes[i]
        i += 1
        if byte <= 0x80 {
            out.append(Unicode.Scalar(byte))
            continue
        }
        if byte >= 0xA1 && byte <= 0xDF {
            out.append(Unicode.Scalar(0xFF61 - 0xA1 + UInt32(byte))!)
            continue
        }
        guard byte >= 0x81 && byte <= 0xFC && byte != 0xA0, i < bytes.count else {
            out.append("\u{FFFD}")
            continue
        }
        let trail = bytes[i]
        guard (0x40...0x7E).contains(trail) || (0x80...0xFC).contains(trail) else {
            // The trail byte is not part of this character; it is
            // reprocessed as a lead of its own.
            out.append("\u{FFFD}")
            continue
        }
        i += 1
        let leadOffset: UInt32 = byte < 0xA0 ? 0x81 : 0xC1
        let offset: UInt32 = trail < 0x7F ? 0x40 : 0x41
        let pointer = Int((UInt32(byte) - leadOffset) * 188 + UInt32(trail) - offset)
        // 8836...10715 maps arithmetically into the private use area.
        if pointer >= 8836 && pointer <= 10715 {
            out.append(Unicode.Scalar(0xE000 - 8836 + UInt32(pointer))!)
            continue
        }
        guard pointer >= 0, pointer < jis0208Index.count, jis0208Index[pointer] != 0,
            let scalar = Unicode.Scalar(jis0208Index[pointer])
        else {
            out.append("\u{FFFD}")
            continue
        }
        out.append(scalar)
    }
    return String(out)
}

/// `\ansicpgN` and the DOC code-page fields. Anything unrecognized is
/// windows-1252, the reference's fallback.
func codepageEncoding(_ codepage: UInt32) -> LegacyEncoding {
    switch codepage {
    case 874: return .windows874
    case 1250: return .windows1250
    case 1251: return .windows1251
    case 1253: return .windows1253
    case 1254: return .windows1254
    case 1255: return .windows1255
    case 1256: return .windows1256
    case 1257: return .windows1257
    case 1258: return .windows1258
    case 932: return .shiftJis
    case 936, 949, 950: return unimplementedMultiByte(String(codepage))
    default: return .windows1252
    }
}

/// `\fcharsetN` on a font-table entry. Charsets 0 (ANSI) and 1 (default)
/// defer to the document's own code page.
func charsetEncoding(_ charset: Int32, default defaultEncoding: LegacyEncoding)
    -> LegacyEncoding
{
    switch charset {
    case 0, 1: return defaultEncoding
    case 128: return .shiftJis
    case 129: return unimplementedMultiByte("euc-kr")
    case 134: return unimplementedMultiByte("gbk")
    case 136: return unimplementedMultiByte("big5")
    case 161: return .windows1253
    case 162: return .windows1254
    case 163: return .windows1258
    case 177: return .windows1255
    case 178, 179, 180: return .windows1256
    case 186: return .windows1257
    case 204: return .windows1251
    case 222: return .windows874
    case 238: return .windows1250
    default: return defaultEncoding
    }
}

/// A multi-byte page the port has not reached yet (Phase 5). Substituting
/// windows-1252 keeps the surrounding document readable and the ASCII
/// subset correct; the log says the text of these runs is not.
private func unimplementedMultiByte(_ name: String) -> LegacyEncoding {
    Log.warn("decoding \(name) text as windows-1252: multi-byte code pages are not ported yet")
    return .windows1252
}
