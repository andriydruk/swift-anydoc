/// Position-explicit RTF lexer. `\binN` consumes exactly N raw bytes, so
/// binary payloads can never corrupt group state; unbalanced groups are the
/// caller's to recover (deliberately, with a log).

enum RtfToken {
    case open
    case close
    /// Control word with optional numeric parameter.
    case word(name: String, param: Int32?)
    /// Control symbol (`\~`, `\*`, `\{`, ...).
    case symbol(UInt8)
    /// `\'xx` hex-escaped byte in the current code page.
    case hex(UInt8)
    /// One plain text byte.
    case byte(UInt8)
    /// The raw payload of a `\binN` control.
    case bin(ArraySlice<UInt8>)
}

struct RtfLexer {
    private let bytes: [UInt8]
    private(set) var pos = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func next() -> RtfToken? {
        while true {
            guard pos < bytes.count else { return nil }
            let b = bytes[pos]
            pos += 1
            switch b {
            case UInt8(ascii: "{"): return .open
            case UInt8(ascii: "}"): return .close
            case UInt8(ascii: "\\"): return control()
            // Line breaks and NULs are layout in the source, not content.
            case 0x0D, 0x0A, 0x00: continue
            default: return .byte(b)
            }
        }
    }

    private mutating func control() -> RtfToken? {
        guard pos < bytes.count else { return nil }
        let b = bytes[pos]
        if !isAsciiAlpha(b) {
            pos += 1
            // A reader treats `\` before CR or LF as a paragraph mark; the
            // trailing LF of a CRLF pair is skipped as plain-text whitespace.
            if b == 0x0D || b == 0x0A {
                return .word(name: "par", param: nil)
            }
            if b == UInt8(ascii: "'") {
                guard pos + 1 < bytes.count else { return nil }
                let hi = hexValue(bytes[pos])
                let lo = hexValue(bytes[pos + 1])
                guard let hi, let lo else {
                    // Truncated escape: recover by treating it as literal.
                    return .byte(UInt8(ascii: "'"))
                }
                pos += 2
                return .hex(hi &* 16 &+ lo)
            }
            return .symbol(b)
        }
        let start = pos
        while pos < bytes.count, isAsciiAlpha(bytes[pos]) {
            pos += 1
        }
        let name = String(decoding: bytes[start..<pos], as: UTF8.self)
        var param: Int32?
        var negative = false
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "-") {
            negative = true
            pos += 1
        }
        let numStart = pos
        while pos < bytes.count, isAsciiDigit(bytes[pos]) {
            pos += 1
        }
        if pos > numStart {
            // Parse wide, then clamp: a parameter with more digits than an
            // i32 holds saturates rather than wrapping or trapping.
            var value: Int64 = 0
            var overflowed = false
            for byte in bytes[numStart..<pos] {
                let (scaled, mulOverflow) = value.multipliedReportingOverflow(by: 10)
                let digit = Int64(byte - UInt8(ascii: "0"))
                let (sum, addOverflow) = mulOverflow
                    ? (Int64.max, true) : scaled.addingReportingOverflow(digit)
                if mulOverflow || addOverflow {
                    overflowed = true
                    value = Int64.max
                    break
                }
                value = sum
            }
            if overflowed {
                param = negative ? Int32.min : Int32.max
            } else {
                let signed = negative ? -value : value
                param = Int32(clamping: signed)
            }
        } else if negative {
            pos -= 1
        }
        // One space after a control word is part of the control.
        if pos < bytes.count, bytes[pos] == UInt8(ascii: " ") {
            pos += 1
        }
        if name == "bin" {
            let n = Int(max(param ?? 0, 0))
            let end = min(pos.addingReportingOverflow(n).partialValue, bytes.count)
            let payload = bytes[pos..<max(end, pos)]
            pos = max(end, pos)
            return .bin(payload)
        }
        return .word(name: name, param: param)
    }
}

private func isAsciiAlpha(_ b: UInt8) -> Bool {
    (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
        || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
}

private func isAsciiDigit(_ b: UInt8) -> Bool {
    b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")
}

private func hexValue(_ b: UInt8) -> UInt8? {
    switch b {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
    default: return nil
    }
}

/// Extract the balanced content of destination groups named `name`
/// (`{\name ...}` or `{\*\name ...}`), bin-aware. Returns the group bodies
/// after the destination word.
func rtfDestinationGroups(_ bytes: [UInt8], _ name: String) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var lexer = RtfLexer(bytes)
    // Track group starts; when a group's first control word (skipping `\*`)
    // matches, remember its start depth and capture until it closes.
    var depth = 0
    var expectingWordAt: Int?
    var capture: (depth: Int, start: Int)?
    while true {
        let before = lexer.pos
        guard let token = lexer.next() else { break }
        switch token {
        case .open:
            depth += 1
            expectingWordAt = depth
        case .close:
            if let capturing = capture, depth == capturing.depth {
                out.append(Array(bytes[capturing.start..<before]))
                capture = nil
            }
            depth = max(0, depth - 1)
            expectingWordAt = nil
        case .symbol(let b) where b == UInt8(ascii: "*") && expectingWordAt == depth:
            break
        case .word(let word, _):
            if expectingWordAt == depth, word == name, capture == nil {
                capture = (depth: depth, start: lexer.pos)
            }
            expectingWordAt = nil
        default:
            expectingWordAt = nil
        }
    }
    return out
}
