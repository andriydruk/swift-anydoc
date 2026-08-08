/// Helpers matching Rust `char`/`str` semantics exactly, so ported logic
/// behaves byte-for-byte like the reference implementation. Ported parser and
/// renderer code MUST use these instead of Swift's `Character`-based APIs:
/// a Rust `char` is a Unicode scalar, not a grapheme cluster.

extension Unicode.Scalar {
    /// Rust `char::is_whitespace`: the Unicode `White_Space` property.
    var isRustWhitespace: Bool { properties.isWhitespace }

    /// Rust `char::is_alphanumeric`: `Alphabetic` or general category Nd/Nl/No.
    var isRustAlphanumeric: Bool {
        if properties.isAlphabetic { return true }
        switch properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// Rust `char::is_control`: general category Cc only.
    var isRustControl: Bool { properties.generalCategory == .control }

    var isAsciiDigit: Bool { "0" <= self && self <= "9" }

    var isAsciiAlphabetic: Bool { ("a" <= self && self <= "z") || ("A" <= self && self <= "Z") }

    var isAsciiAlphanumeric: Bool { isAsciiAlphabetic || isAsciiDigit }

    /// Rust `char::to_lowercase`: the unconditional full lowercase mapping.
    var rustLowercased: String {
        properties.lowercaseMapping
    }
}

extension StringProtocol {
    /// Rust `str::trim`: strip Unicode whitespace from both ends.
    func rustTrim() -> String {
        String(rustTrimStartSub().rustTrimEndSub())
    }

    /// Rust `str::trim_start`.
    func rustTrimStart() -> String { String(rustTrimStartSub()) }

    /// Rust `str::trim_end`.
    func rustTrimEnd() -> String { String(rustTrimEndSub()) }

    /// True when the string is empty after a Rust-style trim.
    var isBlank: Bool { unicodeScalars.allSatisfy(\.isRustWhitespace) }

    func rustTrimStartSub() -> Self.SubSequence {
        var view = self[...]
        while let first = view.unicodeScalars.first, first.isRustWhitespace {
            view = view[view.unicodeScalars.index(after: view.unicodeScalars.startIndex)...]
        }
        return view
    }

    func rustTrimEndSub() -> Self.SubSequence {
        var view = self[...]
        while let last = view.unicodeScalars.last, last.isRustWhitespace {
            view = view[..<view.unicodeScalars.index(before: view.unicodeScalars.endIndex)]
        }
        return view
    }

    /// Rust `str::split_whitespace`: split on runs of Unicode whitespace,
    /// yielding no empty pieces.
    func rustSplitWhitespace() -> [Self.SubSequence] {
        var pieces: [Self.SubSequence] = []
        var start: Self.Index?
        for index in unicodeScalars.indices {
            let isSpace = unicodeScalars[index].isRustWhitespace
            if isSpace {
                if let begin = start { pieces.append(self[begin..<index]) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let begin = start { pieces.append(self[begin...]) }
        return pieces
    }

    /// Rust `str::lines`: split on `\n`, strip one trailing `\r` per line, and
    /// produce no final empty line for a trailing newline.
    func rustLines() -> [String] {
        if isEmpty { return [] }
        var lines: [String] = []
        var current = ""
        for scalar in unicodeScalars {
            if scalar == "\n" {
                if current.unicodeScalars.last == "\r" {
                    current.unicodeScalars.removeLast()
                }
                lines.append(current)
                current = ""
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty {
            if current.unicodeScalars.last == "\r" {
                current.unicodeScalars.removeLast()
            }
            lines.append(current)
        }
        return lines
    }

    /// Rust `str::to_lowercase` (full Unicode, context-sensitive).
    func rustLowercased() -> String { lowercased() }
}

extension UInt64 {
    /// Rust `u64::saturating_add`.
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? .max : result
    }
}

/// Shared mutable cell (the Rust `RefCell`): state threaded through parsing
/// contexts by reference where the context itself is copied or re-scoped.
final class MutBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Rust `str` `{:?}` (Debug) formatting: double-quoted with
/// `char::escape_debug` escapes — `\t`/`\r`/`\n`/`\\`/`\"`/`\0` named, other
/// non-printable scalars as `\u{hex}`, printable scalars verbatim.
func rustDebugString(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        case "\n": out += "\\n"
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\0": out += "\\0"
        default:
            switch c.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate,
                .unassigned:
                out += "\\u{\(String(c.value, radix: 16))}"
            default:
                out.unicodeScalars.append(c)
            }
        }
    }
    return out + "\""
}

/// Rust `f64::from_str` grammar check, without Swift's extras (hex floats):
/// `[+-]? ( digits ( '.' digits? )? | '.' digits ) ( [eE] [+-]? digits )?`.
/// Special values (`inf`, `nan`) are excluded by construction — callers
/// require a digit anyway.
func parsesAsRustF64(_ text: some StringProtocol) -> Bool {
    var scalars = ArraySlice(Array(text.unicodeScalars))
    if let first = scalars.first, first == "+" || first == "-" {
        scalars = scalars.dropFirst()
    }
    var intDigits = 0
    while let c = scalars.first, c.isAsciiDigit {
        intDigits += 1
        scalars = scalars.dropFirst()
    }
    var fracDigits = 0
    if scalars.first == "." {
        scalars = scalars.dropFirst()
        while let c = scalars.first, c.isAsciiDigit {
            fracDigits += 1
            scalars = scalars.dropFirst()
        }
    }
    if intDigits == 0 && fracDigits == 0 { return false }
    if let c = scalars.first, c == "e" || c == "E" {
        scalars = scalars.dropFirst()
        if let sign = scalars.first, sign == "+" || sign == "-" {
            scalars = scalars.dropFirst()
        }
        var expDigits = 0
        while let c = scalars.first, c.isAsciiDigit {
            expDigits += 1
            scalars = scalars.dropFirst()
        }
        if expDigits == 0 { return false }
    }
    return scalars.isEmpty
}
