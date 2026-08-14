/// Section numbering, ported from `markdown/heading.rs`: `roman_value`,
/// `parse_numbering`, `has_additional_decimal_numbering` and
/// `numbering_forms_hierarchy`.
///
/// A numbered line is evidence of a heading independent of its typography —
/// `2.1 Method` is a heading whatever size it is set at. Recovering that
/// needs the number parsed and then *related* to its neighbours: `1.` and
/// `1.1` form a hierarchy, `1.` and `2.` do not.
///
/// This is the first of the signals `PdfMarkdown.swift` records as missing.
/// The sequence logic that consumes it is not ported yet.

/// Whether a line's number is decimal or roman.
enum PdfNumberingKind: Equatable {
    case decimal
    case roman
}

/// A parsed section number: its kind, its depth, and its components.
struct PdfNumbering: Equatable {
    var kind: PdfNumberingKind
    var depth: Int
    var parts: [UInt32]
}

/// The value of a roman numeral, or nothing if it is not one.
///
/// Only `I V X L C` — **not** `D` or `M`. Section numbering does not reach
/// five hundred, and admitting those letters would read `DOC` and `MIX` as
/// numerals. Eight characters is the ceiling for the same reason.
func pdfRomanValue(_ token: String) -> UInt32? {
    // `len()` is bytes in the reference; every accepted character is ASCII.
    if token.isEmpty || token.utf8.count > 8 { return nil }

    func value(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar {
        case "I": return 1
        case "V": return 5
        case "X": return 10
        case "L": return 50
        case "C": return 100
        default: return nil
        }
    }

    var values: [UInt32] = []
    for scalar in token.unicodeScalars {
        guard let single = value(scalar) else { return nil }
        values.append(single)
    }

    // Subtractive notation: a smaller value before a larger one is negative.
    // Note this accepts forms a strict reader would not — `IIX` totals 8 —
    // which is the reference's behaviour and is left alone.
    var total = 0
    for (index, current) in values.enumerated() {
        if index + 1 < values.count, current < values[index + 1] {
            total -= Int(current)
        } else {
            total += Int(current)
        }
    }
    return total > 0 ? UInt32(total) : nil
}

/// The section number a line opens with, if it has one.
///
/// The first token must end in `.`, `)` or `:` — a bare `2` is a page number
/// or a quantity far more often than a section. Decimal is tried first and
/// roman only as a fallback, so `I.` is roman but `1.1` is decimal.
func pdfParseNumbering(_ text: String) -> PdfNumbering? {
    guard let first = text.rustSplitWhitespace().first else { return nil }
    let delimiters: Set<Character> = [".", ")", ":"]
    guard let lastCharacter = first.last, delimiters.contains(lastCharacter) else { return nil }

    // `trim_end_matches` strips *every* trailing delimiter, so `1...` and
    // `1.` parse alike.
    var token = Substring(first)
    while let lastCharacter = token.last, delimiters.contains(lastCharacter) {
        token = token.dropLast()
    }
    if token.isEmpty { return nil }

    // Decimal: every dot-separated part must be one to three digits. A part
    // of four digits fails the whole token rather than truncating it, which
    // is what keeps a year out of the numbering.
    var parts: [UInt32] = []
    var decimal = true
    for part in token.split(separator: ".", omittingEmptySubsequences: false) {
        guard !part.isEmpty, part.utf8.count <= 3,
            part.unicodeScalars.allSatisfy(pdfIsAsciiDigitScalarValue),
            let value = UInt32(part)
        else {
            decimal = false
            break
        }
        parts.append(value)
    }
    if decimal && !parts.isEmpty {
        return PdfNumbering(kind: .decimal, depth: parts.count, parts: parts)
    }

    guard let roman = pdfRomanValue(String(token)) else { return nil }
    // Roman numbering is always one level deep — there is no `IV.2`.
    return PdfNumbering(kind: .roman, depth: 1, parts: [roman])
}

/// Whether a line carries a *second* decimal number after its first word.
///
/// `1. See section 2.3 for details` has one; `1. Introduction` does not. A
/// line that references another section is prose about the document rather
/// than a heading of it.
func pdfHasAdditionalDecimalNumbering(_ text: String) -> Bool {
    let words = text.rustSplitWhitespace()
    guard words.count > 1 else { return false }

    for word in words.dropFirst() {
        // Trimmed from both ends of anything that is not a digit or a dot,
        // so `(2.3)` and `2.3,` both yield `2.3`.
        var token = Substring(word)
        while let first = token.first, !first.isASCIIDigitCharacter, first != "." {
            token = token.dropFirst()
        }
        while let last = token.last, !last.isASCIIDigitCharacter, last != "." {
            token = token.dropLast()
        }

        let parts = token.split(separator: ".").filter { !$0.isEmpty }
        guard let first = parts.first, parts.count >= 2 else { continue }
        if parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigitCharacter) })
            && first.allSatisfy(\.isASCIIDigitCharacter)
        {
            return true
        }
    }
    return false
}

/// Whether two numberings are parent and child rather than siblings.
///
/// `[1]` and `[1, 1]` form a hierarchy; `[1]` and `[2]` do not, and neither
/// does a number with itself.
func pdfNumberingFormsHierarchy(_ left: [UInt32], _ right: [UInt32]) -> Bool {
    guard left.count != right.count else { return false }
    return left.starts(with: right) || right.starts(with: left)
}

extension Character {
    fileprivate var isASCIIDigitCharacter: Bool {
        guard let ascii = asciiValue else { return false }
        return ascii >= 0x30 && ascii <= 0x39
    }
}
