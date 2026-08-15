/// Bold paragraphs that are not headings, ported from `markdown/convert.rs`:
/// `starts_with_section_number`, `is_body_size_all_bold_line`,
/// `is_wrapped_same_style_line`, `find_wrapped_bold_paragraph_lines` and
/// `struct_role_heading_level`.
///
/// Wave 72 made a bold line at body size eligible to be a heading, which is
/// right for a section title and wrong for a bold *paragraph* — a pull quote,
/// a warning, an abstract set in bold. The difference is length: a heading
/// does not wrap three times.
///
/// The lines this finds are handed to `pdfClassifyHeadingSequences` as its
/// excluded set, so they cannot support another line's candidacy either.

/// Whether a line opens with a multi-part section number **and a title**.
///
/// The reference has *two* functions called `starts_with_section_number`, in
/// different modules and behaving differently. The one in
/// `tables/detect_heuristic.rs` is already ported as
/// `pdfStartsWithSectionNumber` and asks only whether the first token is a
/// dotted number, so `1.2` alone satisfies it. This one, from
/// `markdown/convert.rs`, additionally requires whitespace and an alphabetic
/// title after the number — hence the different name here.
///
/// Two components minimum either way: `9.5. Title` is a section, `1. Title`
/// is an ordered list item. The distinction matters because this prefix
/// bypasses the isolation checks entirely.
func pdfStartsWithSectionNumberAndTitle(_ text: String) -> Bool {
    var rest = Substring(text.rustTrimStart())
    var groups = 0
    while true {
        let digits = rest.prefix { $0.isASCIIDigitCharacter }.count
        if digits == 0 || digits > 3 { break }
        groups += 1
        rest = rest.dropFirst(digits)
        if rest.first == "." {
            rest = rest.dropFirst()
        } else {
            break
        }
    }
    guard groups >= 2, let next = rest.first, next.isWhitespace else { return false }
    return rest.rustTrimStart().unicodeScalars.first?.properties.isAlphabetic == true
}

/// Whether a line is entirely bold at roughly the body size.
///
/// The window is deliberately narrow — from 0.95 to 1.2 times the body — so
/// a genuinely larger bold heading is left to the size heuristics, and every
/// run must be both bold and the same size, so a bold label followed by a
/// regular value does not qualify.
func pdfIsBodySizeAllBoldLine(_ line: PdfTextLine, bodySize: Float) -> Bool {
    guard let first = line.items.first else { return false }
    guard first.fontSize >= bodySize * 0.95, first.fontSize < bodySize * 1.2 else { return false }
    return line.items.allSatisfy { $0.isBold && abs($0.fontSize - first.fontSize) < 0.5 }
}

/// Whether two lines are consecutive lines of one wrapped paragraph.
///
/// Same page, a downward gap no larger than the paragraph threshold, and
/// left edges within 40 points — which tolerates a first-line indent without
/// admitting a different column.
func pdfIsWrappedSameStyleLine(
    _ previous: PdfTextLine, _ next: PdfTextLine, paragraphThreshold: Float
) -> Bool {
    if previous.page != next.page { return false }
    let gap = previous.y - next.y
    guard gap > 0, gap <= paragraphThreshold else { return false }
    let previousX = previous.items.first?.x ?? 0
    let nextX = next.items.first?.x ?? 0
    return abs(previousX - nextX) <= 40
}

/// The lines belonging to bold paragraphs rather than to bold headings.
///
/// A run of all-bold body-size lines qualifies only at **three lines and
/// more than twenty words** — a bold heading may wrap once, and may be long,
/// but not both.
func pdfFindWrappedBoldParagraphLines(
    _ lines: [PdfTextLine], bodySize: Float, paragraphThreshold: Float
) -> Set<Int> {
    var found: Set<Int> = []
    var index = 0
    while index < lines.count {
        guard pdfIsBodySizeAllBoldLine(lines[index], bodySize: bodySize) else {
            index += 1
            continue
        }

        let start = index
        var end = index
        var wordCount = pdfLineText(lines[index]).rustSplitWhitespace().count
        while end + 1 < lines.count,
            pdfIsBodySizeAllBoldLine(lines[end + 1], bodySize: bodySize),
            pdfIsWrappedSameStyleLine(
                lines[end], lines[end + 1], paragraphThreshold: paragraphThreshold)
        {
            end += 1
            wordCount += pdfLineText(lines[end]).rustSplitWhitespace().count
        }

        if end - start + 1 >= 3 && wordCount > 20 {
            for line in start...end { found.insert(line) }
        }
        index = end + 1
    }
    return found
}

/// The Markdown level a tagged heading role names, if it names one.
func pdfStructRoleHeadingLevel(_ role: PdfStructRole) -> Int? {
    switch role {
    // A generic `H` carries no depth of its own, so it becomes H1.
    case .h, .h1: return 1
    case .h2: return 2
    case .h3: return 3
    case .h4: return 4
    case .h5: return 5
    case .h6: return 6
    default: return nil
    }
}

extension Character {
    fileprivate var isASCIIDigitCharacter: Bool {
        guard let ascii = asciiValue else { return false }
        return ascii >= 0x30 && ascii <= 0x39
    }
}
