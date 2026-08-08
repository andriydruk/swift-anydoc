/// Line classification — captions, lists, code — ported from pdf-inspector's
/// `markdown/classify.rs`, plus the two measurements from
/// `markdown/analysis.rs` that the block loop needs.
///
/// A PDF says nothing about what a line *is*. Every one of these predicates is
/// therefore a guess made from the text alone, and the reference's guesses are
/// reproduced exactly, quirks included — the point is to agree with it, not to
/// classify well.

/// Whether the text is a figure/table caption or a source citation.
///
/// `Figure` and `Table` need a digit, `(` or `#` after them, or "Table of
/// Contents" would be a caption. The other prefixes are always followed by an
/// identifier in practice, so they match on their own. The Portuguese
/// spellings come from the reference and are kept.
func pdfIsCaptionLine(_ text: String) -> Bool {
    let trimmed = text.rustTrim()

    let alwaysPrefixes = [
        "Figura ", "Fig. ", "Fig ", "Tabela ", "Source:", "Fonte:", "Source ", "Fonte ",
        "Note:", "Nota:", "Chart ", "Gráfico ", "Graph ", "Diagram ", "Image ", "Imagem ",
        "Photo ", "Foto ",
    ]
    for prefix in alwaysPrefixes where scalarsHavePrefix(trimmed, prefix) {
        return true
    }

    // A reference marker is a digit, a parenthesis or a hash.
    func introducesAReference(_ rest: Substring) -> Bool {
        guard let first = rest.rustTrimStartSub().unicodeScalars.first else { return false }
        return first.isASCIIDigit || first == "(" || first == "#"
    }
    for prefix in ["Figure ", "Table "] {
        if scalarsHavePrefix(trimmed, prefix),
            introducesAReference(droppingScalars(trimmed[...], prefix.unicodeScalars.count))
        {
            return true
        }
    }

    // The same test again, case-insensitively, which is what catches
    // `FIGURE 1`. The reference runs both passes and so does this.
    let lower = trimmed.rustLowercased()
    for prefix in ["figure ", "table "] {
        if scalarsHavePrefix(lower, prefix),
            introducesAReference(droppingScalars(lower[...], prefix.unicodeScalars.count))
        {
            return true
        }
    }
    return scalarsHavePrefix(lower, "source:")
}

/// The bullet characters the reference recognises, in its order.
private let pdfBulletCharacters: [Unicode.Scalar] = ["•", "○", "●", "◦"]

/// Rust's `str::starts_with`, which compares scalars rather than the grapheme
/// clusters Swift's `hasPrefix` compares.
///
/// The difference is not academic here: `•` followed by a combining accent is
/// one Swift `Character` and two Rust `char`s, so a grapheme-wise test misses
/// a bullet the reference strips.
private func scalarsHavePrefix<S: StringProtocol>(_ text: S, _ prefix: String) -> Bool {
    var subject = text.unicodeScalars.makeIterator()
    for scalar in prefix.unicodeScalars {
        guard subject.next() == scalar else { return false }
    }
    return true
}

/// Rust's `str::contains`, which is a byte search — so a needle can match
/// across what Swift would call one grapheme, as `courier` does inside
/// `Courier` followed by a combining diaeresis.
func scalarsContain<S: StringProtocol>(_ text: S, _ needle: String) -> Bool {
    let haystack = Array(text.unicodeScalars)
    let pattern = Array(needle.unicodeScalars)
    guard !pattern.isEmpty else { return true }
    guard haystack.count >= pattern.count else { return false }
    for start in 0...(haystack.count - pattern.count) {
        if Array(haystack[start..<(start + pattern.count)]) == pattern { return true }
    }
    return false
}

/// The text with `count` leading scalars removed.
private func droppingScalars(_ text: Substring, _ count: Int) -> Substring {
    let scalars = text.unicodeScalars
    let start =
        scalars.index(scalars.startIndex, offsetBy: count, limitedBy: scalars.endIndex)
        ?? scalars.endIndex
    return text[start...]
}

/// Whether the text opens with an unmistakable bullet.
///
/// Narrower than `pdfIsListItem`: numbered and lettered forms like `1.` or
/// `a)` are excluded, because those are section headings as often as they are
/// list items. Heading detection uses this to reject bulleted lines without
/// also demoting numbered headings.
func pdfStartsWithBulletMarker(_ text: String) -> Bool {
    let trimmed = text.rustTrimStartSub()
    return ["• ", "● ", "○ ", "◦ ", "- ", "* "].contains { scalarsHavePrefix(trimmed, $0) }
}

/// Whether the text looks like a list item.
func pdfIsListItem(_ text: String) -> Bool {
    let trimmed = text.rustTrimStartSub()

    if ["• ", "- ", "* ", "○ ", "● ", "◦ "].contains(where: { scalarsHavePrefix(trimmed, $0) }) {
        return true
    }

    // Numbered: `1.`, `1)`, `10.`. Only the first five scalars are examined,
    // so a delimiter further in does not count.
    let head = Array(trimmed.unicodeScalars.prefix(5))
    if head.contains(where: \.isASCIIDigit),
        let stop = head.firstIndex(where: { $0 == "." || $0 == ")" }),
        // An empty run before the delimiter passes here, exactly as the
        // reference's `all()` over an empty slice does: `.5` is a list item.
        head[..<stop].allSatisfy(\.isASCIIDigit)
    {
        return true
    }

    // Lettered: `a.`, `a)`, and the parenthesised `(a)` — where the reference
    // checks only that the third scalar closes the parenthesis, so any single
    // scalar inside one qualifies.
    var scalars = trimmed.unicodeScalars.makeIterator()
    guard let first = scalars.next(), let second = scalars.next() else { return false }
    if first.isASCIILetter, second == "." || second == ")" { return true }
    return first == "(" && scalars.next() == ")"
}

/// Rewrite a list item's marker as Markdown's.
///
/// Takes the *formatted* text, markers and all, because the bullet is often
/// inside a style run: a PDF sets `● Label:` bold as one span, which arrives
/// here as `**● Label:**`. Markdown would not see a list there, so the bullet
/// is lifted out of the wrapper.
func pdfFormatListItem(_ text: String) -> String {
    let trimmed = text.rustTrimStart()

    for bullet in pdfBulletCharacters {
        if trimmed.unicodeScalars.first == bullet {
            return "- " + droppingScalars(trimmed[...], 1).rustTrimStart()
        }
        for wrapper in ["**", "*", "<u>"] where scalarsHavePrefix(trimmed, wrapper) {
            let afterOpen = droppingScalars(trimmed[...], wrapper.unicodeScalars.count)
            if afterOpen.unicodeScalars.first == bullet {
                return "- " + wrapper + droppingScalars(afterOpen, 1).rustTrimStart()
            }
        }
    }

    // A dash or asterisk is already Markdown's own marker, and a numbered
    // list is already Markdown's own syntax. Both pass through.
    return trimmed
}

/// Whether the text looks like source code.
func pdfIsCodeLike(_ text: String) -> Bool {
    let trimmed = text.rustTrim()

    let codePatterns = [
        "import ", "export ", "from ", "const ", "let ", "var ", "function ", "class ",
        "def ", "pub fn ", "fn ", "async fn ", "impl ",
        "=> ", "-> ", ":: ", ":= ",
    ]
    for pattern in codePatterns where scalarsHavePrefix(trimmed, pattern) {
        return true
    }

    let punctuation: Set<Unicode.Scalar> = ["{", "}", "(", ")", "[", "]", ";", "=", "<", ">"]
    let special = trimmed.unicodeScalars.count(where: { punctuation.contains($0) })
    // The length bound is in bytes in the reference, so it is here too.
    if special >= 3, trimmed.utf8.count < 200 { return true }

    // Suffixes on the scalar view too: a trailing combining mark makes the
    // grapheme differ while the last scalar is still the brace.
    let last = trimmed.unicodeScalars.last
    return last == ";" || last == "{" || last == "}"
}

/// Whether a font name says monospace.
func pdfIsMonospaceFont(_ fontName: String) -> Bool {
    let lower = fontName.rustLowercased()
    let patterns = [
        "courier", "consolas", "monaco", "menlo", "mono", "fixed", "terminal",
        "typewriter", "source code", "fira code", "jetbrains", "inconsolata",
        "dejavu sans mono", "liberation mono",
    ]
    return patterns.contains { scalarsContain(lower, $0) }
}

/// Whether the text carries dot leaders — the run of periods that walks a
/// table-of-contents entry across to its page number.
///
/// Two groups of three or more, or one run of four, since a single `...` is
/// an ellipsis far more often than it is a leader.
func pdfHasDotLeaders(_ text: String) -> Bool {
    if scalarsContain(text, "....") { return true }
    var groups = 0
    var run = 0
    // Scalars, not characters: a dot carrying a combining mark is still a dot
    // to the reference, which counts `char`s.
    for scalar in text.unicodeScalars {
        if scalar == "." {
            run += 1
        } else {
            if run >= 3 { groups += 1 }
            run = 0
        }
    }
    if run >= 3 { groups += 1 }
    return groups >= 2
}

/// The Y gap above which two lines belong to different paragraphs.
///
/// Measured from the document rather than assumed, since line pitch varies
/// with the typesetting: the median gap, widened by a third, floored at one
/// and a half times the body size. Gaps beyond ten body sizes are dropped as
/// headers and footers rather than leading.
func pdfParagraphThreshold(_ lines: [PdfTextLine], bodySize: Float) -> Float {
    let fallback = bodySize * 1.8

    var gaps: [Float] = []
    for (previous, next) in zip(lines, lines.dropFirst()) {
        let gap = previous.y - next.y
        if gap > 0, gap < bodySize * 10 { gaps.append(gap) }
    }
    // Too few samples to call a median meaningful.
    guard gaps.count >= 5 else { return fallback }

    gaps.sort()
    let median = gaps[gaps.count / 2]
    return max(median * 1.3, bodySize * 1.5)
}

extension Unicode.Scalar {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
    var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
}
