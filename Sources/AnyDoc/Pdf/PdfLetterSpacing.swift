/// Repair for letter-spaced text items, ported from `fix_letterspaced_items`,
/// `compute_canva_join_threshold` and `collect_gap_ratios` in
/// pdf-inspector's `text_utils.rs`.
///
/// Canva renders text with CSS-style letter-spacing, which reaches the PDF as
/// one glyph per positioning operation. The extractor's `TJ` handler then
/// inserts a space at every gap, so a word arrives as `"a r i b"` instead of
/// `"arib"` — or, on the other variant, as one item per character with no
/// spaces at all.
///
/// Both variants need the same second thing: a *higher* join threshold. Every
/// gap on such a page is wide by ordinary standards, so the default would
/// refuse to join anything and the page would come out one letter per word.

/// The join threshold for an ordinary page, as a fraction of font size.
private let pdfDefaultJoinThreshold: Float = 0.10

/// Whether an item's text alternates single characters and spaces.
///
/// Three characters minimum, since `"a b"` is the shortest thing that can
/// show the pattern at all.
func pdfIsLetterspaced(_ text: String) -> Bool {
    let scalars = Array(text.rustTrim().unicodeScalars)
    guard scalars.count >= 3 else { return false }
    for (index, scalar) in scalars.enumerated() {
        if index % 2 == 0 {
            if scalar == " " { return false }
        } else if scalar != " " {
            return false
        }
    }
    return true
}

/// Strip the spurious spaces from letter-spaced items, and return the join
/// threshold the page should use.
///
/// Two detection paths, because Canva emits two shapes. The first is the
/// `"a r i b"` pattern *within* items, and needs half the substantial items to
/// show it. The second is one item per character, with no spaces to remove —
/// nothing is rewritten there, but the threshold still has to be raised.
///
/// Note the threshold is computed *before* the spaces are removed: the gaps
/// are what it measures, and stripping first would change them.
func pdfFixLetterspacedItems(_ items: inout [PdfLayoutItem]) -> Float {
    if items.isEmpty { return pdfDefaultJoinThreshold }

    var letterspacedCount = 0
    var substantialItems = 0
    for item in items {
        let trimmed = item.text.rustTrim()
        // `len()` is bytes in the reference, so a three-scalar CJK item counts
        // as substantial where a three-byte ASCII one is the boundary case.
        if trimmed.isEmpty || trimmed.utf8.count < 3 { continue }
        substantialItems += 1
        if pdfIsLetterspaced(item.text) { letterspacedCount += 1 }
    }

    if substantialItems < 4 || letterspacedCount * 2 < substantialItems {
        // The per-character variant: no `"a b"` pattern to find, so it is
        // detected by the sheer proportion of one-character items instead.
        let singleCharacterCount = items.filter { $0.text.rustTrim().unicodeScalars.count == 1 }
            .count
        if items.count >= 10 && singleCharacterCount * 2 >= items.count {
            let threshold = pdfCanvaJoinThreshold(items)
            // Only trust it when it landed well above the ordinary range —
            // otherwise the page was probably not letter-spaced after all.
            if threshold > 0.40 { return threshold }
        }
        return pdfDefaultJoinThreshold
    }

    let threshold = pdfCanvaJoinThreshold(items)
    for index in items.indices where pdfIsLetterspaced(items[index].text) {
        items[index].text = String(
            String.UnicodeScalarView(items[index].text.unicodeScalars.filter { $0 != " " }))
    }
    return threshold
}

/// The join threshold for a page confirmed to be letter-spaced.
///
/// The median gap ratio times 1.55, clamped to a sane band. Both the largest
/// *and* the smallest observed gap must clear 0.40 — if any pair sits at an
/// ordinary distance the page is not uniformly letter-spaced, and raising the
/// threshold would glue real words together.
func pdfCanvaJoinThreshold(_ items: [PdfLayoutItem]) -> Float {
    let sorted = pdfCollectGapRatios(items).sorted()
    guard sorted.count >= 8 else { return pdfDefaultJoinThreshold }
    guard let smallest = sorted.first, let largest = sorted.last,
        largest >= 0.40, smallest >= 0.40
    else { return pdfDefaultJoinThreshold }

    let median = sorted[sorted.count / 2]
    return min(max(median * 1.55, 0.50), 2.0)
}

/// Gap-to-font-size ratios for adjacent item pairs.
///
/// CJK is skipped because it is set without spaces, so its gaps say nothing
/// about letter-spacing. The gap is measured in whichever direction the pair
/// runs, so a right-to-left line contributes the same positive ratios as a
/// left-to-right one. Ratios outside 0…3 are discarded as column jumps.
func pdfCollectGapRatios(_ items: [PdfLayoutItem]) -> [Float] {
    var ratios: [Float] = []
    for index in 0..<max(items.count - 1, 0) {
        let previous = items[index]
        let current = items[index + 1]

        let previousLast = previous.text.rustTrim().unicodeScalars.last
        let currentFirst = current.text.rustTrim().unicodeScalars.first
        if let previousLast, pdfIsCjkScalarValue(previousLast) { continue }
        if let currentFirst, pdfIsCjkScalarValue(currentFirst) { continue }

        if previous.width <= 0 || previous.fontSize <= 0 { continue }

        let gap =
            previous.x <= current.x
            ? current.x - (previous.x + previous.width)
            : previous.x - (current.x + current.width)

        let ratio = gap / previous.fontSize
        if ratio >= 0 && ratio <= 3 { ratios.append(ratio) }
    }
    return ratios
}
