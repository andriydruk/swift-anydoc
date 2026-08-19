/// Merging the fragments a PDF breaks its text into, ported from
/// pdf-inspector's `extractor/mod.rs` (`merge_text_items`,
/// `merge_subscript_items` and their helpers).
///
/// A PDF does not draw words. It draws whatever the producer found
/// convenient — a glyph at a time when the text is letterspaced, a fragment
/// per kerning pair, a separate run wherever the style changes. Reassembling
/// that into words is a distinct pass, and it has to guess where the spaces
/// were, because a space is usually not in the file at all: it is a gap.
///
/// The guessing is all in the thresholds, and they are the reference's.

/// Items whose baselines are within this are on the same line.
private let pdfMergeLineTolerance: Float = 5.0

/// Fragments merge only when their sizes are within a fifth of each other.
private let pdfMergeSizeBand: Float = 0.20

/// The width a fragment occupies for merging, capped when word spacing has
/// inflated it.
///
/// `Tw` widens only strings that actually contain a space, so a run whose
/// average glyph is implausibly wide has had its advance stretched, and using
/// that width unchanged would leave a hole the next fragment cannot cross.
func pdfEffectiveMergeWidth(_ item: PdfLayoutItem) -> Float {
    guard item.width > 0, item.fontSize > 0 else { return item.width }
    guard item.text.contains(" ") else { return item.width }
    // CJK glyphs really are about one em wide, so the cap does not apply.
    if item.text.unicodeScalars.contains(where: pdfIsCjkScalar) { return item.width }

    let count = item.text.unicodeScalars.count
    guard count > 0 else { return item.width }
    let average = item.width / Float(count)
    // Proportional text runs about half an em per glyph and monospace about
    // three fifths; past 0.85 the advance has been stretched.
    guard average > item.fontSize * 0.85 else { return item.width }
    return min(Float(count) * item.fontSize * 0.6, item.width)
}

/// Whether a fragment is a bullet standing on its own.
private func pdfIsStandaloneBullet(_ text: String) -> Bool {
    ["•", "○", "●", "◦"].contains(text.rustTrim())
}

/// The CJK blocks the reference treats as never taking spaces between glyphs.
private func pdfIsSpacelessCjkScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040...0x30FF,  // Hiragana and Katakana
        0x3400...0x4DBF,  // CJK Extension A
        0x4E00...0x9FFF,  // CJK Unified Ideographs
        0xF900...0xFAFF:  // Compatibility Ideographs
        return true
    default: return false
    }
}

/// The wider CJK range, which additionally covers Hangul and the fullwidth
/// forms — wide enough that a glyph is an em, so the width cap is skipped.
private func pdfIsCjkScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x1100...0x11FF, 0x3000...0x30FF, 0x3130...0x318F, 0x3400...0x4DBF,
        0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF,
        0xFF00...0xFFEF:
        return true
    default: return false
    }
}

/// Where a letterspaced run ends, and the gap below which its junctions are
/// *not* word boundaries.
///
/// Display tracking spaces every glyph of a heading, so the fixed
/// eight-percent threshold would break `TRACKED` into seven words. When a run
/// of single glyphs has a typical gap wide enough to do that, the run gets its
/// own floor instead — but only when it is all-caps or CJK, since geometry
/// alone cannot tell spaced single letters (`x y z`) from a tracked
/// title-case word.
func pdfTrackedRunSpaceFloor(_ group: [PdfLayoutItem], from start: Int) -> (end: Int, floor: Float)?
{
    let minimumGaps = 4
    let first = group[start]
    guard first.text.rustTrim().unicodeScalars.count == 1, first.fontSize > 0 else { return nil }
    let fontSize = first.fontSize

    // Walk under the same break conditions as the merge loop, so the indices
    // the caller compares against stay aligned.
    var gaps: [Float] = []
    var endX = first.x + pdfEffectiveMergeWidth(first)
    var end = start
    for offset in (start + 1)..<group.count {
        let next = group[offset]
        if next.text.rustTrim().unicodeScalars.count != 1 { break }
        if abs(next.fontSize - fontSize) > fontSize * pdfMergeSizeBand { break }
        if next.isBold != first.isBold || next.isItalic != first.isItalic
            || next.isUnderline != first.isUnderline || next.isStrikeout != first.isStrikeout
        {
            break
        }
        let gap = next.x - endX
        if gap > fontSize * 0.5 || gap < -fontSize * 0.5 { break }
        gaps.append(gap / fontSize)
        endX = next.x + pdfEffectiveMergeWidth(next)
        end = offset
    }
    guard gaps.count >= 2 else { return nil }

    let sorted = gaps.sorted()
    let median = sorted[sorted.count / 2]

    let runScalars = group[start...end].flatMap { $0.text.rustTrim().unicodeScalars }
    let spacelessCjk =
        runScalars.allSatisfy { pdfIsSpacelessCjkScalar($0) || !$0.properties.isAlphabetic && !pdfIsAsciiDigitScalar($0) }
        && runScalars.contains(where: pdfIsSpacelessCjkScalar)
    let allCaps = runScalars.allSatisfy {
        $0.properties.isUppercase || pdfIsCjkScalar($0) || !$0.properties.isAlphabetic
    }
    guard spacelessCjk || allCaps else { return nil }

    if gaps.count >= minimumGaps {
        if median <= 0.075 { return nil }
    } else {
        // Two or three gaps demand a stricter shape — clearly wide and
        // uniform — because a genuine spaced sequence has the same count.
        let uniform = sorted[sorted.count - 1] <= max(sorted[0], 0.01) * 1.4
        if median < 0.09 || !uniform { return nil }
    }

    // Han and Kana take no inter-glyph spaces at all, so an uneven gap
    // distribution must not manufacture word boundaries.
    if spacelessCjk { return (end, .infinity) }

    // Word gaps, where there are any, form a second cluster above the letter
    // gaps: split at the largest relative jump. A single cluster is one word.
    var bestJump: Float = 1.0
    var floor: Float = .infinity
    for (low, high) in zip(sorted, sorted.dropFirst()) {
        let lo = max(low, 0.01)
        let hi = max(high, 0.01)
        let jump = hi / lo
        if jump > bestJump {
            bestJump = jump
            floor = (lo + hi) / 2
        }
    }
    if bestJump < 1.4 { floor = .infinity }
    return (end, floor * fontSize)
}

private func pdfIsAsciiDigitScalar(_ scalar: Unicode.Scalar) -> Bool {
    scalar >= "0" && scalar <= "9"
}

/// Join the fragments of each line into words.
///
/// **Not ported yet**, and each would change the grouping for a document that
/// needs it: right-to-left runs, which the reference sorts descending by x;
/// and the marked-content overlay order it preserves for `ActualText`
/// fragments, which cannot fire here at all because this port does not read
/// MCIDs — the reference's own test returns false without them.
func pdfMergeTextItems(_ items: [PdfLayoutItem]) -> [PdfLayoutItem] {
    guard !items.isEmpty else { return items }

    // Group by baseline, in first-seen order, exactly as the reference's
    // linear search over accumulated groups does.
    var groups: [(y: Float, items: [PdfLayoutItem])] = []
    for item in items {
        if let index = groups.firstIndex(where: { abs(item.y - $0.y) < pdfMergeLineTolerance }) {
            groups[index].items.append(item)
        } else {
            groups.append((item.y, [item]))
        }
    }

    // Lines run down the page; within a line, left to right.
    // **Direction-aware, and it has to happen here.** A right-to-left line
    // reads from its highest x, so the group is ordered that way before the
    // merge concatenates it — sorting afterwards is too late, because the
    // merge has already fused the runs into one item in the wrong order and
    // no later pass can tell where the seam was.
    //
    // `rtl-two-runs.pdf` is the case: one Arabic line drawn as two `Tj`
    // operators. Merged left-to-right it reads `ساللب`; the reference reads
    // `لبسال`, the same as the single-run version of the same line. Whether
    // the two runs then merge or stay separate does not matter — the order
    // is already right either way.
    //
    // **And a line the stream deliberately overlaid keeps its stream order**,
    // sorted neither way — see `pdfShouldPreserveOverlappingStreamOrder`. That
    // check runs on the group as the stream left it, so it must come before
    // the sort that would destroy the evidence.
    var preserveOrder = Set<Int>()
    for index in groups.indices {
        let rightToLeft = pdfIsRtlText(groups[index].items.map(\.text))
        if !rightToLeft && pdfShouldPreserveOverlappingStreamOrder(groups[index].items) {
            preserveOrder.insert(index)
            continue
        }
        groups[index].items.sort { rightToLeft ? $0.x > $1.x : $0.x < $1.x }
    }
    let preservedYs = Set(preserveOrder.map { groups[$0].y })
    groups.sort { $0.y > $1.y }

    var merged: [PdfLayoutItem] = []
    for group in groups {
        let line = group.items
        let preserved = preservedYs.contains(group.y)
        var index = 0
        while index < line.count {
            let first = line[index]
            var text = first.text
            var endX = first.x + pdfEffectiveMergeWidth(first)
            // A preserved line's runs are overlaid rather than tracked, so
            // the letter-spacing floor must not be measured across them.
            let tracked = preserved ? nil : pdfTrackedRunSpaceFloor(line, from: index)

            var next = index + 1
            while next < line.count {
                let candidate = line[next]
                if abs(candidate.fontSize - first.fontSize) > first.fontSize * pdfMergeSizeBand {
                    break
                }
                // Never merge across a style boundary. The merged fragment
                // carries the first one's flags, so absorbing a styled run
                // into a plain neighbour silently erases the styling — and
                // OR-ing underline instead would stretch a `<u>` span over
                // the plain text beside it.
                if candidate.isBold != first.isBold || candidate.isItalic != first.isItalic
                    || candidate.isUnderline != first.isUnderline
                    || candidate.isStrikeout != first.isStrikeout
                {
                    break
                }
                let gap = candidate.x - endX
                // A bullet on a preserved line reaches further: the text it
                // introduces was drawn separately and sits further off.
                let gapMax =
                    preserved && pdfIsStandaloneBullet(text)
                    ? first.fontSize * 1.2 : first.fontSize * 0.5
                if gap > gapMax { break }
                // **A preserved line is allowed to run backwards.** The
                // overlay starts left of the fragment it covers, so its gap
                // is negative by design; breaking on that is what stopped the
                // two from fusing, and left the later line sort free to
                // interleave them by x.
                if gap < -first.fontSize * 0.5 && !preserved { break }

                // Where the gap is a word boundary. Punctuation that joins
                // what precedes it never takes a space; a lowercase pair is
                // probably mid-word, so it gets a wider threshold to absorb
                // the `Tc`/`Tw` adjustments that shift advances relative to
                // `Td` positioning.
                let previousLast = text.rustTrimEnd().unicodeScalars.last
                let nextFirst = candidate.text.rustTrimStart().unicodeScalars.first
                let threshold: Float
                if let nextFirst, ".,;)]}".unicodeScalars.contains(nextFirst) {
                    threshold = first.fontSize * 0.25
                } else if previousLast?.properties.isLowercase == true,
                    nextFirst?.properties.isLowercase == true
                {
                    threshold = first.fontSize * 0.13
                } else {
                    threshold = first.fontSize * 0.08
                }
                let effective =
                    tracked.map { next <= $0.end ? $0.floor : threshold } ?? threshold
                if gap > effective { text += " " }
                text += candidate.text
                endX = candidate.x + pdfEffectiveMergeWidth(candidate)
                next += 1
            }

            var joined = first
            joined.text = text
            joined.width = endX - first.x
            merged.append(joined)
            index = next
        }
    }
    return merged
}

/// The Unicode superscript and subscript digits, in order.
private let pdfSuperscriptDigits = Array("⁰¹²³⁴⁵⁶⁷⁸⁹")
private let pdfSubscriptDigits = Array("₀₁₂₃₄₅₆₇₈₉")

/// Rewrite digits as their raised or lowered forms.
func pdfMapScriptDigits(_ text: String, raised: Bool) -> String {
    String(
        text.map { character in
            guard let digit = character.wholeNumberValue, (0...9).contains(digit) else {
                return character
            }
            return raised ? pdfSuperscriptDigits[digit] : pdfSubscriptDigits[digit]
        })
}

/// Absorb numeric superscripts and subscripts into the word beside them.
///
/// `H₂O` reaches this point as `H`, `2`, `O` — three fragments, the middle one
/// smaller and offset — and downstream line grouping and table detection want
/// the whole token. Only digits are absorbed: letters would swallow small
/// bullets and ordinal indicators.
func pdfMergeSubscriptItems(_ items: [PdfLayoutItem]) -> [PdfLayoutItem] {
    guard items.count >= 2 else { return items }

    var groups: [(y: Float, items: [PdfLayoutItem])] = []
    for item in items {
        if let index = groups.firstIndex(where: { abs(item.y - $0.y) < pdfMergeLineTolerance }) {
            groups[index].items.append(item)
        } else {
            groups.append((item.y, [item]))
        }
    }

    var result: [PdfLayoutItem] = []
    for group in groups {
        let line = group.items.sorted { $0.x < $1.x }
        let largest = line.map(\.fontSize).max() ?? 0
        guard largest >= 1 else {
            result += line
            continue
        }
        // Anything under three quarters of the line's largest size is a
        // candidate script.
        let threshold = largest * 0.75

        var merged: [PdfLayoutItem] = []
        for item in line {
            let isCandidate =
                item.fontSize < threshold && item.fontSize > 0 && item.text.utf8.count <= 4
                && !item.text.isEmpty
                && item.text.unicodeScalars.allSatisfy(pdfIsAsciiDigitScalar)
            if isCandidate, var parent = merged.last {
                // The parent must be normal-sized, not itself a script, and
                // end in a letter — which keeps `33` + `1` in `33 1/3%` apart
                // while joining `NH` + `3` and `word` + `2`.
                let endsWithLetter =
                    parent.text.unicodeScalars.last?.properties.isAlphabetic == true
                // A strikeout boundary blocks the merge either way. An
                // underlined parent with an unmarked digit still merges: the
                // drawn rule easily misses the tiny digit's overlap window,
                // and refusing would cost the whole token.
                let marksOk =
                    parent.isStrikeout == item.isStrikeout
                    && (parent.isUnderline == item.isUnderline
                        || (parent.isUnderline && !item.isUnderline))
                if parent.fontSize >= threshold, endsWithLetter, marksOk {
                    let gap = item.x - (parent.x + parent.width)
                    // A script hugs what it belongs to.
                    if gap < parent.fontSize * 0.2, gap > -parent.fontSize * 0.3 {
                        // Keep the script visible when absorbing it. NFKC
                        // folds these back to plain digits, so downstream
                        // matching is unaffected. Direction comes from the
                        // baseline offset: raised is a footnote reference,
                        // level or lowered is chemistry.
                        let raised = item.y > parent.y + parent.fontSize * 0.1
                        parent.text += pdfMapScriptDigits(item.text, raised: raised)
                        parent.width = (item.x + item.width) - parent.x
                        merged[merged.count - 1] = parent
                        continue
                    }
                }
            }
            merged.append(item)
        }
        result += merged
    }
    return result
}

// MARK: - overlaid stream order

/// Whether a group's items should keep the order the content stream drew
/// them in, rather than being sorted left to right — ported from
/// `should_preserve_overlapping_stream_order` in `extractor/mod.rs`.
///
/// **Some producers draw a line twice.** A short fragment goes down, and then
/// a longer one is drawn *starting to its left* and overlapping it, carrying
/// the real text; the first is a rendering artefact of how the tagged content
/// was built. Sorting such a line by x interleaves the two — `the quick brown
/// fox Th jumps over` — where the stream order reads `Ththe quick brown fox
/// jumps over`. `overlay-backtrack.pdf` is that document, and its twin
/// without marked content is the control.
///
/// **The gates are many because a wrong answer here reorders ordinary text.**
/// Three items or more; at least one carrying an MCID, since this only
/// happens in tagged content; two non-empty; every size within a quarter of
/// the first, so a footnote marker cannot drag a line in; not mostly
/// mathematical symbols, which overlap legitimately; and an x-cluster that is
/// contiguous and not absurdly wide.
///
/// Only then is a backtrack looked for, and it must be *explained*: a short
/// alphabetic fragment nearby, the overlay starting lowercase, and a space or
/// hyphen inside its first 24 characters — or a bullet close enough to the
/// left with a short fragment between. Anything less is a line that merely
/// happens to overlap.
func pdfShouldPreserveOverlappingStreamOrder(_ group: [PdfLayoutItem]) -> Bool {
    guard group.count >= 3 else { return false }
    guard let first = group.first(where: { !$0.text.rustTrim().isEmpty }) else { return false }
    guard group.contains(where: { $0.mcid != nil }) else { return false }

    var nonEmpty = 0
    var nonSpaceCharacters = 0
    var mathSymbolCharacters = 0
    var maxFontSize = first.fontSize

    for item in group {
        if !item.text.rustTrim().isEmpty { nonEmpty += 1 }
        // A size that differs by more than a quarter means this is not one
        // overlaid line.
        if abs(item.fontSize - first.fontSize) > first.fontSize * 0.25 { return false }
        maxFontSize = max(maxFontSize, item.fontSize)
        for scalar in item.text.unicodeScalars where !scalar.isRustWhitespace {
            nonSpaceCharacters += 1
            switch scalar {
            case "*", "\u{02C6}", "^", "=", "+", "_", "[", "]", "{", "}", "|", "<", ">":
                mathSymbolCharacters += 1
            default: break
            }
        }
    }

    guard nonEmpty >= 2 else { return false }
    // Mathematics overlaps on purpose and must not be reordered by this.
    if nonSpaceCharacters > 0 && mathSymbolCharacters * 4 > nonSpaceCharacters { return false }

    let byX = group.sorted { $0.x < $1.x }
    let clusterStart = byX[0].x
    var clusterEnd = clusterStart + pdfEffectiveMergeWidth(byX[0])
    for item in byX.dropFirst() {
        if item.x - clusterEnd > maxFontSize * 2.5 { return false }
        clusterEnd = max(clusterEnd, item.x + pdfEffectiveMergeWidth(item))
    }
    if clusterEnd - clusterStart > maxFontSize * 36 { return false }

    for index in 0..<(group.count - 1) {
        let previous = group[index]
        let next = group[index + 1]
        let fontSize = max(previous.fontSize, next.fontSize)
        let backtrack = fontSize * 0.25
        let nextStart = next.x
        let nextEnd = next.x + pdfEffectiveMergeWidth(next)
        guard nextStart < previous.x - backtrack, nextEnd > previous.x + backtrack else {
            continue
        }

        let hasNearPrefix = group[...index].reversed().prefix(4).contains {
            pdfIsShortAlphaFragment($0.text)
                && $0.x >= nextStart - fontSize * 0.5
                && $0.x <= nextStart + fontSize * 4
        }
        let startsLowercase = pdfFirstTextScalar(next.text)
            .map { Character($0).isLowercase } ?? false
        let phraseContinuation = pdfHasPhraseContinuationShape(next.text)

        var hasNearBullet = false
        if let bulletIndex = group[...index].firstIndex(where: {
            pdfIsStandaloneBullet($0.text) && nextStart <= $0.x + fontSize * 3
        }), bulletIndex < index {
            hasNearBullet =
                group[(bulletIndex + 1)...index]
                .reversed()
                .first { !$0.text.rustTrim().isEmpty }
                .map {
                    $0.text.rustTrim().unicodeScalars.count <= 8
                        && pdfHasPhraseContinuationShape(next.text)
                } ?? false
        }

        if (hasNearPrefix && startsLowercase && phraseContinuation) || hasNearBullet {
            return true
        }
    }
    return false
}

/// One to four letters and nothing else — the shape of a fragment a producer
/// draws before overlaying the word it belongs to.
func pdfIsShortAlphaFragment(_ text: String) -> Bool {
    let trimmed = text.rustTrim()
    let count = trimmed.unicodeScalars.count
    return (1...4).contains(count)
        && trimmed.unicodeScalars.allSatisfy { Character($0).isLetter }
}

/// The first non-space character, or nil.
func pdfFirstTextScalar(_ text: String) -> Unicode.Scalar? {
    text.rustTrimStart().unicodeScalars.first
}

/// Whether a fragment looks like the continuation of a phrase rather than a
/// word on its own: a space or hyphen inside its first 24 characters.
func pdfHasPhraseContinuationShape(_ text: String) -> Bool {
    text.rustTrimStart().unicodeScalars.prefix(24).contains {
        $0.isRustWhitespace || $0 == "-"
    }
}
