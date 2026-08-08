/// Markdown cleanup, ported from pdf-inspector's `markdown/postprocess.rs`.
///
/// Everything upstream of here reconstructs; this pass repairs. A PDF's text
/// arrives in fragments whose boundaries are set by style changes and glyph
/// positioning, not by words, so joining them leaves a residue: doubled
/// spaces, a period stranded after a space, a compound word split at its
/// hyphen, a page number on a line of its own. None of it is recoverable from
/// any single earlier stage, which is why it is a pass.
///
/// The reference does this with three regexes; they are hand-written here to
/// keep the port dependency-free, and each is annotated with the pattern it
/// stands in for.

/// Which of the cleanups run. The defaults are the reference's own.
struct PdfCleanupOptions {
    /// Collapse runs of four or more dots into ` ... `. Off by default: it
    /// changes the source text, so the reference reserves it for its explicit
    /// compact profile.
    var collapseDotLeaders = false
    var fixHyphenation = true
    var removePageNumbers = true
    var formatUrls = true
}

/// Run the cleanup pass. The order matters and is the reference's.
func pdfCleanMarkdown(_ input: String, options: PdfCleanupOptions = PdfCleanupOptions()) -> String {
    var text = input
    if options.collapseDotLeaders { text = pdfCollapseDotLeaders(text) }
    if options.fixHyphenation { text = pdfFixHyphenation(text) }
    if options.removePageNumbers { text = pdfRemovePageNumbers(text) }
    if options.formatUrls { text = pdfFormatUrls(text) }

    text = pdfCollapseConsecutiveSpaces(text)
    text = pdfRemoveSpacesBeforeClosingBrackets(text)
    text = pdfRemoveSpacesBeforeSentencePunctuation(text)

    // Three newlines never carry meaning that two do not.
    text = pdfCollapseBlankLines(text)
    let trimmed = text.rustTrim()
    return trimmed + "\n"
}

/// Reduce every run of three or more newlines to two.
///
/// The reference loops on `replace("\n\n\n", "\n\n")` until the string
/// stops containing the triple, which converges on the same thing in one
/// pass here.
func pdfCollapseBlankLines(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    var run = 0
    for character in text {
        if character == "\n" {
            run += 1
            if run <= 2 { result.append(character) }
        } else {
            run = 0
            result.append(character)
        }
    }
    return result
}

/// Collapse runs of two or more spaces inside each line, keeping the line's
/// indentation and any table alignment intact.
///
/// Producers that emit a trailing space on every text item combine with
/// gap-based space insertion to give `Vice  President`.
func pdfCollapseConsecutiveSpaces(_ text: String) -> String {
    var result = String.UnicodeScalarView()
    result.reserveCapacity(text.unicodeScalars.count)
    for line in text.unicodeScalars.split(
        separator: "\n", omittingEmptySubsequences: false)
    {
        // The reference guards the separator on `!result.is_empty()`, not on
        // "is this the first line". Leading blank lines therefore vanish —
        // `"\nabc"` comes back as `"abc"` and `"\n\n\n"` as `""` — while
        // blank lines after any real content keep their newlines. Reproduced,
        // not corrected.
        if !result.isEmpty { result.append("\n") }
        var index = line.startIndex
        while index < line.endIndex, line[index].isRustWhitespace {
            result.append(line[index])
            index = line.index(after: index)
        }
        var previousWasSpace = false
        while index < line.endIndex {
            let scalar = line[index]
            if scalar == " " {
                if !previousWasSpace { result.append(scalar) }
                previousWasSpace = true
            } else {
                previousWasSpace = false
                result.append(scalar)
            }
            index = line.index(after: index)
        }
    }
    return String(result)
}

/// `word ]` → `word]`. Unit markers and link syntax pick up a gap-inserted
/// space before the bracket.
func pdfRemoveSpacesBeforeClosingBrackets(_ text: String) -> String {
    var result = String.UnicodeScalarView()
    result.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
        if scalar == "]", result.last == " " { result.removeLast() }
        result.append(scalar)
    }
    return String(result)
}

/// `word .` → `word.`
///
/// A style boundary can strand a trailing period or comma in its own
/// fragment, and several assembly paths join fragments with a space. Only
/// fires when the punctuation ends its token, so a decimal is untouched, and
/// never inside a run of dots, so ellipses and dot leaders survive.
func pdfRemoveSpacesBeforeSentencePunctuation(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var result = String.UnicodeScalarView()
    result.reserveCapacity(scalars.count)
    for (index, scalar) in scalars.enumerated() {
        if scalar == "." || scalar == "," || scalar == ";", result.last == " " {
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            // A pipe counts as a token end so table cells get the same fix.
            let tokenEnds = next.map { $0.properties.isWhitespace || $0 == "|" } ?? true
            let inDotRun = scalar == "." && next == "."
            if tokenEnds, !inDotRun { result.removeLast() }
        }
        result.append(scalar)
    }
    return String(result)
}

/// `\.{4,}` → ` ... `
func pdfCollapseDotLeaders(_ text: String) -> String {
    var result = String.UnicodeScalarView()
    var run = 0
    func flush() {
        // The pattern is greedy, so a run of six dots is one replacement
        // rather than four dots plus two.
        if run >= 4 {
            result.append(contentsOf: " ... ".unicodeScalars)
        } else {
            result.append(contentsOf: String(repeating: ".", count: run).unicodeScalars)
        }
        run = 0
    }
    for scalar in text.unicodeScalars {
        if scalar == "." {
            run += 1
        } else {
            flush()
            result.append(scalar)
        }
    }
    flush()
    return String(result)
}

/// The letters the reference's hyphenation pattern accepts on either side —
/// ASCII plus the accented forms its Portuguese corpus needed. Not a general
/// "is a letter" test: `é` joins, `ü` does not.
private let pdfHyphenLetters: Set<Unicode.Scalar> = Set(
    ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        + "\u{e1}\u{e0}\u{e2}\u{e3}\u{e9}\u{e8}\u{ea}\u{ed}\u{ef}\u{f3}\u{f4}"
        + "\u{f5}\u{f6}\u{fa}\u{e7}\u{f1}"
        + "\u{c1}\u{c0}\u{c2}\u{c3}\u{c9}\u{c8}\u{ca}\u{cd}\u{cf}\u{d3}\u{d4}"
        + "\u{d5}\u{d6}\u{da}\u{c7}\u{d1}").unicodeScalars)

/// `letter - letter` → `letter-letter`, standing in for the reference's
/// `([a-zA-Z…]) - ([a-zA-Z…])` replacement.
///
/// A compound word broken across lines comes back with its hyphen spaced.
/// Requiring a letter on both sides is what keeps a list item's `- ` marker
/// from being eaten. Matches do not overlap, exactly as `replace_all` does
/// not: in `a - b - c` the second hyphen is considered starting after the
/// first match, so `b` cannot open a match it has already closed.
func pdfFixHyphenation(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var result = String.UnicodeScalarView()
    result.reserveCapacity(scalars.count)
    var index = 0
    while index < scalars.count {
        if index + 4 < scalars.count,
            pdfHyphenLetters.contains(scalars[index]),
            scalars[index + 1] == " ",
            scalars[index + 2] == "-",
            scalars[index + 3] == " ",
            pdfHyphenLetters.contains(scalars[index + 4])
        {
            result.append(scalars[index])
            result.append("-")
            result.append(scalars[index + 4])
            index += 5
            continue
        }
        result.append(scalars[index])
        index += 1
    }
    return String(result)
}

/// Whether every scalar is an ASCII digit — Rust's
/// `chars().all(|c| c.is_ascii_digit())`, which is true of the empty string.
private func allASCIIDigits<S: StringProtocol>(_ text: S) -> Bool {
    text.unicodeScalars.allSatisfy { $0.isASCIIDigit }
}

/// Whether a line is a standalone page number.
func pdfIsPageNumberLine(_ trimmed: String) -> Bool {
    if trimmed.isEmpty { return false }

    // Bare number, up to four digits. The length bound is in bytes, as in the
    // reference, and every digit that passes is ASCII anyway.
    if trimmed.utf8.count <= 4, allASCIIDigits(trimmed) { return true }

    let lower = trimmed.rustLowercased()
    if lower.hasPrefix("page") {
        let rest = String(lower.dropFirst(4)).rustTrim()
        // `Page   of` — a placeholder whose numbers never got filled in.
        if rest == "of" || rest.hasPrefix("of ") { return true }
        if rest.unicodeScalars.first?.isASCIIDigit == true { return true }
        if rest.isEmpty
            || rest.rustSplitWhitespace().allSatisfy({ $0 == "of" || allASCIIDigits($0) })
        {
            return true
        }
    }

    // `3 of 12`
    let scalars = Array(trimmed.unicodeScalars)
    let needle = Array(" of ".unicodeScalars)
    if scalars.count >= needle.count {
        for start in 0...(scalars.count - needle.count)
        where Array(scalars[start..<(start + needle.count)]) == needle {
            let before = String(String.UnicodeScalarView(scalars[..<start])).rustTrim()
            let after = String(
                String.UnicodeScalarView(scalars[(start + needle.count)...])
            ).rustTrim()
            if !before.isEmpty, !after.isEmpty,
                allASCIIDigits(before), allASCIIDigits(after)
            {
                return true
            }
            break
        }
    }

    // `- 7 -`, the centred form.
    if trimmed.count >= 3, trimmed.hasPrefix("-"), trimmed.hasSuffix("-") {
        let inner = String(trimmed.dropFirst().dropLast()).rustTrim()
        if !inner.isEmpty, allASCIIDigits(inner) { return true }
    }

    return false
}

/// Drop page numbers that stand alone.
///
/// Only when isolated — blank lines or a page rule on both sides — or sitting
/// immediately before a page rule. A number in the middle of a paragraph is
/// part of the prose, whatever it looks like.
func pdfRemovePageNumbers(_ text: String) -> String {
    let lines = text.rustLines()
    var kept: [String] = []
    for (index, line) in lines.enumerated() {
        let trimmed = line.rustTrim()
        if pdfIsPageNumberLine(trimmed) {
            func trimmedLine(_ at: Int) -> String? {
                at >= 0 && at < lines.count ? lines[at].rustTrim() : nil
            }
            let previous = trimmedLine(index - 1)
            let next = trimmedLine(index + 1)
            let openBefore = previous == "---" || previous == "" || index == 0
            let openAfter = next == "---" || next == "" || index + 1 == lines.count
            let beforeRule =
                next == "---" || (next == "" && trimmedLine(index + 2) == "---")
            if (openBefore && openAfter) || beforeRule { continue }
        }
        kept.append(line)
    }
    return kept.joined(separator: "\n")
}

/// Whether a scalar may appear inside a bare URL — the reference's
/// `[^\s<>\)\]]`.
private func pdfIsUrlBody(_ scalar: Unicode.Scalar) -> Bool {
    !scalar.isRustWhitespace && scalar != "<" && scalar != ">" && scalar != ")" && scalar != "]"
}

/// Whether a scalar may *end* a bare URL — the reference's
/// `[^\s<>\)\]\.\,;]`, which additionally refuses trailing sentence
/// punctuation so `see https://x.test/a.` does not swallow the period.
private func pdfIsUrlEnd(_ scalar: Unicode.Scalar) -> Bool {
    pdfIsUrlBody(scalar) && scalar != "." && scalar != "," && scalar != ";"
}

/// Wrap bare URLs in Markdown link syntax, standing in for the reference's
/// `https?://[^\s<>\)\]]+[^\s<>\)\]\.\,;]`.
///
/// A URL already inside link syntax is left alone — recognised either by the
/// `](` immediately before it or by an unclosed `[` anywhere earlier, which
/// is the reference's own bracket-counting test and is fooled by a literal
/// unbalanced bracket exactly as it is there.
func pdfFormatUrls(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var result = String.UnicodeScalarView()
    var index = 0
    // Running bracket counts over the *input* consumed so far, including the
    // insides of URLs already matched — the reference recomputes them from
    // `text[..start]` at every match, so a bracket inside an earlier URL
    // still counts. Counting the emitted output instead would also count the
    // brackets this function itself writes, which the reference never sees.
    var openBrackets = 0
    var closeBrackets = 0

    func matchLength(at start: Int) -> Int? {
        for scheme in ["https://", "http://"] {
            let pattern = Array(scheme.unicodeScalars)
            guard start + pattern.count <= scalars.count,
                Array(scalars[start..<(start + pattern.count)]) == pattern
            else { continue }
            // The pattern needs at least one body scalar and one end scalar,
            // so a bare scheme does not match.
            var end = start + pattern.count
            while end < scalars.count, pdfIsUrlBody(scalars[end]) { end += 1 }
            guard end > start + pattern.count else { return nil }
            // Give back trailing scalars the final class refuses.
            var last = end - 1
            while last >= start + pattern.count, !pdfIsUrlEnd(scalars[last]) { last -= 1 }
            guard last >= start + pattern.count else { return nil }
            return last + 1 - start
        }
        return nil
    }

    while index < scalars.count {
        if let length = matchLength(at: index) {
            let alreadyLinked =
                index >= 2 && scalars[index - 2] == "]" && scalars[index - 1] == "("
            let insideLinkText = openBrackets > closeBrackets
            let matched = scalars[index..<(index + length)]
            let url = String(String.UnicodeScalarView(matched))
            if alreadyLinked || insideLinkText {
                result.append(contentsOf: url.unicodeScalars)
            } else {
                result.append(contentsOf: "[\(url)](\(url))".unicodeScalars)
            }
            for scalar in matched {
                if scalar == "[" { openBrackets += 1 }
                if scalar == "]" { closeBrackets += 1 }
            }
            index += length
            continue
        }
        let scalar = scalars[index]
        if scalar == "[" { openBrackets += 1 }
        if scalar == "]" { closeBrackets += 1 }
        result.append(scalar)
        index += 1
    }
    return String(result)
}
