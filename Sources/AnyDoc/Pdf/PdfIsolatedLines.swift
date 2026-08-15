/// Two pre-scans that run before any line is classified, ported from
/// `markdown/convert.rs`: `resolve_line_struct_role`,
/// `detect_overused_struct_heading_levels` and `find_isolated_lines`.
///
/// Both answer the same question from opposite directions. A tagged PDF
/// declares its headings, and where the tags are honest they beat every
/// geometric guess — but a tagger that marks *every* numbered paragraph as
/// H2 is worse than no tags at all, so the levels have to be audited before
/// they are trusted. An untagged PDF declares nothing, and a section title
/// set at body size is invisible to the font-size heuristics; what gives it
/// away is the white space around it.
///
/// The two results are the corrections wave 72's tier logic runs under: one
/// suppresses heading levels, the other promotes lines that no size rule
/// would reach.

/// A tagged document's roles, by page and then by marked-content id.
///
/// The reference keys pages by `u32` and mcids by `i64`; both are `Int`
/// here, matching `PdfTextLine.page` and `PdfLayoutItem.mcid`.
typealias PdfStructRoleMap = [Int: [Int: PdfStructRole]]

/// The role a line carries, if its tags say anything useful.
///
/// The first *informative* tag on the line wins. Container roles — the
/// wrappers a tagger nests everything inside — are skipped rather than
/// returned, and skipping continues the search instead of ending it, so a
/// line whose first run sits in a `Div` and whose second is an `H2` resolves
/// to `H2`. Items are read in line order, which is left to right, not in
/// mcid order.
func pdfResolveLineStructRole(_ line: PdfTextLine, _ structRoles: PdfStructRoleMap)
    -> PdfStructRole?
{
    guard let pageRoles = structRoles[line.page] else { return nil }
    for item in line.items {
        guard let mcid = item.mcid, let role = pageRoles[mcid] else { continue }
        switch role {
        case .document, .part, .art, .sect, .div, .nonStruct, .span, .private:
            continue
        default:
            return role
        }
    }
    return nil
}

/// The heading levels a document tags so freely that they cannot mean
/// anything.
///
/// A tagger that marks every numbered paragraph as H2 produces hundreds of
/// false headings, and the giveaway is proportion: real headings are a small
/// fraction of a document's tagged lines. Any level above **15%** of them is
/// suppressed wholesale.
///
/// Note that the reference's own comment says 25% while its code says 15%;
/// the code is what runs and is what is ported. The denominator is every
/// line with an informative role, not every line and not every *heading* —
/// so a document of tagged paragraphs dilutes its headings, and one where
/// nothing but headings is tagged suppresses them all.
///
/// Documents with fewer than twenty tagged lines are left alone: the ratio
/// means nothing on a page or two, where a single heading is already a large
/// share of the total.
func pdfDetectOverusedStructHeadingLevels(
    _ lines: [PdfTextLine], _ structRoles: PdfStructRoleMap?
) -> Set<Int> {
    // Absent tags and empty tags differ: the first returns before counting,
    // the second counts nothing and falls under the floor anyway.
    guard let roles = structRoles else { return [] }

    var levelCounts: [Int: Int] = [:]
    var total = 0
    for line in lines {
        guard let role = pdfResolveLineStructRole(line, roles) else { continue }
        total += 1
        if let level = pdfStructRoleHeadingLevel(role) {
            levelCounts[level, default: 0] += 1
        }
    }
    if total < 20 { return [] }

    var overused: Set<Int> = []
    for (level, count) in levelCounts where Float(count) / Float(total) > 0.15 {
        overused.insert(level)
    }
    return overused
}

/// The words that, ending a line, mark it as prose that wrapped.
///
/// A heading does not end on `the` or `and`. Compared case-insensitively.
private let pdfContinuationWords: Set<String> = [
    "the", "a", "an", "and", "or", "of", "in", "to", "for", "with", "by", "on", "at",
    "from", "as", "is", "are", "was", "were", "be", "that", "this", "their", "its", "our",
    "your", "has", "have", "had", "not",
]

/// The lines that stand alone: short, with a paragraph break on both sides.
///
/// `Acknowledgements` and `B.3 Prompt Engineering` are headings set at body
/// size, invisible to every rule that reads font size. What identifies them
/// is the white space: one to six words, nothing immediately above, nothing
/// immediately below.
///
/// The gates are deliberately mean, because the shape is common. A line
/// ending in a hyphen, a comma or a semicolon is prose mid-flight; so is one
/// ending on a preposition or an article. Captions and list items have their
/// own handling and are excluded here.
///
/// That last exclusion swallows the reference's own second example.
/// `is_list_item` reads any letter followed by a dot as a lettered list
/// marker, so `B.3 Prompt Engineering` — and every other appendix heading —
/// is thrown out here rather than found. Reproduced as it stands.
///
/// - Parameters:
///   - baseSize: the document's body size. A line below 95% of it is a
///     footnote or a caption, not a heading.
///   - paraThreshold: the vertical gap that separates paragraphs.
func pdfFindIsolatedLines(_ lines: [PdfTextLine], baseSize: Float, paraThreshold: Float)
    -> Set<Int>
{
    var found: Set<Int> = []
    for index in lines.indices {
        let line = lines[index]
        let trimmed = pdfLineText(line).rustTrim()
        let words = trimmed.rustSplitWhitespace()
        // `len()` is bytes, so a short line of accented characters clears a
        // bar that the same number of ASCII characters would not.
        if !(1...6).contains(words.count) || trimmed.utf8.count <= 3 { continue }

        // The *first* item's size, not the largest: a line beginning at body
        // size and rising into a superscript is still a body-size line.
        let fontSize = line.items.first?.fontSize ?? 0
        if fontSize < baseSize * 0.95 { continue }
        if pdfIsListItem(trimmed) || pdfIsCaptionLine(trimmed) { continue }

        // `chars().last()` is a scalar in the reference, so a trailing
        // combining mark hides the hyphen underneath it rather than being
        // read together with it as Swift's `Character` would.
        let lastScalar = trimmed.unicodeScalars.last ?? " "
        if lastScalar == "-" || lastScalar == "," || lastScalar == ";" { continue }
        if let lastWord = words.last, pdfContinuationWords.contains(String(lastWord).lowercased())
        {
            continue
        }

        // The first and last lines of the document are bounded by its edges.
        // A page change counts as a break in either direction, and the gap is
        // compared as an absolute value — so a line placed *above* its
        // predecessor breaks just as one placed far below does.
        let breakBefore: Bool
        if index == 0 {
            breakBefore = true
        } else {
            let previous = lines[index - 1]
            breakBefore = previous.page != line.page || abs(previous.y - line.y) > paraThreshold
        }
        let breakAfter: Bool
        if index + 1 >= lines.count {
            breakAfter = true
        } else {
            let next = lines[index + 1]
            breakAfter = next.page != line.page || abs(line.y - next.y) > paraThreshold
        }
        if !breakBefore || !breakAfter { continue }

        found.insert(index)
    }

    // Density guard. A two-column page read as one produces a page of lines
    // that all look isolated, because the gap between columns reads as a
    // paragraph break on every row. Real headings are rare, so a page more
    // than a quarter isolated has found nothing.
    //
    // The floor matters as much as the ratio: on a sparse page — a cover, a
    // ToC page with a lone title — one isolated line is already a quarter of
    // the page and is exactly the line this exists to find.
    var perPage: [Int: (total: Int, isolated: Int)] = [:]
    for (index, line) in lines.enumerated() {
        perPage[line.page, default: (0, 0)].total += 1
        if found.contains(index) { perPage[line.page]!.isolated += 1 }
    }
    for (page, counts) in perPage
    where counts.total >= 10 && Float(counts.isolated) / Float(counts.total) > 0.25 {
        found = found.filter { lines[$0].page != page }
    }
    return found
}
