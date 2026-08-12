/// Span-level text-quality detection, ported from the second half of
/// `text_quality.rs` in pdf-inspector.
///
/// Wave 42 ported the detectors that judge a whole page's markdown. These
/// judge one extracted span at a time, so a localised garbled run on an
/// otherwise clean page is caught without any single span having to condemn
/// the page on its own — the page-level rule then weighs the accumulated
/// evidence.
///
/// The classes of damage, in the order they are trusted: dollar-as-space,
/// private-use runs, CID garbage and C1-control tokens are *strong* signals —
/// text almost never contains them. Replacement characters are weaker, because
/// a mathematical formula legitimately produces a few.

/// How badly a span is broken. Strong issues condemn on sight; replacement
/// characters only count as accumulated evidence.
enum PdfTextSpanIssue {
    case replacement
    case strong
}

/// What is wrong with one extracted span, if anything.
func pdfTextSpanIssueKind(_ text: String) -> PdfTextSpanIssue? {
    let text = text.rustTrim()
    if text.isEmpty { return nil }

    if pdfHasDollarAsSpacePattern(text) || pdfHasPrivateUseTextRun(text)
        || pdfIsCidGarbage(text) || pdfHasCidControlToken(text)
    {
        return .strong
    }
    if pdfHasReplacementTextRun(text) { return .replacement }
    return nil
}

/// Whether a span shows any decoding issue at all.
func pdfTextSpanHasDecodingIssue(_ text: String) -> Bool {
    pdfTextSpanIssueKind(text) != nil
}

/// Total replacement characters in a span, and the longest unbroken run.
func pdfReplacementTextStats(_ text: String) -> (replacements: Int, longestRun: Int) {
    var replacements = 0
    var currentRun = 0
    var longestRun = 0
    for scalar in text.unicodeScalars {
        if scalar.value == 0xFFFD {
            replacements += 1
            currentRun += 1
            longestRun = max(longestRun, currentRun)
        } else {
            currentRun = 0
        }
    }
    return (replacements, longestRun)
}

/// Whether a span's replacement characters are dense enough to matter: two in
/// a row, or three in total.
func pdfHasReplacementTextRun(_ text: String) -> Bool {
    let stats = pdfReplacementTextStats(text)
    return stats.longestRun >= 2 || stats.replacements >= 3
}

/// One page's accumulated evidence of replacement-character damage.
struct PdfPageTextQualityEvidence {
    var characters = 0
    var replacementCharacters = 0
    /// How many separate spans on the page contained a replacement run.
    var replacementSpans = 0
    var longestReplacementRun = 0
}

/// Whether a page's replacement evidence justifies OCR.
///
/// The thresholds are in basis points because the judgement is about
/// *density*, not count: a page thick with mathematics legitimately produces a
/// handful of replacement characters, and forcing OCR on it would be worse
/// than the damage. Three ways to qualify — enough bad text, repeated bad
/// spans, or one long run — and a shortcut for a page that is nothing *but* a
/// short broken text layer, where even two adjacent replacements are the whole
/// story.
func pdfPageReplacementEvidenceNeedsOcr(_ evidence: PdfPageTextQualityEvidence) -> Bool {
    if evidence.replacementCharacters == 0 || evidence.characters == 0 { return false }

    if evidence.characters <= 80 && evidence.longestReplacementRun >= 2 { return true }

    let densityBasisPoints = evidence.replacementCharacters * 10_000 / evidence.characters
    let enoughBadText = evidence.replacementCharacters >= 12 && densityBasisPoints >= 500
    let repeatedBadSpans = evidence.replacementSpans >= 3 && densityBasisPoints >= 250
    let longBadRun = evidence.longestReplacementRun >= 8 && densityBasisPoints >= 250
    return enoughBadText || repeatedBadSpans || longBadRun
}

/// Whether a scalar sits in one of the three Private Use Areas.
func pdfIsPrivateUseScalar(_ scalar: Unicode.Scalar) -> Bool {
    (0xE000...0xF8FF).contains(scalar.value) || (0xF0000...0xFFFFD).contains(scalar.value)
        || (0x100000...0x10FFFD).contains(scalar.value)
}

/// Whether a span carries a run of private-use characters.
///
/// CID values passed through unmapped land here. Whitespace breaks a run and
/// is not counted at all, so "spaced out" damage still reads as separate runs.
func pdfHasPrivateUseTextRun(_ text: String) -> Bool {
    var total = 0
    var privateUse = 0
    var currentRun = 0
    var longestRun = 0

    for scalar in text.unicodeScalars {
        if scalar.properties.isWhitespace {
            currentRun = 0
            continue
        }
        total += 1
        if pdfIsPrivateUseScalar(scalar) {
            privateUse += 1
            currentRun += 1
            longestRun = max(longestRun, currentRun)
        } else {
            currentRun = 0
        }
    }

    if privateUse == 0 { return false }
    return longestRun >= 3 || (total >= 5 && privateUse >= 2 && privateUse * 2 >= total)
}

/// Whether any whitespace-separated token is thick with C1 controls.
func pdfHasCidControlToken(_ text: String) -> Bool {
    text.rustSplitWhitespace().contains { pdfTokenHasCidControl(String($0)) }
}

/// Whether one token is thick with C1 controls: five characters or more, at
/// least two of them controls, and controls at 5% or more of its length.
func pdfTokenHasCidControl(_ token: String) -> Bool {
    var total = 0
    var c1Controls = 0
    for scalar in token.unicodeScalars {
        total += 1
        if (0x80...0x9F).contains(scalar.value) { c1Controls += 1 }
    }
    return total >= 5 && c1Controls >= 2 && c1Controls * 20 >= total
}

/// Whether extracted text is predominantly non-alphanumeric.
///
/// A broken encoding produces things like `----1-.-.-.___  --.-. .._ I_---.`,
/// where most characters are punctuation. Real text in any language is more
/// than half alphanumeric.
///
/// Two exclusions keep it honest. A run of three or more dots, underscores or
/// middle dots is a *table-of-contents leader* and is skipped entirely — it is
/// layout, not damage. And the Markdown syntax this port adds itself is never
/// counted against the PDF.
///
/// Those exclusions have outgrown the reference's own documentation: its doc
/// comment cites `----1-.-.-.___  --.-. .._ I_---.` as the motivating example,
/// but hyphens are Markdown syntax and underscore runs are leaders, so almost
/// nothing in that string is counted and it no longer triggers. Verified
/// against the reference rather than assumed.
func pdfIsGarbageText(_ markdown: String) -> Bool {
    var alphanumeric = 0
    var nonAlphanumeric = 0

    let scalars = Array(markdown.unicodeScalars)
    var index = 0
    while index < scalars.count {
        let scalar = scalars[index]
        var runEnd = index + 1
        while runEnd < scalars.count && scalars[runEnd] == scalar { runEnd += 1 }

        let isDecorativeLeader =
            (scalar == "." || scalar == "_" || scalar == "\u{00B7}") && runEnd - index >= 3
        if !isDecorativeLeader {
            for runScalar in scalars[index..<runEnd] {
                if runScalar.properties.isWhitespace { continue }
                // Markdown syntax this port emits, not anything the PDF said.
                if runScalar == "#" || runScalar == "*" || runScalar == "|" || runScalar == "-"
                    || runScalar == "\n"
                {
                    continue
                }
                if pdfIsAlphanumericScalar(runScalar) {
                    alphanumeric += 1
                } else {
                    nonAlphanumeric += 1
                }
            }
        }
        index = runEnd
    }

    let total = alphanumeric + nonAlphanumeric
    return total >= 50 && alphanumeric * 2 < total
}

/// Whether text looks like a failed CID→Unicode mapping.
///
/// Beyond the general garbage test, two signatures: C1 control characters,
/// which valid text in any language almost never contains, and a page thick
/// with high Latin-1 but thin on ASCII letters — CID values in `0x80…0xFF`
/// reinterpreted as accented Latin, which is what a CJK document does when its
/// mapping fails.
func pdfIsCidGarbage(_ text: String) -> Bool {
    if pdfIsGarbageText(text) { return true }

    var total = 0
    var c1Controls = 0
    var highLatin = 0
    for scalar in text.unicodeScalars {
        if scalar.properties.isWhitespace { continue }
        total += 1
        // A middle dot counts toward the total but is exempt from both
        // signatures — reproduced in that order, so it dilutes the ratios.
        if scalar == "\u{00B7}" { continue }
        if (0x80...0x9F).contains(scalar.value) { c1Controls += 1 }
        if (0xA0...0xFF).contains(scalar.value) { highLatin += 1 }
    }
    if total < 5 { return false }

    if c1Controls >= 2 && c1Controls * 20 >= total { return true }

    // The length floor keeps a short maths token like "2×()×" from routing a
    // clean page to OCR.
    let asciiLetters = text.unicodeScalars.filter { pdfIsAsciiAlphabetic($0) }.count
    return total >= 20 && highLatin * 5 >= total * 2 && asciiLetters * 3 < total
}

/// Rust's `char::is_alphanumeric`: alphabetic, or a number by general
/// category. Not the same as "letter or ASCII digit".
func pdfIsAlphanumericScalar(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.properties.isAlphabetic { return true }
    switch scalar.properties.generalCategory {
    case .decimalNumber, .letterNumber, .otherNumber:
        return true
    default:
        return false
    }
}
