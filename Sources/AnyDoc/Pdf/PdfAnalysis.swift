/// The document-wide state the writer reads, ported from the opening of
/// `to_markdown_from_lines_with_tables_and_images` in `markdown/convert.rs`.
///
/// The reference computes this inline at the top of a six-hundred-line
/// function before writing a single character. Lifting it into a value of
/// its own is the same structural move `PdfGroupLines.swift` made with the
/// per-page loop: same calls, same order, same results, with the state named
/// rather than held in locals.
///
/// **The order matters and is not obvious.** Font statistics are measured on
/// the lines as they arrive; drop caps merge; the heading tiers are
/// discovered from *those* lines; the heading merge uses the tiers; the
/// paragraph threshold is measured after that merge; the bold merge uses the
/// threshold; and everything index-based is computed last, against the final
/// line array. Any set of line indices computed earlier would be stale —
/// which is why all three of them are computed here rather than by callers.

/// Everything the writer needs to know about a document before it starts.
struct PdfDocumentAnalysis {
    /// The lines after all three merges. **Indices into this array**, not
    /// into the caller's input.
    var lines: [PdfTextLine]
    var baseSize: Float
    /// Measured on the lines as they arrived, before any merge — which is
    /// what the writer's rarity score is scaled against.
    var fontStats: PdfFontStats
    var headingTiers: [Float]
    var paragraphThreshold: Float
    /// Short lines with a paragraph break on both sides — heading candidates
    /// whatever their size.
    var isolatedLines: Set<Int>
    /// Bold runs too long to be headings.
    var wrappedBoldParagraphLines: Set<Int>
    /// The wrapped-bold lines, plus chart text, plus anything a tag marks as
    /// non-heading content.
    var sequenceExcludedLines: Set<Int>
    /// Line index to heading level, from the sequence classifier.
    var sequenceHeadingLevels: [Int: Int]
    /// Heading levels a tagger used so freely they mean nothing.
    var overusedHeadingLevels: Set<Int>
}

/// Measure a document and repair its lines.
///
/// - Parameter mergeWrappedBoldHeadings: the reference gates the bold merge
///   on a `PI_NO_MERGE` environment variable. Reading the environment from
///   inside a library is not something this port does, so the escape hatch
///   is a parameter instead — the default matches the reference's behaviour
///   when the variable is unset.
func pdfAnalyseDocument(
    _ lines: [PdfTextLine],
    options: PdfMarkdownOptions = PdfMarkdownOptions(),
    pageChartRegions: [Int: [PdfImageRegion]] = [:],
    structRoles: PdfStructRoleMap? = nil,
    mergeWrappedBoldHeadings: Bool = true
) -> PdfDocumentAnalysis {
    // Measured before any merge, so a drop cap's outsized glyph is still in
    // the sample. It carries one line's worth of weight, which is why it
    // cannot move the most common size.
    let fontStats = pdfFontStats(lines)
    let baseSize = options.baseFontSize ?? fontStats.mostCommonSize

    var working = pdfMergeDropCaps(lines, baseSize: baseSize)
    // Tiers come from the post-drop-cap lines: leaving the cap in would
    // offer a 30pt tier that exactly one line reaches.
    let headingTiers = pdfHeadingTiers(working, bodySize: baseSize)
    working = pdfMergeHeadingLines(
        working, baseSize: baseSize, tiers: headingTiers, structRoles: structRoles)

    // After the heading merge, because merging two lines into one removes a
    // gap that would otherwise be sampled as line spacing.
    let paragraphThreshold = pdfParagraphThreshold(working, bodySize: baseSize)
    if mergeWrappedBoldHeadings {
        working = pdfMergeWrappedBoldHeadingGroups(
            working, baseSize: baseSize, paraThreshold: paragraphThreshold)
    }

    // From here the line array is final and indices into it are stable.
    let isolatedLines = pdfFindIsolatedLines(
        working, baseSize: baseSize, paraThreshold: paragraphThreshold)
    let wrappedBoldParagraphLines = pdfFindWrappedBoldParagraphLines(
        working, bodySize: baseSize, paragraphThreshold: paragraphThreshold)

    // A line inside a chart, or one a tag marks as a caption, a list item or
    // a table cell, cannot be a heading and must not support another line's
    // candidacy either.
    var sequenceExcludedLines = wrappedBoldParagraphLines
    for (index, line) in working.enumerated() {
        if let regions = pageChartRegions[line.page],
            line.items.contains(where: { pdfItemIsInChartRegion($0, regions) })
        {
            sequenceExcludedLines.insert(index)
        }
    }
    if let roles = structRoles {
        for (index, line) in working.enumerated() {
            if let role = pdfResolveLineStructRole(line, roles), role.isNonHeadingContent {
                sequenceExcludedLines.insert(index)
            }
        }
    }

    return PdfDocumentAnalysis(
        lines: working,
        baseSize: baseSize,
        fontStats: fontStats,
        headingTiers: headingTiers,
        paragraphThreshold: paragraphThreshold,
        isolatedLines: isolatedLines,
        wrappedBoldParagraphLines: wrappedBoldParagraphLines,
        sequenceExcludedLines: sequenceExcludedLines,
        sequenceHeadingLevels: pdfClassifyHeadingSequences(
            working, bodySize: baseSize, tiers: headingTiers,
            excludedLines: sequenceExcludedLines),
        overusedHeadingLevels: pdfDetectOverusedStructHeadingLevels(working, structRoles))
}
