/// `ToUnicode` CMap parsing (ISO 32000-1 §9.10.3), ported from
/// pdf-inspector's `tounicode.rs`.
///
/// A CMap maps the character codes a content stream shows to Unicode. The
/// reference scans the decoded CMap as text rather than running a PostScript
/// interpreter over it, because the constructs that matter — the codespace
/// ranges and the `bfchar`/`bfrange` sections — are a fixed shape.

struct PdfToUnicodeCMap {
    /// Code to the string it denotes. A code can map to several scalars:
    /// ligatures decompose that way.
    fileprivate(set) var map: [UInt32: String] = [:]
    /// How many bytes a code occupies, from `begincodespacerange`. Fonts
    /// with a simple encoding use one; CID fonts use two.
    fileprivate(set) var codeByteLength: Int = 1

    /// The string a code maps to, if any.
    func lookup(_ code: UInt32) -> String? { map[code] }

    var isEmpty: Bool { map.isEmpty }
}

/// Parse a decoded `ToUnicode` stream.
func parsePdfToUnicode(_ content: [UInt8]) -> PdfToUnicodeCMap {
    var cmap = PdfToUnicodeCMap()
    // The CMap is ASCII-ish; anything outside is inside a hex string and is
    // reached through the hex scanner rather than the text one.
    let text = Array(content)

    // The codespace range fixes the code width. Its entries are pairs of
    // hex strings whose digit count gives the byte width.
    if let section = sectionBody(text, begin: "begincodespacerange", end: "endcodespacerange") {
        var scanner = PdfHexScanner(text, range: section)
        if let first = scanner.nextHexDigits() {
            cmap.codeByteLength = max(1, min(4, first.count / 2))
        }
    }

    // `beginbfchar`: pairs of <src> <dst>.
    var searchFrom = 0
    while let section = sectionBody(text, begin: "beginbfchar", end: "endbfchar", from: searchFrom) {
        var scanner = PdfHexScanner(text, range: section)
        while let src = scanner.nextHexDigits(), let dst = scanner.nextHexDigits() {
            guard let code = hexDigitsToCode(src) else { continue }
            cmap.setMapping(code, hexDigitsToString(dst))
        }
        searchFrom = section.upperBound
    }

    // `beginbfrange`: <lo> <hi> <dst>, or <lo> <hi> [<d1> <d2> ...].
    searchFrom = 0
    while let section = sectionBody(text, begin: "beginbfrange", end: "endbfrange", from: searchFrom)
    {
        var scanner = PdfHexScanner(text, range: section)
        while let loDigits = scanner.nextHexDigits() {
            guard let hiDigits = scanner.nextHexDigits(), let lo = hexDigitsToCode(loDigits),
                let hi = hexDigitsToCode(hiDigits)
            else { break }
            // A range longer than any real font is a crafted file.
            let count = hi >= lo ? Int(hi - lo) + 1 : 0
            guard count > 0, count <= 65_536 else {
                _ = scanner.skipDestination()
                continue
            }
            switch scanner.nextDestination() {
            case .single(let digits):
                // The destination increments with the code, in its last
                // UTF-16 unit.
                let base = hexDigitsToUnits(digits)
                for offset in 0..<count {
                    var units = base
                    if var last = units.last {
                        last = UInt16(truncatingIfNeeded: Int(last) + offset)
                        units[units.count - 1] = last
                    }
                    cmap.setMapping(lo + UInt32(offset), unitsToString(units))
                }
            case .array(let entries):
                for (offset, digits) in entries.enumerated() where offset < count {
                    cmap.setMapping(lo + UInt32(offset), hexDigitsToString(digits))
                }
            case .none:
                break
            }
        }
        searchFrom = section.upperBound
    }
    return cmap
}

extension PdfToUnicodeCMap {
    fileprivate mutating func setMapping(_ code: UInt32, _ value: String) {
        // An empty destination means "no mapping"; keeping it would erase
        // text that a later section defines.
        if value.isEmpty { return }
        map[code] = value
    }
}

/// The byte range between a `begin...`/`end...` keyword pair.
private func sectionBody(
    _ text: [UInt8], begin: String, end: String, from: Int = 0
) -> Range<Int>? {
    guard let beginAt = find(text, Array(begin.utf8), from: from) else { return nil }
    let bodyStart = beginAt + begin.utf8.count
    guard let endAt = find(text, Array(end.utf8), from: bodyStart) else { return nil }
    return bodyStart..<endAt
}

private func find(_ haystack: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
    guard !needle.isEmpty, from >= 0, haystack.count >= needle.count else { return nil }
    var i = max(0, from)
    while i + needle.count <= haystack.count {
        var matched = true
        for k in 0..<needle.count where haystack[i + k] != needle[k] {
            matched = false
            break
        }
        if matched { return i }
        i += 1
    }
    return nil
}

/// Walks `<hex>` tokens and `[...]` destination arrays inside a CMap section.
private struct PdfHexScanner {
    let text: [UInt8]
    var pos: Int
    let end: Int

    init(_ text: [UInt8], range: Range<Int>) {
        self.text = text
        self.pos = range.lowerBound
        self.end = min(range.upperBound, text.count)
    }

    enum Destination {
        case single([UInt8])
        case array([[UInt8]])
        case none
    }

    /// The digits of the next `<...>` token.
    mutating func nextHexDigits() -> [UInt8]? {
        while pos < end, text[pos] != UInt8(ascii: "<") {
            // A `[` means the next token is a destination array, not a plain
            // hex string; the caller handles it.
            if text[pos] == UInt8(ascii: "[") { return nil }
            pos += 1
        }
        guard pos < end else { return nil }
        pos += 1
        var digits: [UInt8] = []
        while pos < end, text[pos] != UInt8(ascii: ">") {
            let c = text[pos]
            if !PdfLexer.isWhitespace(c) { digits.append(c) }
            pos += 1
        }
        if pos < end { pos += 1 }
        return digits
    }

    /// The destination of a `bfrange` entry: one hex string or an array.
    mutating func nextDestination() -> Destination {
        while pos < end, PdfLexer.isWhitespace(text[pos]) { pos += 1 }
        guard pos < end else { return .none }
        if text[pos] == UInt8(ascii: "[") {
            pos += 1
            var entries: [[UInt8]] = []
            while pos < end, text[pos] != UInt8(ascii: "]") {
                if text[pos] == UInt8(ascii: "<") {
                    pos += 1
                    var digits: [UInt8] = []
                    while pos < end, text[pos] != UInt8(ascii: ">") {
                        if !PdfLexer.isWhitespace(text[pos]) { digits.append(text[pos]) }
                        pos += 1
                    }
                    if pos < end { pos += 1 }
                    entries.append(digits)
                } else {
                    pos += 1
                }
            }
            if pos < end { pos += 1 }
            return .array(entries)
        }
        guard let digits = nextHexDigits() else { return .none }
        return .single(digits)
    }

    /// Consume a destination without interpreting it.
    mutating func skipDestination() -> Bool {
        _ = nextDestination()
        return true
    }
}

/// Hex digits to the numeric code they denote, capped at four bytes.
private func hexDigitsToCode(_ digits: [UInt8]) -> UInt32? {
    guard !digits.isEmpty, digits.count <= 8 else { return nil }
    var value: UInt32 = 0
    for digit in digits {
        guard let nibble = hexNibble(digit) else { return nil }
        value = (value << 4) | UInt32(nibble)
    }
    return value
}

/// Hex digits to UTF-16 code units, two bytes each.
private func hexDigitsToUnits(_ digits: [UInt8]) -> [UInt16] {
    var units: [UInt16] = []
    var index = 0
    while index + 3 < digits.count {
        var unit: UInt16 = 0
        var valid = true
        for k in 0..<4 {
            guard let nibble = hexNibble(digits[index + k]) else {
                valid = false
                break
            }
            unit = (unit << 4) | UInt16(nibble)
        }
        if !valid { break }
        units.append(unit)
        index += 4
    }
    return units
}

private func hexDigitsToString(_ digits: [UInt8]) -> String {
    unitsToString(hexDigitsToUnits(digits))
}

/// UTF-16 units to a string, pairing surrogates. Unpaired ones are dropped
/// rather than becoming replacement characters: a CMap that names half a
/// pair is naming nothing.
private func unitsToString(_ units: [UInt16]) -> String {
    var out = String.UnicodeScalarView()
    var i = 0
    while i < units.count {
        let unit = units[i]
        if unit >= 0xD800, unit <= 0xDBFF, i + 1 < units.count, units[i + 1] >= 0xDC00,
            units[i + 1] <= 0xDFFF
        {
            let value = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(units[i + 1] - 0xDC00)
            if let scalar = Unicode.Scalar(value) { out.append(scalar) }
            i += 2
            continue
        }
        if unit >= 0xD800, unit <= 0xDFFF {
            i += 1
            continue
        }
        if let scalar = Unicode.Scalar(unit) { out.append(scalar) }
        i += 1
    }
    return String(out)
}

private func hexNibble(_ c: UInt8) -> UInt8? {
    switch c {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
    default: return nil
    }
}
