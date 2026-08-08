/// The PDF object syntax (ISO 32000-1 §7.2-7.3), ported from `lopdf`'s
/// parser so recovery behavior on malformed files matches rather than merely
/// resembling it.
///
/// Every entry point is total: the parser returns `nil` on anything it
/// cannot read and never traps, because the byte offsets it follows come
/// from the file itself.

/// Literal-string bracket nesting cap. A crafted file can otherwise nest
/// parentheses until the parser recurses off the stack.
let pdfMaxBracket = 100

struct PdfLexer {
    let bytes: [UInt8]
    var pos: Int

    init(_ bytes: [UInt8], at pos: Int = 0) {
        self.bytes = bytes
        self.pos = min(max(pos, 0), bytes.count)
    }

    // MARK: character classes

    /// PDF whitespace, which includes NUL and form feed.
    static func isWhitespace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x00 || c == 0x0C
    }

    /// The characters that end a token: `()<>[]{}/%`.
    static func isDelimiter(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
            UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
            UInt8(ascii: "/"), UInt8(ascii: "%"):
            return true
        default:
            return false
        }
    }

    static func isRegular(_ c: UInt8) -> Bool { !isWhitespace(c) && !isDelimiter(c) }

    private static func isDigit(_ c: UInt8) -> Bool {
        c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    // MARK: cursor primitives

    var atEnd: Bool { pos >= bytes.count }
    private var peek: UInt8? { pos < bytes.count ? bytes[pos] : nil }

    private mutating func take(_ expected: [UInt8]) -> Bool {
        guard pos + expected.count <= bytes.count else { return false }
        for (i, byte) in expected.enumerated() where bytes[pos + i] != byte { return false }
        pos += expected.count
        return true
    }

    private mutating func takeEol() -> Bool {
        if take([0x0D, 0x0A]) { return true }
        if take([0x0A]) { return true }
        if take([0x0D]) { return true }
        return false
    }

    /// Whitespace only — no comments. Used where the grammar says "space".
    mutating func skipWhitespace() {
        while let c = peek, Self.isWhitespace(c) { pos += 1 }
    }

    /// Whitespace and comments, which are equivalent to whitespace anywhere
    /// a token boundary is allowed.
    mutating func skipSpace() {
        while true {
            let before = pos
            skipWhitespace()
            if peek == UInt8(ascii: "%") {
                while let c = peek, c != 0x0A, c != 0x0D { pos += 1 }
                _ = takeEol()
            }
            if pos == before { return }
        }
    }

    // MARK: objects

    /// One direct object. Indirect references (`N G R`) are recognized here;
    /// streams are not, because they need the document to resolve `/Length`.
    mutating func parseObject() -> PdfObject? {
        skipSpace()
        guard let c = peek else { return nil }
        switch c {
        case UInt8(ascii: "/"):
            return parseName().map { PdfObject.name($0) }
        case UInt8(ascii: "("):
            return parseLiteralString().map { PdfObject.string($0, .literal) }
        case UInt8(ascii: "["):
            return parseArray().map { PdfObject.array($0) }
        case UInt8(ascii: "<"):
            if pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: "<") {
                return parseDictionary().map { PdfObject.dictionary($0) }
            }
            return parseHexString().map { PdfObject.string($0, .hexadecimal) }
        case UInt8(ascii: "t"):
            return take(Array("true".utf8)) ? .boolean(true) : nil
        case UInt8(ascii: "f"):
            return take(Array("false".utf8)) ? .boolean(false) : nil
        case UInt8(ascii: "n"):
            return take(Array("null".utf8)) ? .null : nil
        default:
            return parseNumberOrReference()
        }
    }

    /// A name: `/` then regular characters, with `#hh` hex escapes.
    mutating func parseName() -> [UInt8]? {
        guard take([UInt8(ascii: "/")]) else { return nil }
        var out: [UInt8] = []
        while let c = peek {
            if c == UInt8(ascii: "#") {
                guard pos + 2 < bytes.count, let hi = Self.hexValue(bytes[pos + 1]),
                    let lo = Self.hexValue(bytes[pos + 2])
                else { break }
                out.append(hi << 4 | lo)
                pos += 3
            } else if Self.isRegular(c) {
                out.append(c)
                pos += 1
            } else {
                break
            }
        }
        return out
    }

    /// A literal string: `(...)`, with balanced inner parentheses kept
    /// verbatim, backslash escapes, and a line continuation that produces
    /// nothing.
    mutating func parseLiteralString() -> [UInt8]? {
        guard take([UInt8(ascii: "(")]) else { return nil }
        var out: [UInt8] = []
        var depth = 0
        while let c = peek {
            switch c {
            case UInt8(ascii: ")"):
                pos += 1
                if depth == 0 { return out }
                depth -= 1
                out.append(c)
            case UInt8(ascii: "("):
                // Nesting past the cap is a crafted file, not a document.
                if depth >= pdfMaxBracket { return nil }
                depth += 1
                out.append(c)
                pos += 1
            case UInt8(ascii: "\\"):
                pos += 1
                guard let escaped = peek else { return nil }
                switch escaped {
                case UInt8(ascii: "n"): out.append(0x0A); pos += 1
                case UInt8(ascii: "r"): out.append(0x0D); pos += 1
                case UInt8(ascii: "t"): out.append(0x09); pos += 1
                case UInt8(ascii: "b"): out.append(0x08); pos += 1
                case UInt8(ascii: "f"): out.append(0x0C); pos += 1
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    // Up to three octal digits; the spec says to ignore
                    // overflow past a byte.
                    var value = 0
                    var digits = 0
                    while digits < 3, let d = peek, d >= UInt8(ascii: "0"), d <= UInt8(ascii: "7") {
                        value = value * 8 + Int(d - UInt8(ascii: "0"))
                        pos += 1
                        digits += 1
                    }
                    out.append(UInt8(truncatingIfNeeded: value))
                case 0x0A, 0x0D:
                    // A backslash before a line break continues the line.
                    _ = takeEol()
                default:
                    out.append(escaped)
                    pos += 1
                }
            case 0x0A, 0x0D:
                // Raw line breaks survive, normalized by the EOL rule.
                let start = pos
                _ = takeEol()
                out.append(contentsOf: bytes[start..<pos])
            default:
                out.append(c)
                pos += 1
            }
        }
        // Unterminated.
        return nil
    }

    /// A hex string: `<...>`, whitespace-tolerant, odd trailing digit
    /// treated as if followed by `0`.
    mutating func parseHexString() -> [UInt8]? {
        guard take([UInt8(ascii: "<")]) else { return nil }
        var out: [UInt8] = []
        var pending: UInt8?
        while let c = peek {
            if c == UInt8(ascii: ">") {
                pos += 1
                if let pending { out.append(pending << 4) }
                return out
            }
            if Self.isWhitespace(c) {
                pos += 1
                continue
            }
            guard let value = Self.hexValue(c) else { return nil }
            pos += 1
            if let high = pending {
                out.append(high << 4 | value)
                pending = nil
            } else {
                pending = value
            }
        }
        return nil
    }

    mutating func parseArray() -> [PdfObject]? {
        guard take([UInt8(ascii: "[")]) else { return nil }
        var out: [PdfObject] = []
        while true {
            skipSpace()
            if peek == UInt8(ascii: "]") {
                pos += 1
                return out
            }
            guard let object = parseObject() else { return nil }
            out.append(object)
        }
    }

    mutating func parseDictionary() -> PdfDictionary? {
        guard take([UInt8(ascii: "<"), UInt8(ascii: "<")]) else { return nil }
        var dict = PdfDictionary()
        while true {
            skipSpace()
            if take([UInt8(ascii: ">"), UInt8(ascii: ">")]) { return dict }
            guard let key = parseName(), let value = parseObject() else { return nil }
            // A repeated key keeps its first position; the later value wins,
            // which is what a reader that overwrites in place does.
            dict[key] = value
        }
    }

    /// A number, or an indirect reference when the shape `N G R` follows.
    private mutating func parseNumberOrReference() -> PdfObject? {
        let start = pos
        guard let first = parseNumberToken() else { return nil }
        // A reference needs two non-negative integers and an `R`.
        if case .integer(let number) = first, number >= 0 {
            let afterFirst = pos
            skipSpace()
            if let generation = parseNumberToken(), case .integer(let gen) = generation, gen >= 0,
                gen <= Int64(UInt16.max)
            {
                skipSpace()
                if take([UInt8(ascii: "R")]), peek.map({ !Self.isRegular($0) }) ?? true {
                    return .reference(
                        PdfObjectId(
                            number: UInt32(truncatingIfNeeded: number),
                            generation: UInt16(truncatingIfNeeded: gen)))
                }
            }
            pos = afterFirst
        }
        if pos == start { return nil }
        return first
    }

    /// One numeric token: integer or real, with an optional sign.
    mutating func parseNumberToken() -> PdfObject? {
        let start = pos
        var sawSign = false
        if let c = peek, c == UInt8(ascii: "+") || c == UInt8(ascii: "-") {
            pos += 1
            sawSign = true
        }
        var intDigits = 0
        while let c = peek, Self.isDigit(c) {
            pos += 1
            intDigits += 1
        }
        var isReal = false
        var fracDigits = 0
        if peek == UInt8(ascii: ".") {
            isReal = true
            pos += 1
            while let c = peek, Self.isDigit(c) {
                pos += 1
                fracDigits += 1
            }
        }
        // A bare sign or a lone `.` is not a number.
        if intDigits == 0 && fracDigits == 0 {
            pos = start
            return nil
        }
        let text = String(decoding: bytes[start..<pos], as: UTF8.self)
        if isReal {
            guard let value = Float(text) else {
                pos = start
                return nil
            }
            return .real(value)
        }
        guard let value = Int64(text) else {
            // Out of range for an integer: PDF readers fall back to a real.
            guard let value = Float(text) else {
                pos = start
                return nil
            }
            return .real(value)
        }
        _ = sawSign
        return .integer(value)
    }

    /// An unsigned integer token, for the structural grammar (object
    /// headers, xref entries) where signs are not allowed.
    mutating func parseUnsignedInt() -> Int? {
        let start = pos
        var value = 0
        var digits = 0
        while let c = peek, Self.isDigit(c) {
            // Saturate rather than trap: these come from the file.
            if value < Int.max / 16 {
                value = value * 10 + Int(c - UInt8(ascii: "0"))
            }
            pos += 1
            digits += 1
        }
        if digits == 0 {
            pos = start
            return nil
        }
        return value
    }

    /// A bare keyword made of regular characters (`obj`, `endobj`, `stream`).
    mutating func parseKeyword() -> [UInt8]? {
        skipSpace()
        var out: [UInt8] = []
        while let c = peek, Self.isRegular(c) {
            out.append(c)
            pos += 1
        }
        return out.isEmpty ? nil : out
    }

    /// The `stream` keyword and the EOL that must follow it, positioning the
    /// cursor at the first data byte.
    mutating func takeStreamKeyword() -> Bool {
        skipSpace()
        guard take(Array("stream".utf8)) else { return false }
        // The spec allows CR LF or LF, but producers emit trailing spaces.
        while peek == UInt8(ascii: " ") { pos += 1 }
        _ = takeEol()
        return true
    }
}
