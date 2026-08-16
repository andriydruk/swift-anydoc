/// The plain line-to-Markdown entry point, ported from
/// `to_markdown_from_lines` in `markdown/convert.rs`.
///
/// This is the reference's public conversion for callers with nothing but
/// text lines — no tables, no images, no structure tree. It is **not** the
/// big writer with arguments defaulted: it is a separate, older
/// implementation that has drifted from its sibling, and the divergences are
/// the substance of this port. Nine of them, listed at the branches where
/// they bite:
///
/// * no bold-run merge, so wrapped bold headings arrive unmerged;
/// * the sequence classifier is given only the wrapped-bold set to exclude —
///   there is no chart or struct-role exclusion to add;
/// * a page break also resets the list state and the dot-leader flag, which
///   the big writer leaves standing — a difference in the code that has not
///   been shown to change any output, since a page break already defeats the
///   continuation test through its baseline gap;
/// * no band-switch break, and no previous-x tracking at all;
/// * the heading gate omits the bullet-marker test, the list-continuation
///   guard and the non-heading-role guard;
/// * the rarity fallback needs no strong signal, but a single-word heading
///   must be isolated as well as bold;
/// * there is no numbered-bold shortcut;
/// * code is fenced per line rather than accumulated into one block;
/// * captions are found by text alone, and tagged list items, quotes and
///   code have no handling.
///
/// Keeping the two apart is deliberate. Sharing an implementation would mean
/// choosing which behaviour is "right", and both are the reference's.
func pdfMarkdownFromLines(
    _ lines: [PdfTextLine], options: PdfMarkdownOptions = PdfMarkdownOptions()
) -> String {
    if lines.isEmpty { return "" }

    let fontStats = pdfFontStats(lines)
    let baseSize = options.baseFontSize ?? fontStats.mostCommonSize

    var working = pdfMergeDropCaps(lines, baseSize: baseSize)
    let headingTiers = pdfHeadingTiers(working, bodySize: baseSize)
    // No struct roles: this entry point has none to offer.
    working = pdfMergeHeadingLines(
        working, baseSize: baseSize, tiers: headingTiers, structRoles: nil)
    let paragraphThreshold = pdfParagraphThreshold(working, bodySize: baseSize)
    // Note what is *missing* here: the big writer merges wrapped bold
    // headings at this point, and this one does not.
    let isolatedLines = pdfFindIsolatedLines(
        working, baseSize: baseSize, paraThreshold: paragraphThreshold)
    let wrappedBoldParagraphLines = pdfFindWrappedBoldParagraphLines(
        working, bodySize: baseSize, paragraphThreshold: paragraphThreshold)
    let sequenceHeadingLevels = pdfClassifyHeadingSequences(
        working, bodySize: baseSize, tiers: headingTiers,
        excludedLines: wrappedBoldParagraphLines)

    var output = ""
    var currentPage = 0
    var previousY = Float.greatestFiniteMagnitude
    var inList = false
    var inParagraph = false
    var lastListX: Float?
    var previousHadDotLeaders = false
    var paragraphInWrappedBoldRun = false
    var tocSuppressPage: Int?

    func endParagraph() {
        if inParagraph {
            output += "\n\n"
            inParagraph = false
            paragraphInWrappedBoldRun = false
        }
    }

    for (lineIndex, line) in working.enumerated() {
        if line.page != currentPage {
            if currentPage > 0 {
                if inParagraph {
                    output += "\n\n"
                    inParagraph = false
                }
                output += "\n\n"
            }
            currentPage = line.page
            previousY = .greatestFiniteMagnitude
            // The big writer keeps a list open across a page break; this one
            // closes it, along with the dot-leader flag.
            inList = false
            lastListX = nil
            previousHadDotLeaders = false
            paragraphInWrappedBoldRun = false

            if options.includePageNumbers { output += "<!-- Page \(currentPage) -->\n\n" }
        }

        let yGap = previousY - line.y
        let isParagraphBreak = abs(yGap) > paragraphThreshold
        let lineAllBold = !line.items.isEmpty && line.items.allSatisfy(\.isBold)
        let lineInWrappedBoldRun = wrappedBoldParagraphLines.contains(lineIndex)
        let isBoldToRegularBreak =
            inParagraph && paragraphInWrappedBoldRun && !lineInWrappedBoldRun && !lineAllBold
            && yGap > baseSize * 1.2 && yGap <= paragraphThreshold
        if (isParagraphBreak || isBoldToRegularBreak) && inParagraph {
            output += "\n\n"
            inParagraph = false
            paragraphInWrappedBoldRun = false
        }
        previousY = line.y

        let text = pdfLineTextWithEmphasis(
            line, formatBold: options.detectBold, formatItalic: options.detectItalic,
            formatUnderline: options.detectUnderline)
        let trimmed = text.rustTrim()
        let plainText = pdfLineText(line)
        let plainTrimmed = plainText.rustTrim()
        if trimmed.isEmpty { continue }

        if pdfIsCaptionLine(plainTrimmed) {
            endParagraph()
            output += trimmed + "\n\n"
            continue
        }

        // The heading gate. Monospace is excluded inline here rather than
        // through a shared code-line flag, and neither bullet markers nor
        // list continuations are tested at all.
        if options.detectHeaders && plainTrimmed.utf8.count > 3
            && plainTrimmed.rustSplitWhitespace().count <= 15
            && !pdfIsTocEntryLine(plainTrimmed) && !pdfIsHeadingFragment(plainTrimmed)
            && tocSuppressPage != line.page
            && !(options.detectCode && line.items.contains { pdfIsMonospaceFont($0.fontName) })
        {
            let lineFontSize = line.items.first?.fontSize ?? baseSize
            var level = pdfHeadingLevel(
                fontSize: lineFontSize, bodySize: baseSize, tiers: headingTiers,
                isBold: pdfLineIsMostlyBold(line))
            if level == nil {
                level = rarityLevel(
                    line: line, lineIndex: lineIndex, lineFontSize: lineFontSize,
                    plainTrimmed: plainTrimmed, standalone: !inParagraph)
            }
            if level == nil { level = sequenceHeadingLevels[lineIndex] }

            if let level {
                endParagraph()
                let headingText =
                    options.detectUnderline
                    ? pdfLineTextWithEmphasis(
                        line, formatBold: false, formatItalic: false, formatUnderline: true)
                    : plainText
                output += String(repeating: "#", count: level) + " "
                    + headingText.rustTrim() + "\n\n"
                if pdfIsTocMarkerHeading(plainTrimmed) { tocSuppressPage = line.page }
                inList = false
                continue
            }
        }

        if options.detectLists && pdfIsListItem(plainTrimmed) {
            endParagraph()
            output += pdfFormatListItem(trimmed) + "\n"
            inList = true
            lastListX = line.items.first?.x
            continue
        } else if inList {
            var isContinuation = false
            if let listX = lastListX, let currentX = line.items.first?.x {
                isContinuation =
                    currentX >= listX - 5 && currentX <= listX + 50 && yGap < baseSize * 7
                    && !pdfIsListItem(plainTrimmed) && !pdfHasDotLeaders(plainTrimmed)
            }
            if isContinuation {
                if output.hasSuffix("\n") {
                    output.removeLast()
                    output += " "
                }
                output += trimmed + "\n"
                continue
            }
            inList = false
            lastListX = nil
        }

        // Fenced per line, not accumulated — two consecutive monospace lines
        // become two blocks here and one in the big writer.
        if options.detectCode, line.items.contains(where: { pdfIsMonospaceFont($0.fontName) }) {
            endParagraph()
            output += "```\n" + plainTrimmed + "\n```\n"
            continue
        }

        let currentDotLeaders = pdfHasDotLeaders(plainTrimmed)
        if inParagraph {
            output += (currentDotLeaders || previousHadDotLeaders) ? "\n" : " "
        }
        output += trimmed
        paragraphInWrappedBoldRun =
            inParagraph ? (paragraphInWrappedBoldRun || lineInWrappedBoldRun) : lineInWrappedBoldRun
        inParagraph = true
        previousHadDotLeaders = currentDotLeaders
    }

    if inParagraph { output += "\n" }

    var cleanup = PdfCleanupOptions()
    cleanup.collapseDotLeaders = options.profile == .compact
    cleanup.fixHyphenation = options.fixHyphenation
    cleanup.removePageNumbers = options.removePageNumbers
    cleanup.formatUrls = options.formatUrls
    return pdfCleanMarkdown(output, options: cleanup)

    /// The rarity fallback, in this entry point's shape.
    ///
    /// Two differences from the big writer's: there is no strong-signal
    /// requirement on top of the score, and a single-word heading must be
    /// **isolated as well as bold** rather than merely bold. Nor is there a
    /// numbered-bold shortcut.
    func rarityLevel(
        line: PdfTextLine, lineIndex: Int, lineFontSize: Float, plainTrimmed: String,
        standalone: Bool
    ) -> Int? {
        if lineFontSize < baseSize * 0.95 { return nil }
        let wordCount = plainTrimmed.rustSplitWhitespace().count
        if !(1...15).contains(wordCount) { return nil }
        if wrappedBoldParagraphLines.contains(lineIndex) { return nil }

        let rarity = pdfFontSizeRarity(lineFontSize, fontStats)
        let allBold = !line.items.isEmpty && line.items.allSatisfy(\.isBold)
        let isolated = isolatedLines.contains(lineIndex)
        let score =
            rarity * 0.5 + (allBold ? 0.3 : 0) + (standalone ? 0.2 : 0) + (isolated ? 0.3 : 0)
        let enoughWords =
            wordCount >= 2 || (allBold && isolated && plainTrimmed.utf8.count >= 4)
        if score >= 0.5 && standalone && enoughWords { return pdfBoldHeadingLevel(headingTiers) }
        return nil
    }
}
