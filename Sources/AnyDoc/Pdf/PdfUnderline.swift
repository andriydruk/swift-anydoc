/// Geometric underline and strikeout detection, ported from
/// pdf-inspector's `extractor/underline.rs`.
///
/// PDF has no underline flag. An underline is a separate graphic — a stroked
/// horizontal line or a thin filled rectangle — drawn near a baseline, and
/// recovering it means correlating the page's paths with its text after both
/// have been extracted.
///
/// Most of this file is not the correlation, which is simple, but the
/// business of telling an underline from a table ruling. Both are horizontal
/// rules near text. The reference distinguishes them with five overlapping
/// heuristics, every one of which exists because some real document broke the
/// previous four; they are ported as written, comments and all, because the
/// thresholds are empirical and there is nothing to derive them from.

/// A stroked line or thin rectangle is a rule rather than a border or a
/// decorative band only below this thickness.
private let pdfMaxRuleThickness: Float = 2.0

/// A rule must cover this fraction of an item's width to decorate it.
private let pdfMinXOverlap: Float = 0.6

/// Same-span rules at this many distinct heights are table or form rulings.
private let pdfMinRepeatedRuleLevels = 3

/// Two rules within this distance are on the same row edge.
private let pdfRuleYDedupEpsilon: Float = 2.0

/// How alike two spans must be to cluster as repeated rulings.
private let pdfRuleSpanOverlapRatio: Float = 0.8
private let pdfRuleSpanWidthRatio: Float = 1.5

/// Several separated rule segments on one row are per-column separators.
private let pdfMinSegmentedRowRules = 3
private let pdfMinSegmentedRowGaps = 2
private let pdfSegmentedRowGapMinimum: Float = 12.0

/// One rule under several widely separated items is a header separator.
private let pdfMinTabularRuleItems = 3
private let pdfMinTabularRuleGaps = 2
private let pdfTabularRuleGapEm: Float = 2.0

/// A horizontal rule candidate, in page coordinates with y increasing up.
struct PdfRule: Equatable {
    var x1: Float
    var x2: Float
    var y: Float

    var width: Float { x2 - x1 }
}

/// The rules a page's graphics offer as underline candidates.
///
/// Extents are normalised first: `re` operands pass through the transform, so
/// width and height can come out negative under a flipped axis. Without
/// normalising, negative-width rules are missed and negative-height bands
/// slip past the thickness test.
func pdfRulesFromGraphics(_ rectangles: [PdfRect], _ lines: [PdfLineSegment]) -> [PdfRule] {
    var rules: [PdfRule] = []
    for line in lines {
        // Horizontal, tolerating slight skew.
        guard line.strokeWidth <= pdfMaxRuleThickness,
            abs(line.y1 - line.y2) <= pdfMaxRuleThickness
        else { continue }
        let x1 = min(line.x1, line.x2)
        let x2 = max(line.x1, line.x2)
        if x2 - x1 > 1 { rules.append(PdfRule(x1: x1, x2: x2, y: (line.y1 + line.y2) / 2)) }
    }
    for rectangle in rectangles {
        let x1 = rectangle.width >= 0 ? rectangle.x : rectangle.x + rectangle.width
        let x2 = rectangle.width >= 0 ? rectangle.x + rectangle.width : rectangle.x
        guard abs(rectangle.height) <= pdfMaxRuleThickness, x2 - x1 > 1 else { continue }
        rules.append(PdfRule(x1: x1, x2: x2, y: rectangle.y + rectangle.height / 2))
    }
    return rules
}

/// Whether an item is the kind of text a rule can decorate.
private func pdfIsUnderlineCandidate(_ item: PdfLayoutItem) -> Bool {
    !item.text.rustTrim().isEmpty && item.width > 0
}

/// Whether a rule sits in the band just below an item's baseline and covers
/// enough of its width.
///
/// Latin fonts draw underlines five to fifteen percent of the em below the
/// baseline; CJK layouts put them under the full em box, as much as two
/// thirds down. The window allows 0.72em below and a point above for
/// rounding.
func pdfRuleMatchesItem(_ rule: PdfRule, _ item: PdfLayoutItem) -> Bool {
    let below = max(item.fontSize * 0.72, 3)
    guard rule.y >= item.y - below, rule.y <= item.y + 1 else { return false }
    let overlap = min(rule.x2, item.x + item.width) - max(rule.x1, item.x)
    return overlap >= item.width * pdfMinXOverlap
}

/// Whether a rule crosses an item's glyphs.
///
/// Strikethroughs sit twenty to thirty-five percent of the em above the
/// baseline, about half the x-height. The band is kept well inside the glyph
/// body so a baseline underline or an overline never qualifies.
func pdfRuleStrikesItem(_ rule: PdfRule, _ item: PdfLayoutItem) -> Bool {
    guard rule.y >= item.y + item.fontSize * 0.12, rule.y <= item.y + item.fontSize * 0.55
    else { return false }
    let overlap = min(rule.x2, item.x + item.width) - max(rule.x1, item.x)
    return overlap >= item.width * pdfMinXOverlap
}

/// Whether two rules span nearly the same horizontal range.
private func pdfHasSimilarSpan(_ a: PdfRule, _ b: PdfRule) -> Bool {
    guard a.width > 1, b.width > 1 else { return false }
    let widthRatio = max(a.width, b.width) / min(a.width, b.width)
    guard widthRatio <= pdfRuleSpanWidthRatio else { return false }
    let overlap = min(a.x2, b.x2) - max(a.x1, b.x1)
    return overlap >= min(a.width, b.width) * pdfRuleSpanOverlapRatio
}

/// Whether same-span rules repeat down the page, which is what a ruled table
/// or form looks like.
private func pdfIsRepeatedRulingRule(_ rule: PdfRule, _ rules: [PdfRule]) -> Bool {
    var levels = rules.filter { pdfHasSimilarSpan(rule, $0) }.map(\.y).sorted()
    // `dedup_by` drops each element within tolerance of the last *kept* one.
    var distinct: [Float] = []
    for level in levels where !(distinct.last.map { abs(level - $0) <= pdfRuleYDedupEpsilon } ?? false) {
        distinct.append(level)
    }
    levels = distinct
    return levels.count >= pdfMinRepeatedRuleLevels
}

/// Whether a rule is one of several separated segments on the same row,
/// which is how per-column header separators are drawn.
private func pdfIsSegmentedRowRulingRule(_ rule: PdfRule, _ rules: [PdfRule]) -> Bool {
    let row = rules.filter { abs($0.y - rule.y) <= pdfRuleYDedupEpsilon }
        .sorted { $0.x1 < $1.x1 }
    guard row.count >= pdfMinSegmentedRowRules else { return false }
    let largeGaps = zip(row, row.dropFirst()).count {
        $1.x1 - $0.x2 > pdfSegmentedRowGapMinimum
    }
    return largeGaps >= pdfMinSegmentedRowGaps
}

/// Whether one text line both sits on the rule's baseline and contains it.
///
/// Underlines are drawn to the width of the text they decorate, but that text
/// may be several runs — a CJK line mixes scripts and switches fonts — so
/// ownership is judged against the union of the runs on the rule's row. Table
/// rulings overshoot their row's text, spanning cell padding and empty
/// columns, so they fail either containment or coverage.
private func pdfHasSnugTextOwner(_ rule: PdfRule, _ items: [PdfLayoutItem]) -> Bool {
    let matched = items.filter { pdfIsUnderlineCandidate($0) && pdfRuleMatchesItem(rule, $0) }
    guard !matched.isEmpty else { return false }

    let x1 = matched.map(\.x).min() ?? 0
    let x2 = matched.map { $0.x + $0.width }.max() ?? 0
    let maxFontSize = matched.map(\.fontSize).max() ?? 0
    let pad = max(maxFontSize * 0.75, 4)
    guard rule.x1 >= x1 - pad, rule.x2 <= x2 + pad else { return false }

    let covered = matched.map(\.width).reduce(0, +)
    guard covered >= rule.width * 0.6 else { return false }

    // A table row also unions to the rule's span, but its cells sit apart.
    // An underlined line is contiguous runs with word-sized gaps, so any
    // column-sized hole means this is a row ruling.
    let sorted = matched.sorted { $0.x < $1.x }
    return zip(sorted, sorted.dropFirst()).allSatisfy { left, right in
        right.x - (left.x + left.width) <= max(maxFontSize * 2, 12)
    }
}

/// Whether vertical strokes rise from a rule's ends, or a grid box contains
/// it — either way a table or box border rather than an underline.
private func pdfHasFlankingVerticals(
    _ rule: PdfRule, _ rectangles: [PdfRect], _ lines: [PdfLineSegment]
) -> Bool {
    // A drawn box containing the rule only vetoes it with *grid evidence*: a
    // second box abutting it vertically, the way cell rows tile. Height alone
    // cannot separate a table cell from a decorative callout panel, and
    // genuine underlines do live inside isolated filled panels.
    func normalised(_ r: PdfRect) -> (Float, Float, Float, Float) {
        (
            min(r.x, r.x + r.width), max(r.x, r.x + r.width),
            min(r.y, r.y + r.height), max(r.y, r.y + r.height)
        )
    }
    let boxes = rectangles.filter { abs($0.height) > 6 }.map(normalised)
    let boxFlank = boxes.contains { box in
        let (xLow, xHigh, yLow, yHigh) = box
        let contains =
            xLow <= rule.x1 + 2 && xHigh >= rule.x2 - 2 && yLow <= rule.y + 2
            && yHigh >= rule.y - 2
        guard contains else { return false }
        return boxes.contains { neighbour in
            let (nxLow, nxHigh, nyLow, nyHigh) = neighbour
            let overlap = min(nxHigh, xHigh) - max(nxLow, xLow)
            guard overlap > 10 else { return false }
            return abs(nyLow - yHigh) <= 3 || abs(yLow - nyHigh) <= 3
        }
    }
    if boxFlank { return true }

    return lines.contains { line in
        guard abs(line.x1 - line.x2) <= 2 else { return false }
        let x = (line.x1 + line.x2) / 2
        guard abs(x - rule.x1) <= 6 || abs(x - rule.x2) <= 6 else { return false }
        let yLow = min(line.y1, line.y2)
        let yHigh = max(line.y1, line.y2)
        return yLow <= rule.y + 2 && yHigh >= rule.y - 2
    }
}

/// Drop the rules that are table or form rulings rather than underlines.
private func pdfDiscardRepeatedRulingRules(
    _ rules: [PdfRule], _ items: [PdfLayoutItem], _ rectangles: [PdfRect],
    _ lines: [PdfLineSegment]
) -> [PdfRule] {
    guard rules.count >= pdfMinRepeatedRuleLevels else { return rules }
    return rules.filter { rule in
        // A rule snugly owned by one line is an underline even where
        // span-similar rules repeat: a document that underlines many
        // full-width lines looks exactly like a ruled table to the repetition
        // test, which used to discard every one of them. Rulings fail
        // snugness — a row separator extends past its cells' text, or has no
        // text on the baseline above it — and multi-column survivors are
        // culled by the tabular filter afterwards. Same-row segmented rules
        // are always rulings, since each segment snugly owns its column
        // label, so snugness must not override that test.
        !pdfIsSegmentedRowRulingRule(rule, rules)
            && ((pdfHasSnugTextOwner(rule, items)
                && !pdfHasFlankingVerticals(rule, rectangles, lines))
                || !pdfIsRepeatedRulingRule(rule, rules))
    }
}

/// The rules that read as a table's header/body separator: one rule under
/// several items with column-sized gaps between them.
private func pdfTabularRuleIndices(_ rules: [PdfRule], _ items: [PdfLayoutItem]) -> Set<Int> {
    var tabular: Set<Int> = []
    for (index, rule) in rules.enumerated() {
        let matched = items
            .filter { pdfIsUnderlineCandidate($0) && pdfRuleMatchesItem(rule, $0) }
            .sorted { $0.x < $1.x }
        guard matched.count >= pdfMinTabularRuleItems else { continue }
        let largeGaps = zip(matched, matched.dropFirst()).count { left, right in
            let gap = right.x - (left.x + left.width)
            return gap > max(left.fontSize, right.fontSize, 1) * pdfTabularRuleGapEm
        }
        if largeGaps >= pdfMinTabularRuleGaps { tabular.insert(index) }
    }
    return tabular
}

/// The rules that are maths fraction bars.
///
/// A fraction bar has underline geometry seen from above, but no underline
/// has text hanging directly beneath it at fraction distance. Only narrow
/// rules qualify: a real underline under a short label has its next line a
/// full line-pitch away.
private func pdfFractionRuleIndices(_ rules: [PdfRule], _ items: [PdfLayoutItem]) -> Set<Int> {
    var fractions: Set<Int> = []
    for (index, rule) in rules.enumerated() where rule.width <= 60 {
        let hasDenominator = items.contains { item in
            guard pdfIsUnderlineCandidate(item) else { return false }
            // A denominator hugs the bar — fraction typesetting leaves a
            // tenth to a fifth of an em — and is bar-sized. Both bounds
            // matter: a short last line of a paragraph at normal leading sits
            // further below, and a full next line is far wider than the rule.
            // An item's height is its font size, as the reference sets it.
            let dy = rule.y - (item.y + item.fontSize)
            let overlap = min(rule.x2, item.x + item.width) - max(rule.x1, item.x)
            return dy > 0 && dy <= item.fontSize * 0.3 && overlap > rule.width * 0.5
                && item.width <= rule.width * 1.5
        }
        if hasDenominator { fractions.insert(index) }
    }
    return fractions
}

/// Mark the items a rule underlines or strikes through.
///
/// `rectangles` must be the ink the page actually laid down — the `re`
/// rectangles a painting operator confirmed plus the filled subpaths — never
/// clip-only rectangles, which draw nothing.
func pdfMarkUnderlines(
    _ items: inout [PdfLayoutItem], rectangles: [PdfRect], lines: [PdfLineSegment]
) {
    let rules = pdfDiscardRepeatedRulingRules(
        pdfRulesFromGraphics(rectangles, lines), items, rectangles, lines)
    guard !rules.isEmpty else { return }

    let tabular = pdfTabularRuleIndices(rules, items)
    let fractions = pdfFractionRuleIndices(rules, items)

    for index in items.indices {
        guard pdfIsUnderlineCandidate(items[index]) else { continue }
        for (ruleIndex, rule) in rules.enumerated() where !tabular.contains(ruleIndex) {
            // The fraction guard gates underlining only: a rule that reads as
            // a fraction bar from below can still strike through the line
            // above it.
            if !fractions.contains(ruleIndex), pdfRuleMatchesItem(rule, items[index]) {
                items[index].isUnderline = true
            }
            if pdfRuleStrikesItem(rule, items[index]) {
                items[index].isStrikeout = true
            }
            if items[index].isUnderline, items[index].isStrikeout { break }
        }
    }
}

/// The ink a page laid down, which is what underline detection reads.
func pdfUnderlineInk(_ graphics: PdfPageGraphics) -> [PdfRect] {
    graphics.paintedRectangles + graphics.filledRectangles
}
