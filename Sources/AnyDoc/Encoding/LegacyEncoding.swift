/// Legacy code-page decoding for the formats that name one: RTF's
/// `\ansicpgN` and `\fcharsetN`, and binary DOC's character sets.
///
/// Only the single-byte Windows pages are implemented. The multi-byte CJK
/// pages (shift_jis, gbk, euc-kr, big5) arrive with Phase 5, which needs the
/// same decoders for binary `.doc`; until then a document selecting one is
/// decoded with the document's default page and the substitution is logged,
/// so the text is wrong but present rather than silently dropped.

/// A single-byte legacy code page.
struct LegacyEncoding: Equatable {
    /// The WHATWG label, used for identity and for logs.
    let name: String
    /// Scalars for bytes 0x80...0xFF; `0` marks an unmapped position.
    let high: [UInt16]

    static func == (a: LegacyEncoding, b: LegacyEncoding) -> Bool { a.name == b.name }

    /// Decode bytes, replacing unmapped positions with U+FFFD — the lossy
    /// behavior of the reference's `Encoding::decode`.
    func decode(_ bytes: [UInt8]) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(bytes.count)
        for byte in bytes {
            out.append(scalar(byte))
        }
        return String(out)
    }

    func scalar(_ byte: UInt8) -> Unicode.Scalar {
        if byte < 0x80 {
            return Unicode.Scalar(byte)
        }
        let mapped = high[Int(byte - 0x80)]
        guard mapped != 0, let scalar = Unicode.Scalar(mapped) else {
            return "\u{FFFD}"
        }
        return scalar
    }
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
    case 932, 936, 949, 950: return unimplementedMultiByte(String(codepage))
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
    case 128: return unimplementedMultiByte("shift_jis")
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
