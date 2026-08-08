/// Byte-to-text decoding without Foundation, matching `encoding_rs` (WHATWG
/// Encoding Standard) semantics: malformed sequences become U+FFFD, and
/// windows-1252's unmapped positions fall back to the C1 control they name.

/// Decode UTF-16 with the given endianness, skipping a leading BOM. Unpaired
/// surrogates and a trailing odd byte decode to U+FFFD, as in `encoding_rs`.
func decodeUtf16(_ bytes: ArraySlice<UInt8>, littleEndian: Bool) -> String {
    var out = String.UnicodeScalarView()
    out.reserveCapacity(bytes.count / 2)
    var units: [UInt16] = []
    units.reserveCapacity(bytes.count / 2)
    var i = bytes.startIndex
    while i + 1 < bytes.endIndex {
        let lo = UInt16(bytes[i])
        let hi = UInt16(bytes[i + 1])
        units.append(littleEndian ? (hi << 8 | lo) : (lo << 8 | hi))
        i += 2
    }
    let oddTrailingByte = i < bytes.endIndex

    var j = 0
    if units.first == 0xFEFF { j = 1 }
    while j < units.count {
        let unit = units[j]
        if unit < 0xD800 || unit > 0xDFFF {
            out.append(Unicode.Scalar(unit)!)
            j += 1
        } else if unit >= 0xDC00 {
            // Lone low surrogate.
            out.append("\u{FFFD}")
            j += 1
        } else if j + 1 < units.count, (0xDC00...0xDFFF).contains(units[j + 1]) {
            let value = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(units[j + 1] - 0xDC00)
            out.append(Unicode.Scalar(value)!)
            j += 2
        } else {
            // High surrogate without a low one.
            out.append("\u{FFFD}")
            j += 1
        }
    }
    if oddTrailingByte {
        out.append("\u{FFFD}")
    }
    return String(out)
}

/// Decode windows-1252. Every byte maps: 0x80–0x9F follow the WHATWG index
/// (unmapped positions fall back to the C1 control of the same value).
func decodeWindows1252(_ bytes: ArraySlice<UInt8>) -> String {
    var out = String.UnicodeScalarView()
    out.reserveCapacity(bytes.count)
    for byte in bytes {
        out.append(windows1252Scalar(byte))
    }
    return String(out)
}

func windows1252Scalar(_ byte: UInt8) -> Unicode.Scalar {
    LegacyEncoding.windows1252.scalar(byte)
}

/// Strict UTF-8 validation: the decoded string, or `nil` on any malformed
/// sequence (mirrors `std::str::from_utf8`: no overlongs, no surrogates,
/// nothing past U+10FFFF).
func validateUtf8(_ bytes: ArraySlice<UInt8>) -> String? {
    var i = bytes.startIndex
    let end = bytes.endIndex
    while i < end {
        let b = bytes[i]
        if b < 0x80 {
            i += 1
        } else if b & 0xE0 == 0xC0 {
            guard b >= 0xC2, i + 1 < end, bytes[i + 1] & 0xC0 == 0x80 else { return nil }
            i += 2
        } else if b & 0xF0 == 0xE0 {
            guard i + 2 < end else { return nil }
            let b1 = bytes[i + 1], b2 = bytes[i + 2]
            guard b1 & 0xC0 == 0x80, b2 & 0xC0 == 0x80 else { return nil }
            if b == 0xE0, b1 < 0xA0 { return nil }  // overlong
            if b == 0xED, b1 >= 0xA0 { return nil }  // surrogate
            i += 3
        } else if b & 0xF8 == 0xF0 {
            guard i + 3 < end else { return nil }
            let b1 = bytes[i + 1], b2 = bytes[i + 2], b3 = bytes[i + 3]
            guard b1 & 0xC0 == 0x80, b2 & 0xC0 == 0x80, b3 & 0xC0 == 0x80 else { return nil }
            if b == 0xF0, b1 < 0x90 { return nil }  // overlong
            if b == 0xF4, b1 >= 0x90 { return nil }  // past U+10FFFF
            if b > 0xF4 { return nil }
            i += 4
        } else {
            return nil
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}
