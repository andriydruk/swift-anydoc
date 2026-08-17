/// Line preprocessing, ported from `markdown/preprocess.rs`:
/// `effective_heading_level`, `merge_heading_lines`, `merge_drop_caps`, and
/// the text-comparison helpers `normalize_whitespace`,
/// `normalize_for_comparison`, `is_structural_line` and
/// `is_decorative_separator`.
///
/// These run before anything is written, repairing lines that the layout
/// stage got right geometrically and wrong semantically: a heading that
/// wrapped is two lines and one heading, and a drop cap is a line of its own
/// that belongs to the front of another.
///
/// `strip_repeated_lines` — the running-header remover, and the largest
/// thing in this file — lives in `PdfStripRepeated.swift` (wave 89) and is
/// called from the pipeline when `stripHeadersFooters` is on.

/// The heading level a line carries, tags first.
///
/// A struct-tree tag beats the font heuristic outright, even when the two
/// disagree about the level. A tagged `H2` set at title size is an H2.
func pdfEffectiveHeadingLevel(
    _ line: PdfTextLine, baseSize: Float, tiers: [Float], structRoles: PdfStructRoleMap?
) -> Int? {
    // Note this is *not* `pdfResolveLineStructRole`: it does not skip
    // container roles, it simply ignores every role that names no level and
    // keeps looking. The two walk the same map to different ends.
    if let roles = structRoles, let pageRoles = roles[line.page] {
        for item in line.items {
            guard let mcid = item.mcid, let role = pageRoles[mcid] else { continue }
            if let level = pdfStructRoleHeadingLevel(role) { return level }
        }
    }

    // The *first* item's size, and the base size when there are no items —
    // which makes an empty line a body line rather than a heading.
    let font = line.items.first?.fontSize ?? baseSize
    return pdfHeadingLevel(
        fontSize: font, bodySize: baseSize, tiers: tiers,
        isBold: pdfLineIsMostlyBold(line))
}

/// Merge consecutive heading lines that are one wrapped heading.
///
/// Two conditions, either of which merges. The first is the ordinary one:
/// consecutive lines at the same heading level, on the same page, within
/// twice the font size, totalling twenty words or fewer.
///
/// The second exists because a bold heading at body size never reaches a
/// tier, so a wrapped one would split into two output headings. It is
/// deliberately narrow — both lines fully bold and tier-less, a gap under
/// 1.6× the font, the continuation starting lowercase, and no terminal
/// punctuation on the line before. Bold list labels and bold sentences start
/// with markers or capitals and are left alone.
func pdfMergeHeadingLines(
    _ lines: [PdfTextLine], baseSize: Float, tiers: [Float], structRoles: PdfStructRoleMap?
) -> [PdfTextLine] {
    if lines.isEmpty { return lines }
    var result: [PdfTextLine] = []
    result.reserveCapacity(lines.count)

    func level(_ line: PdfTextLine) -> Int? {
        pdfEffectiveHeadingLevel(
            line, baseSize: baseSize, tiers: tiers, structRoles: structRoles)
    }
    func allBold(_ line: PdfTextLine) -> Bool {
        !line.items.isEmpty && line.items.allSatisfy(\.isBold)
    }

    for line in lines {
        let lineLevel = level(line)
        let lineFont = line.items.first?.fontSize ?? baseSize

        var shouldMerge = false
        if let previous = result.last, let currentLevel = lineLevel {
            let yGap = previous.y - line.y
            let previousWords = pdfLineText(previous).rustSplitWhitespace().count
            let currentWords = pdfLineText(line).rustSplitWhitespace().count
            shouldMerge =
                previous.page == line.page && level(previous) == currentLevel
                // Strictly downward and strictly under twice the font size.
                && yGap > 0 && yGap < lineFont * 2
                && previousWords + currentWords <= 20
        }

        if !shouldMerge, let previous = result.last {
            let previousTrimmed = pdfLineText(previous).rustTrimEnd()
            let currentTrimmed = pdfLineText(line).rustTrim()
            let yGap = previous.y - line.y
            let terminal: Set<Unicode.Scalar> = [".", ":", ";", "!", "?"]
            shouldMerge =
                lineLevel == nil && level(previous) == nil
                && previous.page == line.page
                && allBold(previous) && allBold(line)
                && yGap > 0 && yGap < lineFont * 1.6
                && (currentTrimmed.unicodeScalars.first.map {
                    Character($0).isLowercase
                } ?? false)
                && !(previousTrimmed.unicodeScalars.last.map { terminal.contains($0) } ?? false)
                && previousTrimmed.rustSplitWhitespace().count
                    + currentTrimmed.rustSplitWhitespace().count <= 20
        }

        if shouldMerge {
            // The join is carried by a *copy of the first item* whose text
            // gains a leading space, rather than by anything the writer does
            // later — so the merged line reads as two words, not one.
            var previous = result[result.count - 1]
            if let first = line.items.first {
                var spaceItem = first
                spaceItem.text = " " + first.text.rustTrimStart()
                previous.items.append(spaceItem)
            }
            previous.items.append(contentsOf: line.items.dropFirst())
            result[result.count - 1] = previous
        } else {
            result.append(line)
        }
    }
    return result
}

/// Attach drop caps to the lines they open.
///
/// A drop cap is a single outsized capital set beside the first lines of a
/// paragraph. Because the layout stage sorts by baseline, it usually arrives
/// *after* the line it belongs to, so this scans the lines already emitted
/// for the paragraph's opening line and prepends the character there.
///
/// The target is the first line on the same page that begins lowercase and
/// opens a paragraph — meaning the line before it does not begin lowercase.
/// The drop-cap line itself is dropped.
func pdfMergeDropCaps(_ lines: [PdfTextLine], baseSize: Float) -> [PdfTextLine] {
    var result: [PdfTextLine] = []
    result.reserveCapacity(lines.count)

    for line in lines {
        let trimmed = pdfLineText(line).rustTrim()
        // `len() <= 2` is bytes, so `O ` and `Oh` both qualify and a
        // two-character accented pair may not.
        let isDropCap =
            trimmed.utf8.count <= 2
            && (line.items.first?.fontSize ?? 0) >= baseSize * 2.5
            && (trimmed.unicodeScalars.first.map { Character($0).isUppercase } ?? false)

        guard isDropCap, let dropCharacter = trimmed.unicodeScalars.first else {
            result.append(line)
            continue
        }

        var targetIndex: Int?
        for (index, candidate) in result.enumerated() where candidate.page == line.page {
            let candidateText = pdfLineText(candidate).rustTrim()
            guard candidateText.unicodeScalars.first.map({ Character($0).isLowercase }) ?? false
            else { continue }
            // An empty preceding line reads as lowercase — `unwrap_or(true)`
            // in the reference — so it does *not* open a paragraph.
            let isParagraphStart: Bool
            if index == 0 {
                isParagraphStart = true
            } else {
                let before = pdfLineText(result[index - 1]).rustTrim()
                isParagraphStart = !(before.unicodeScalars.first.map {
                    Character($0).isLowercase
                } ?? true)
            }
            if isParagraphStart {
                targetIndex = index
                break
            }
        }

        if let targetIndex, !result[targetIndex].items.isEmpty {
            // Note the target's own text is trimmed on both sides here, not
            // just at the front.
            let existing = result[targetIndex].items[0].text.rustTrim()
            result[targetIndex].items[0].text = String(Character(dropCharacter)) + existing
        }
        // The drop-cap line is never emitted, whether or not it found a home.
    }
    return result
}

/// Trim, and collapse every internal run of whitespace to one space.
func pdfNormalizeWhitespace(_ text: String) -> String {
    text.rustSplitWhitespace().joined(separator: " ")
}

/// Normalise a line for the running-header frequency count.
///
/// Leading and trailing digit runs are stripped so `Chapter 3 — Page 5` and
/// `Chapter 3 — Page 6` compare equal. Only ASCII digits count.
func pdfNormalizeForComparison(_ text: String) -> String {
    var value = Substring(pdfNormalizeWhitespace(text))
    while let first = value.unicodeScalars.first, pdfIsAsciiDigitScalarValue(first) {
        value = value.dropFirst()
    }
    value = value.rustTrimStartSub()
    while let last = value.unicodeScalars.last, pdfIsAsciiDigitScalarValue(last) {
        value = value.dropLast()
    }
    return String(value.rustTrimEndSub())
}

/// Whether a line is a heading or a list item, and so must never be stripped
/// as a running header.
func pdfIsStructuralLine(_ text: String) -> Bool {
    let trimmed = text.rustTrimStart()
    if trimmed.hasPrefix("#") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
        || trimmed.hasPrefix("• ")
    {
        return true
    }
    // `&&` binds tighter than `||` in Rust as it does here: a leading digit
    // counts only when the line also carries `. ` or `) ` somewhere.
    let startsWithDigit =
        trimmed.unicodeScalars.first.map(pdfIsAsciiDigitScalarValue) ?? false
    return startsWithDigit && (trimmed.contains(". ") || trimmed.contains(") "))
}

/// Whether a line is a rule — one character repeated.
///
/// Note the empty string is not one, but a *single* character is: the
/// reference takes the first character and asks whether all the rest match,
/// which is vacuously true when there are none.
func pdfIsDecorativeSeparator(_ text: String) -> Bool {
    var scalars = text.unicodeScalars.makeIterator()
    guard let first = scalars.next() else { return false }
    while let next = scalars.next() {
        if next != first { return false }
    }
    return true
}
