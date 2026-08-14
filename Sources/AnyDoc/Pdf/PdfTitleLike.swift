/// Whether a line reads as a title, ported from `markdown/heading.rs`:
/// `title_like` and `complete_sidebar_label`.
///
/// The second of the three signals `PdfMarkdown.swift` records as missing.
/// Where wave 76 asked whether a line is *numbered*, these ask whether it
/// looks like a heading at all — short, capitalised, not punctuated as a
/// sentence — which is what lets a bold line at body size be promoted.

/// Words that cannot end a complete label, because a line ending in one is
/// still going.
private let pdfContinuationWords: Set<String> = [
    "a", "an", "and", "as", "at", "by", "for", "from", "in", "of", "on", "or", "the", "to",
    "with",
]

/// Whether a sidebar label is complete rather than a wrapped fragment.
///
/// A fixed-size sidebar label needs stronger evidence than typography alone,
/// since table headers and column fragments repeat the same small bold font.
/// A trailing hyphen or a dangling preposition means the label continues on
/// another line and is not a heading on its own.
func pdfCompleteSidebarLabel(_ text: String) -> Bool {
    let trimmed = text.rustTrim()
    if trimmed.hasSuffix("-") { return false }

    let words = trimmed.rustSplitWhitespace()
    // `to_ascii_lowercase`: only A-Z shift, so a non-ASCII word is compared
    // as written and never matches the list.
    let lastWord = String(
        String.UnicodeScalarView((words.last ?? "").unicodeScalars.map(pdfAsciiLowercased)))
    if pdfContinuationWords.contains(lastWord) { return false }

    // A margin reference such as `G 02` is a navigation code, not a heading.
    if words.count == 2, words[0].unicodeScalars.count == 1,
        words[0].unicodeScalars.allSatisfy({ $0.properties.isAlphabetic }),
        words[1].unicodeScalars.allSatisfy(pdfIsAsciiDigitScalarValue)
    {
        return false
    }
    return true
}

/// Whether a line reads as a title.
///
/// Length bounds first, then the vetoes of wave 73, then capitalisation —
/// unless the line is numbered or bold, either of which stands in for it.
///
/// Note a numbered line is let through even though the list recogniser also
/// matches it: telling a section run from an ordinary ordered list is the
/// sequence logic's job, not this predicate's.
func pdfTitleLike(_ text: String, numbered: Bool, bold: Bool) -> Bool {
    let trimmed = text.rustTrim()
    let wordCount = trimmed.rustSplitWhitespace().count
    let characterCount = trimmed.unicodeScalars.count
    guard (1...12).contains(wordCount), (4...140).contains(characterCount),
        trimmed.unicodeScalars.contains(where: { $0.properties.isAlphabetic })
    else { return false }
    // A sentence's punctuation is the clearest sign it is not a heading.
    if let last = trimmed.last, last == "." || last == "," || last == ";" { return false }

    if pdfStartsWithBulletMarker(trimmed) || pdfIsCaptionLine(trimmed)
        || pdfIsTocEntryLine(trimmed) || pdfIsHeadingFragment(trimmed)
    {
        return false
    }
    if !numbered && pdfIsListItem(trimmed) { return false }

    // Capitalisation is measured over the words that carry letters, by their
    // *first* letter — so `iPhone Settings` counts one capitalised of two.
    let alphaWords = trimmed.rustSplitWhitespace().filter { word in
        word.unicodeScalars.contains { $0.properties.isAlphabetic }
    }
    let capitalised = alphaWords.filter { word in
        word.unicodeScalars.first(where: { $0.properties.isAlphabetic })?.properties.isUppercase
            == true
    }.count
    return numbered || bold || capitalised * 2 >= max(alphaWords.count, 1)
}
