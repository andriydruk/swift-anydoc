/// Lines that look like headings and are not, ported from
/// `markdown/analysis.rs`: `is_toc_entry_line`, `is_toc_marker_heading` and
/// `is_heading_fragment`.
///
/// A table-of-contents entry and a display equation are both short, both sit
/// alone on a line, and both are often set larger or bolder than body text —
/// so the size heuristics promote them to headings. These three are the
/// veto: each recognises a shape that *cannot* be a heading however it is
/// typeset.
///
/// `has_dot_leaders` was ported in wave 5 as `pdfHasDotLeaders` and audited
/// against the reference in wave 73; it needed no change.

/// A table-of-contents entry: dots leading to a page number.
///
/// `pdfHasDotLeaders` wants two groups of dots and so misses a single-group
/// leader, but a trailing run of dots followed by a number is strong enough
/// evidence on its own.
func pdfIsTocEntryLine(_ text: String) -> Bool {
    let trimmed = text.rustTrimEnd()
    let scalars = Array(trimmed.unicodeScalars)

    var digits = 0
    while digits < scalars.count, pdfIsAsciiDigitScalarValue(scalars[scalars.count - 1 - digits]) {
        digits += 1
    }
    // One to four digits: a page number, not a year in a title or a whole
    // line of figures.
    if digits == 0 || digits > 4 { return false }

    let beforeNumber = String(String.UnicodeScalarView(scalars[0..<(scalars.count - digits)]))
        .rustTrimEnd()
    var dots = 0
    for scalar in beforeNumber.unicodeScalars.reversed() {
        if scalar == "." { dots += 1 } else { break }
    }
    return dots >= 3
}

/// The heading that announces a table of contents.
///
/// Lines after it on the same page are entries — section titles that look
/// exactly like headings and must not be promoted. A trailing colon is
/// stripped, since `Contents:` is the same announcement.
func pdfIsTocMarkerHeading(_ text: String) -> Bool {
    var trimmed = text.rustTrim()
    while trimmed.hasSuffix(":") { trimmed = String(trimmed.dropLast()) }
    let lowered = trimmed.rustTrim().rustLowercased()
    return lowered == "contents" || lowered == "table of contents"
}

/// The characters that mark a line as display mathematics.
private let pdfMathOperators: Set<Unicode.Scalar> = [
    "=", "<", ">", "≤", "≥", "≪", "≫", "≈", "≠", "±", "∑", "∫", "√", "∝",
]

/// Whether a token is an equation number: `(N)` with one to three digits.
private func pdfIsEquationNumber<S: StringProtocol>(_ token: S) -> Bool {
    guard token.hasPrefix("("), token.hasSuffix(")") else { return false }
    let inner = token.dropFirst().dropLast()
    // `len() <= 3` is bytes in the reference; every accepted character is an
    // ASCII digit, so this counts the same.
    guard !inner.isEmpty, inner.utf8.count <= 3 else { return false }
    return inner.unicodeScalars.allSatisfy(pdfIsAsciiDigitScalarValue)
}

/// Whether a line resembling a heading is really a fragment of something
/// else — usually display mathematics.
///
/// Three shapes, and the middle one is deliberately hard to satisfy: a
/// trailing `(N)` alone is *not* enough, because real headings end with
/// parenthesised numbers too — `Nicaea (325)`, appendix numbering. It needs
/// corroborating evidence that the line is an equation.
func pdfIsHeadingFragment(_ text: String) -> Bool {
    let trimmed = text.rustTrimEnd()

    // One or two words starting lowercase: a mid-sentence fragment beside
    // display maths — `or inversely`, `and therefore`. A real heading that
    // short starts with a capital.
    let words = trimmed.rustSplitWhitespace()
    if words.count <= 2,
        let firstAlphabetic = trimmed.unicodeScalars.first(where: { $0.properties.isAlphabetic })
    {
        if firstAlphabetic.properties.isLowercase { return true }
    }

    // Note `rsplit(' ')` in the reference splits on the *space character*
    // only, not on whitespace generally — so a tab-separated line does not
    // reach these branches the way a space-separated one does.
    let spaceSeparated = trimmed.split(separator: " ", omittingEmptySubsequences: false)
        .map(String.init)
    let last = spaceSeparated.last ?? ""

    if pdfIsEquationNumber(last) {
        let previous = spaceSeparated.count >= 2 ? spaceSeparated[spaceSeparated.count - 2] : nil

        // A running header counting pages: `LIVSMEDELSVERKET PM 2 (10)`.
        // Recognised by the pair being a plausible page-of-total.
        if let previous, let page = UInt32(previous),
            let total = UInt32(last.dropFirst().dropLast()), page <= total
        {
            return true
        }

        // The corroboration: a comma or colon immediately before the number,
        // or a mathematical operator anywhere in the line. Both are present
        // in every display equation and absent from a name-and-number
        // heading.
        let punctuationBefore = previous.map { $0.hasSuffix(",") || $0.hasSuffix(":") } ?? false
        let hasMathOperator = trimmed.unicodeScalars.contains(where: pdfMathOperators.contains)
        if punctuationBefore || hasMathOperator { return true }
    }

    // A lead-in: `Rearranging Equation (8) gives:`. The trailing colon alone
    // proves nothing — real headings end with colons constantly — so an
    // equation number must appear inline as well.
    if trimmed.hasSuffix(":") && words.contains(where: pdfIsEquationNumber) { return true }

    return false
}
