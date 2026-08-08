/// Excel number-format classification.
///
/// A spreadsheet stores dates, times and durations as plain serial numbers;
/// only the cell's number format says which is which. Ported from calamine's
/// `formats.rs` (MIT), whose detector anydoc depends on for its date/time
/// rendering — the classification has to agree token for token or numbers
/// that should render as `2026-03-15` come out as `46096`.
enum CellFormat: Equatable {
    case other
    case dateTime
    case timeDelta
}

/// Classify a custom `formatCode`. Scans only the first section (Excel's
/// positive-number format); a `;` ends the scan as "not a date".
func detectCustomNumberFormat(_ format: String) -> CellFormat {
    var escaped = false
    var isQuote = false
    var brackets: UInt8 = 0
    var prev: Unicode.Scalar = " "
    var hms = false
    var ap = false
    // Branch order mirrors the reference match arms exactly: earlier arms win,
    // and several of them deliberately fire even inside a quoted literal.
    for s in format.unicodeScalars {
        if escaped {
            escaped = false
        } else if s == "_" || s == "\\" || s == "*" {
            // `\` escapes, `_` skips a width, `*` fills: the next character is
            // always a literal, never a format token.
            escaped = true
        } else if isQuote {
            if s == "\"" { isQuote = false }
        } else if s == "\"" {
            isQuote = true
        } else if s == ";" {
            return .other
        } else if s == "[" {
            brackets = brackets &+ 1
        } else if s == "]" {
            if brackets == 1 && hms { return .timeDelta }
            brackets = brackets == 0 ? 0 : brackets - 1
        } else if (s == "a" || s == "A") && !ap && brackets == 0 {
            ap = true
        } else if (s == "p" || s == "m" || s == "/" || s == "P" || s == "M") && ap && brackets == 0 {
            return .dateTime
        } else if isDateToken(s) && !ap && brackets == 0 {
            return .dateTime
        } else {
            if hms && eqIgnoreAsciiCaseScalar(s, prev) {
                // A repeated bracketed unit (`[mm]`, `[hh]`) stays one unit.
            } else {
                hms = prev == "[" && isElapsedUnit(s)
            }
        }
        prev = s
    }
    return .other
}

private func isDateToken(_ s: Unicode.Scalar) -> Bool {
    switch s {
    case "d", "m", "h", "y", "s", "D", "M", "H", "Y", "S": return true
    default: return false
    }
}

private func isElapsedUnit(_ s: Unicode.Scalar) -> Bool {
    switch s {
    case "m", "h", "s", "M", "H", "S": return true
    default: return false
    }
}

private func eqIgnoreAsciiCaseScalar(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
    if a == b { return true }
    guard a.isASCII && b.isASCII else { return false }
    return asciiLower(UInt8(a.value)) == asciiLower(UInt8(b.value))
}

/// Classify a reserved format id given as a number — the binary workbook
/// formats store the id rather than its text.
func builtinFormatByCode(_ code: UInt16) -> CellFormat {
    switch code {
    case 14...22, 45, 47: return .dateTime
    case 46: return .timeDelta
    default: return .other
    }
}

/// Classify one of Excel's reserved (built-in) format ids. The id is matched
/// as written in the file, so `"014"` is not id 14 — the reference compares
/// the raw attribute bytes.
func builtinFormatById(_ id: String) -> CellFormat {
    switch id {
    // 14 mm-dd-yy, 15 d-mmm-yy, 16 d-mmm, 17 mmm-yy, 18 h:mm AM/PM,
    // 19 h:mm:ss AM/PM, 20 h:mm, 21 h:mm:ss, 22 m/d/yy h:mm,
    // 45 mm:ss, 47 mmss.0
    case "14", "15", "16", "17", "18", "19", "20", "21", "22", "45", "47":
        return .dateTime
    // 46 [h]:mm:ss
    case "46":
        return .timeDelta
    default:
        return .other
    }
}
