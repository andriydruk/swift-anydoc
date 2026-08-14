/// Font statistics, ported from `markdown/analysis.rs`: `FontStats`,
/// `calculate_font_stats`, `calculate_font_stats_from_items`,
/// `font_size_rarity` and `bold_heading_level`.
///
/// Everything the heading detector decides rests on knowing which size is the
/// *body*. That is not the largest or the mean but the most common — and
/// which "most common" is measured matters: one vote per line rather than
/// per run, so a page of short captions cannot outvote its body text, and
/// nothing under nine points votes at all, since footnotes and superscripts
/// would otherwise claim the majority on a densely annotated page.

/// A document's font-size distribution.
struct PdfFontStats {
    /// The body size: the most common size, ties going to the smaller.
    var mostCommonSize: Float = 12
    /// How many votes each size received, keyed by tenths of a point.
    var sizeCounts: [Int: Int] = [:]
    /// The total number of votes cast.
    var totalLines = 0
}

/// The size key: tenths of a point, **truncated**.
///
/// Rust's float-to-integer cast truncates toward zero rather than rounding,
/// so 12.19 and 12.11 are both key 121 while 12.2 is 122. Rounding here would
/// bucket differently and change which size wins on a document whose sizes
/// sit near a tenth boundary.
private func pdfFontSizeKey(_ size: Float) -> Int {
    Int(size * 10)
}

/// The most common key, ties going to the smaller size.
private func pdfMostCommonSize(_ counts: [Int: Int]) -> Float {
    // The reference's `max_by` compares count first, then prefers the
    // *smaller* key. Keys are unique so the comparator is a total order and
    // the hash order cannot affect the answer.
    var bestKey: Int?
    var bestCount = -1
    for (key, count) in counts {
        if count > bestCount || (count == bestCount && key < (bestKey ?? Int.max)) {
            bestKey = key
            bestCount = count
        }
    }
    guard let bestKey else { return 12 }
    return Float(bestKey) / 10
}

/// Statistics from grouped lines: one vote per line, cast by its first item.
///
/// Giving each line equal weight is what stops small captions and footnotes
/// skewing the body size on a page that carries a lot of them.
func pdfFontStats(_ lines: [PdfTextLine]) -> PdfFontStats {
    var counts: [Int: Int] = [:]
    for line in lines {
        guard let first = line.items.first else { continue }
        // Nothing under nine points votes: footnotes and superscripts would
        // otherwise claim the majority on a densely annotated page.
        if first.fontSize >= 9 { counts[pdfFontSizeKey(first.fontSize), default: 0] += 1 }
    }
    return PdfFontStats(
        mostCommonSize: pdfMostCommonSize(counts), sizeCounts: counts,
        totalLines: counts.values.reduce(0, +))
}

/// Statistics from items, before they have been grouped into lines.
///
/// Every item votes here, since there are no lines yet to weight by.
func pdfFontStatsFromItems(_ items: [PdfLayoutItem]) -> PdfFontStats {
    var counts: [Int: Int] = [:]
    for item in items where item.fontSize >= 9 {
        counts[pdfFontSizeKey(item.fontSize), default: 0] += 1
    }
    return PdfFontStats(
        mostCommonSize: pdfMostCommonSize(counts), sizeCounts: counts,
        totalLines: counts.values.reduce(0, +))
}

/// How rare a size is in the document: 0 for the most common, approaching 1
/// for a size used once.
///
/// Heading fonts appear on far fewer lines than body text, so a high rarity
/// is evidence of a heading independent of how much larger the size is.
func pdfFontSizeRarity(_ fontSize: Float, _ stats: PdfFontStats) -> Float {
    if stats.totalLines == 0 { return 0 }
    let count = stats.sizeCounts[pdfFontSizeKey(fontSize)] ?? 0
    return 1 - Float(count) / Float(stats.totalLines)
}

/// The level for a bold line that never reached a size tier.
///
/// Common in academic papers, where section headings are bold at exactly
/// body size. The level sits below every size tier — and never above H2,
/// since H1 is reserved for titles, which are larger.
func pdfBoldHeadingLevel(_ tiers: [Float]) -> Int {
    min(max(tiers.count + 1, 2), 6)
}
