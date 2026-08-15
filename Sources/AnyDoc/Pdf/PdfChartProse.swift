/// Prose columns on a chart page, ported from `markdown/mod.rs`:
/// `chart_page_prose_column_split`, `chart_spans_prose_split`,
/// `is_cross_row_prose_continuation`, `looks_like_numbered_section_heading`
/// and `merged_retry_skips_body_font`.
///
/// A page carrying both charts and two columns of prose is the hard case for
/// reading order: the charts fill the gutter, so the projection histogram of
/// wave 65 sees one column. These infer the gutter from the *prose alone*,
/// then ask whether each chart genuinely crosses it — because a chart
/// confined to one column must stay in that column's local order rather than
/// reordering the whole page.

/// Runs whose left edges agree this closely share a column.
private let pdfProseColumnXTolerance: Float = 12
/// A column needs this many prose runs to be believed.
private let pdfMinProseLinesPerColumn = 6
/// And the two columns' left edges must be this far apart.
private let pdfMinProseAnchorSeparation: Float = 120
/// Each column must also run this tall.
private let pdfMinProseVerticalSpan: Float = 60

/// The gutter between two columns of prose, inferred without the histogram.
///
/// Only *substantial* runs vote — four words, 80pt wide, and more than half
/// alphabetic — so axis labels and figures cannot form a column. Two
/// dominant left-edge clusters must emerge, far enough apart, each tall
/// enough, and overlapping vertically: side-by-side columns run alongside
/// each other, where a column and a caption below it do not.
func pdfChartPageProseColumnSplit(_ items: [PdfLayoutItem]) -> Float? {
    let prose = items.filter { item in
        let words = item.text.rustSplitWhitespace().count
        let characters = max(item.text.unicodeScalars.count, 1)
        let alphabetic = item.text.unicodeScalars.filter { $0.properties.isAlphabetic }.count
        return words >= 4 && item.width >= 80 && alphabetic * 2 >= characters
    }
    if prose.count < pdfMinProseLinesPerColumn * 2 { return nil }

    // Ascending by left edge, stably.
    let sorted = prose.enumerated().sorted { left, right in
        if left.element.x != right.element.x { return left.element.x < right.element.x }
        return left.offset < right.offset
    }.map(\.element)

    // Clustered by left edge, the anchor being the running mean of its
    // members — so a column drifting slightly still holds together.
    var anchors: [Float] = []
    var members: [[PdfLayoutItem]] = []
    for item in sorted {
        var placed = false
        for index in anchors.indices where abs(item.x - anchors[index]) <= pdfProseColumnXTolerance
        {
            members[index].append(item)
            anchors[index] =
                members[index].reduce(0) { $0 + $1.x } / Float(members[index].count)
            placed = true
            break
        }
        if !placed {
            anchors.append(item.x)
            members.append([item])
        }
    }

    var dominant: [(anchor: Float, members: [PdfLayoutItem])] = []
    for index in anchors.indices where members[index].count >= pdfMinProseLinesPerColumn {
        dominant.append((anchors[index], members[index]))
    }
    // Exactly two: one column is not a split, and three or more is a table.
    guard dominant.count == 2 else { return nil }
    dominant = dominant.enumerated().sorted { left, right in
        if left.element.anchor != right.element.anchor {
            return left.element.anchor < right.element.anchor
        }
        return left.offset < right.offset
    }.map(\.element)
    if dominant[1].anchor - dominant[0].anchor < pdfMinProseAnchorSeparation { return nil }

    func verticalRange(_ items: [PdfLayoutItem]) -> (low: Float, high: Float) {
        var low = Float.infinity
        var high = -Float.infinity
        for item in items {
            low = min(low, item.y)
            high = max(high, item.y)
        }
        return (low, high)
    }
    let left = verticalRange(dominant[0].members)
    let right = verticalRange(dominant[1].members)
    let leftSpan = left.high - left.low
    let rightSpan = right.high - right.low
    if leftSpan < pdfMinProseVerticalSpan || rightSpan < pdfMinProseVerticalSpan { return nil }

    // Columns run alongside each other; a column and the caption below it do
    // not. Two fifths of the shorter one is the bar.
    let overlap = max(min(left.high, right.high) - max(left.low, right.low), 0)
    if overlap < min(leftSpan, rightSpan) * 0.4 { return nil }

    return (dominant[0].anchor + dominant[1].anchor) / 2
}

/// Whether a chart crosses the prose gutter widely enough to separate the
/// page.
///
/// Forty points each side. A chart confined to one column stays in that
/// column's local reading order instead of reordering everything.
func pdfChartSpansProseSplit(_ region: PdfImageRegion, splitX: Float) -> Bool {
    let minimumPerSide: Float = 40
    let left = min(region.x0, region.x1)
    let right = max(region.x0, region.x1)
    return splitX - left >= minimumPerSide && right - splitX >= minimumPerSide
}

/// Whether two adjacent rows are one sentence broken across them.
///
/// The previous row must end *open* — no sentence-ending punctuation, with
/// any closing quotes or brackets stripped first, since `…said."` is still
/// closed. The current row must begin lowercase.
func pdfIsCrossRowProseContinuation(_ previous: String, _ current: String) -> Bool {
    let previousTrimmed = previous.rustTrim()
    let currentTrimmed = current.rustTrim()
    if previousTrimmed.isEmpty || currentTrimmed.isEmpty { return false }

    let closers: Set<Character> = ["\"", "'", "\u{201D}", ")", "]"]
    var withoutClosers = Substring(previousTrimmed)
    while let last = withoutClosers.last, closers.contains(last) {
        withoutClosers = withoutClosers.dropLast()
    }
    // Nothing but closers leaves no character to judge, and the row is not
    // open.
    guard let lastCharacter = withoutClosers.last else { return false }
    let terminators: Set<Character> = [".", "!", "?", ":", ";"]
    let previousIsOpen = !terminators.contains(lastCharacter)

    let startsLower =
        currentTrimmed.unicodeScalars.first(where: { $0.properties.isAlphabetic })?
        .properties.isLowercase == true

    return previousIsOpen && startsLower
}

/// Whether a line is a numbered section heading.
///
/// Stricter than wave 76's `pdfParseNumbering`: the number must be one to
/// four dotted groups *and* be followed by a title of at least three words
/// beginning with a capital. A heuristic grid that captured such a line has
/// captured page prose rather than a table.
func pdfLooksLikeNumberedSectionHeading(_ text: String) -> Bool {
    let trimmed = text.rustTrim()
    guard let space = trimmed.firstIndex(where: { $0.isWhitespace }) else { return false }
    var prefix = Substring(trimmed[trimmed.startIndex..<space])
    let title = String(trimmed[trimmed.index(after: space)...]).rustTrim()

    while prefix.last == "." { prefix = prefix.dropLast() }
    var groupCount = 0
    for group in prefix.split(separator: ".", omittingEmptySubsequences: false) {
        guard !group.isEmpty, group.utf8.count <= 3,
            group.unicodeScalars.allSatisfy(pdfIsAsciiDigitScalarValue)
        else { return false }
        groupCount += 1
    }

    guard (1...4).contains(groupCount), title.rustSplitWhitespace().count >= 3 else {
        return false
    }
    return title.unicodeScalars.first(where: { $0.properties.isAlphabetic })?
        .properties.isUppercase == true
}

/// Whether a merged-table retry should skip body-font detection.
///
/// Only on a page with columns and no charts — a chart page keeps body-font
/// detection, since its columns are inferred rather than projected.
func pdfMergedRetrySkipsBodyFont(detectedColumns: Bool, hasChartRegions: Bool) -> Bool {
    detectedColumns && !hasChartRegions
}
