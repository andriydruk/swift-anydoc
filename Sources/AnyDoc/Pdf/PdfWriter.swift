/// The writer, ported from the body of
/// `to_markdown_from_lines_with_tables_and_images` in `markdown/convert.rs`,
/// together with `flush_page_tables_and_images`.
///
/// Everything the previous thirty waves built converges here: one pass over
/// the analysed lines, deciding for each what it is — caption, heading, list
/// item, quote, code, or prose — and emitting Markdown accordingly, with
/// tables and images interleaved at the right points.
///
/// The pass carries a dozen pieces of running state, and most of the
/// subtlety is in when each is reset rather than in the classification. A
/// paragraph ends on a large baseline gap, on a column switch, or on the
/// transition out of a bold run; a list survives a paragraph break but not a
/// line that fails the continuation test; a code block spans lines and must
/// be closed on a page break as well as on the first non-code line.

/// The writer's running state, named so the resets can be read.
private struct PdfWriterState {
    var output = ""
    var currentPage = 0
    var previousY = Float.greatestFiniteMagnitude
    var previousX: Float = 0
    var inList = false
    var inParagraph = false
    var lastListX: Float?
    var inCodeBlock = false
    var previousHadDotLeaders = false
    /// Whether the paragraph being built started inside a wrapped-bold run,
    /// which is what lets the bold-to-regular transition end it.
    var paragraphInWrappedBoldRun = false
    /// Set when a table-of-contents marker heading is emitted, suppressing
    /// further heading detection for the rest of that page.
    var tocSuppressPage: Int?
    var insertedTables: Set<PdfBlockSlot> = []
    var insertedImages: Set<PdfBlockSlot> = []
}

/// A page and an index within that page's blocks of one kind.
private struct PdfBlockSlot: Hashable {
    var page: Int
    var index: Int
}

/// Convert analysed lines to Markdown, interleaving tables and images.
///
/// - Parameters:
///   - pageTables: rendered tables by page, in detection order.
///   - pageImages: rendered image placeholders by page, in input order.
///   - bandSplitPages: pages laid out as side-by-side bands, where a large
///     horizontal jump at the same baseline separates paragraphs.
func pdfWriteMarkdown(
    _ analysis: PdfDocumentAnalysis,
    options: PdfMarkdownOptions = PdfMarkdownOptions(),
    pageTables: [Int: [PdfPositionedMarkdown]] = [:],
    pageImages: [Int: [PdfPositionedMarkdown]] = [:],
    bandSplitPages: Set<Int> = [],
    structRoles: PdfStructRoleMap? = nil
) -> String {
    let lines = analysis.lines
    let baseSize = analysis.baseSize
    let paragraphThreshold = analysis.paragraphThreshold

    // Nothing at all produces nothing at all — not even the trailing newline
    // an empty paragraph would leave.
    if lines.isEmpty && pageTables.isEmpty && pageImages.isEmpty { return "" }

    var state = PdfWriterState()

    // Every page carrying a table or an image, in order — including pages
    // with no text at all, which would otherwise never be visited.
    var contentPages = Array(Set(pageTables.keys).union(pageImages.keys))
    contentPages.sort()
    // The block order is built once per page. It is only a meaningful sort
    // on chart pages; ordinary pages keep their legacy table-then-image
    // order, and repeating the work per line would be waste.
    var pageBlocks: [Int: [PdfPositionedBlockRef]] = [:]
    for page in contentPages {
        pageBlocks[page] = pdfPositionedBlocksForPage(
            tables: pageTables[page] ?? [], images: pageImages[page] ?? [])
    }

    /// Emit every block on a page that has not been emitted yet.
    func flushPage(_ page: Int, into state: inout PdfWriterState) {
        guard let blocks = pageBlocks[page] else { return }
        for block in blocks {
            let slot = PdfBlockSlot(page: page, index: block.index)
            let already =
                block.kind == .table
                ? state.insertedTables.contains(slot) : state.insertedImages.contains(slot)
            if already { continue }
            if state.inParagraph {
                state.output += "\n\n"
                state.inParagraph = false
            }
            state.output += "\n" + block.block.markdown + "\n"
            if block.kind == .table {
                state.insertedTables.insert(slot)
            } else {
                state.insertedImages.insert(slot)
            }
        }
    }

    for (lineIndex, line) in lines.enumerated() {
        // MARK: page break

        if line.page != state.currentPage {
            if state.currentPage > 0 {
                if state.inCodeBlock {
                    state.output += "```\n"
                    state.inCodeBlock = false
                }
                flushPage(state.currentPage, into: &state)
                if state.inParagraph {
                    state.output += "\n\n"
                    state.inParagraph = false
                }
                state.output += "\n\n"
            }

            // Pages between this one and the last that carry only tables or
            // images have no line to trigger them, so they are flushed here.
            for page in contentPages {
                if page <= state.currentPage { continue }
                if page >= line.page { break }
                flushPage(page, into: &state)
                if state.inParagraph {
                    state.output += "\n\n"
                    state.inParagraph = false
                }
                state.output += "\n\n"
            }

            state.currentPage = line.page
            state.previousY = .greatestFiniteMagnitude
            state.previousX = 0
            state.paragraphInWrappedBoldRun = false

            if options.includePageNumbers {
                state.output += "<!-- Page \(state.currentPage) -->\n\n"
            }
        }

        // MARK: blocks that precede this line

        if let blocks = pageBlocks[state.currentPage] {
            for block in blocks {
                let slot = PdfBlockSlot(page: state.currentPage, index: block.index)
                let already =
                    block.kind == .table
                    ? state.insertedTables.contains(slot) : state.insertedImages.contains(slot)
                guard pdfPositionedBlockPrecedesLine(block.block, line), !already else { continue }
                if state.inParagraph {
                    state.output += "\n\n"
                    state.inParagraph = false
                    state.paragraphInWrappedBoldRun = false
                }
                state.output += "\n" + block.block.markdown + "\n"
                if block.kind == .table {
                    state.insertedTables.insert(slot)
                } else {
                    state.insertedImages.insert(slot)
                }
            }
        }

        // MARK: paragraph break

        let yGap = state.previousY - line.y
        let lineX = line.items.first?.x ?? 0
        // Absolute, so a *backward* jump breaks too — which is how newspaper
        // columns emitted one after another on one page stay separate.
        let isParagraphBreak = abs(yGap) > paragraphThreshold
        // On a band-split page, a large horizontal jump at the same height
        // is a switch between bands rather than a continuation.
        let isBandSwitch =
            bandSplitPages.contains(line.page) && abs(yGap) <= paragraphThreshold
            && abs(state.previousX - lineX) > 50 && state.previousY < .greatestFiniteMagnitude
        let lineAllBold = !line.items.isEmpty && line.items.allSatisfy(\.isBold)
        let lineInWrappedBoldRun = analysis.wrappedBoldParagraphLines.contains(lineIndex)
        // Leaving a bold run for ordinary text ends the paragraph even on a
        // gap too small to break one — the bold run was its own block.
        let isBoldToRegularBreak =
            state.inParagraph && state.paragraphInWrappedBoldRun && !lineInWrappedBoldRun
            && !lineAllBold && yGap > baseSize * 1.2 && yGap <= paragraphThreshold
        if (isParagraphBreak || isBandSwitch || isBoldToRegularBreak) && state.inParagraph {
            state.output += "\n\n"
            state.inParagraph = false
            state.paragraphInWrappedBoldRun = false
        }
        // A list deliberately survives a paragraph break; the continuation
        // test below is what ends it.
        state.previousY = line.y
        state.previousX = lineX

        let text = pdfLineTextWithEmphasis(
            line, formatBold: options.detectBold, formatItalic: options.detectItalic,
            formatUnderline: options.detectUnderline)
        let trimmed = text.rustTrim()
        // Pattern matching runs on the plain text, so emphasis markers do
        // not defeat the list and caption tests.
        let plainText = pdfLineText(line)
        let plainTrimmed = plainText.rustTrim()
        if trimmed.isEmpty { continue }

        let structRole = structRoles.flatMap { pdfResolveLineStructRole(line, $0) }
        let isCodeLine =
            structRole == .code
            || (options.detectCode && line.items.contains { pdfIsMonospaceFont($0.fontName) })
        if state.inCodeBlock && !isCodeLine {
            state.output += "```\n"
            state.inCodeBlock = false
        }

        // MARK: caption

        if structRole == .caption || pdfIsCaptionLine(plainTrimmed) {
            endParagraph(&state)
            state.output += trimmed + "\n\n"
            continue
        }

        // MARK: heading

        // A tag adds a heading; it never suppresses one the font heuristic
        // would find, because tagged documents routinely mark obvious
        // headings as `P` or `Span`.
        let structHeading = structRole.flatMap(pdfStructRoleHeadingLevel)
            .flatMap { analysis.overusedHeadingLevels.contains($0) ? nil : $0 }

        // Inside a list, a line that continues the previous item visually
        // must not be reclassified as a heading — PDFs often bold the lead
        // phrase of a list item across its wrapped lines.
        var looksLikeListContinuation = false
        if state.inList, let listX = state.lastListX, let currentX = line.items.first?.x {
            looksLikeListContinuation =
                currentX >= listX - 5 && currentX <= listX + 50 && yGap >= 0
                && yGap <= paragraphThreshold && !pdfIsListItem(plainTrimmed)
        }
        let nonHeadingRole = structRole?.isNonHeadingContent ?? false

        var heuristicHeading: Int?
        if options.detectHeaders && !nonHeadingRole && !isCodeLine && !looksLikeListContinuation
            && plainTrimmed.utf8.count > 3
            && plainTrimmed.rustSplitWhitespace().count <= 15
            && !pdfStartsWithBulletMarker(plainTrimmed) && !pdfIsTocEntryLine(plainTrimmed)
            && !pdfIsHeadingFragment(plainTrimmed) && state.tocSuppressPage != line.page
        {
            let lineFontSize = line.items.first?.fontSize ?? baseSize
            heuristicHeading = pdfHeadingLevel(
                fontSize: lineFontSize, bodySize: baseSize, tiers: analysis.headingTiers,
                isBold: pdfLineIsMostlyBold(line))
            if heuristicHeading == nil {
                heuristicHeading = rarityHeading(
                    line: line, lineIndex: lineIndex, lineFontSize: lineFontSize,
                    plainTrimmed: plainTrimmed, state: state)
            }
            if heuristicHeading == nil {
                heuristicHeading = analysis.sequenceHeadingLevels[lineIndex]
            }
        }

        if let level = structHeading ?? heuristicHeading {
            endParagraph(&state)
            // Plain text inside `#`, since bold and italic markers would be
            // redundant there — but underline is kept, because `<u>` carries
            // meaning a `#` does not.
            let headingText =
                options.detectUnderline
                ? pdfLineTextWithEmphasis(
                    line, formatBold: false, formatItalic: false, formatUnderline: true)
                : plainText
            state.output += String(repeating: "#", count: level) + " "
                + headingText.rustTrim() + "\n\n"
            if pdfIsTocMarkerHeading(plainTrimmed) { state.tocSuppressPage = line.page }
            state.inList = false
            continue
        }

        // MARK: list

        // `LI` only — an `LBody` is a continuation, not a new item. And a
        // tagged item already inside a list with no visible marker is a
        // wrapped line of the item above, so it falls through.
        if structRole == .listItem && !pdfIsListItem(plainTrimmed) && !state.inList {
            endParagraph(&state)
            state.output += "- " + trimmed + "\n"
            state.inList = true
            state.lastListX = line.items.first?.x
            continue
        }

        if options.detectLists && pdfIsListItem(plainTrimmed) {
            endParagraph(&state)
            state.output += pdfFormatListItem(trimmed) + "\n"
            state.inList = true
            state.lastListX = line.items.first?.x
            continue
        } else if state.inList {
            var isContinuation = false
            if let listX = state.lastListX, let currentX = line.items.first?.x {
                // A far more generous vertical bound than the paragraph
                // threshold — seven line heights — because a list item's
                // wrapped lines may straddle a page's worth of leading.
                isContinuation =
                    currentX >= listX - 5 && currentX <= listX + 50 && yGap < baseSize * 7
                    && !pdfIsListItem(plainTrimmed) && !pdfHasDotLeaders(plainTrimmed)
            }
            if isContinuation {
                // Joined onto the item above by replacing its newline.
                if state.output.hasSuffix("\n") {
                    state.output.removeLast()
                    state.output += " "
                }
                state.output += trimmed + "\n"
                continue
            }
            state.inList = false
            state.lastListX = nil
        }

        // MARK: quote and code

        if structRole == .blockQuote {
            endParagraph(&state)
            state.output += "> " + trimmed + "\n"
            continue
        }

        if isCodeLine {
            endParagraph(&state)
            if !state.inCodeBlock {
                state.output += "```\n"
                state.inCodeBlock = true
            }
            // Plain text inside a fence: emphasis markers would be literal.
            state.output += plainTrimmed + "\n"
            continue
        }

        // MARK: prose

        let currentDotLeaders = pdfHasDotLeaders(plainTrimmed)
        if state.inParagraph {
            // Dot-leader lines are table-of-contents rows, which must not be
            // run together into one paragraph.
            state.output += (currentDotLeaders || state.previousHadDotLeaders) ? "\n" : " "
        }
        state.output += trimmed
        state.paragraphInWrappedBoldRun =
            state.inParagraph
            ? (state.paragraphInWrappedBoldRun || lineInWrappedBoldRun) : lineInWrappedBoldRun
        state.inParagraph = true
        state.previousHadDotLeaders = currentDotLeaders
    }

    if state.inCodeBlock { state.output += "```\n" }

    // The last page's blocks, then any page after it — a document ending in
    // table-only or image-only pages has no line left to trigger them.
    flushPage(state.currentPage, into: &state)
    for page in contentPages where page > state.currentPage {
        flushPage(page, into: &state)
    }
    if state.inParagraph { state.output += "\n" }

    var cleanup = PdfCleanupOptions()
    cleanup.collapseDotLeaders = options.profile == .compact
    cleanup.fixHyphenation = options.fixHyphenation
    cleanup.removePageNumbers = options.removePageNumbers
    cleanup.formatUrls = options.formatUrls
    return pdfCleanMarkdown(state.output, options: cleanup)

    // MARK: helpers

    /// Close an open paragraph. Every block-level emission does this, and
    /// each one also clears the bold-run flag — unlike the paragraph-break
    /// test above, which clears it only when it actually breaks.
    func endParagraph(_ state: inout PdfWriterState) {
        if state.inParagraph {
            state.output += "\n\n"
            state.inParagraph = false
            state.paragraphInWrappedBoldRun = false
        }
    }

    /// The rarity fallback: a heading no size rule reached, scored on how
    /// unusual its size is plus how much it stands alone.
    ///
    /// Weights are the reference's: rarity a half, bold three tenths,
    /// standalone a fifth, isolated three tenths. Half a point passes, and a
    /// strong signal is required on top of the score so ordinary body text
    /// in a multi-column layout — where column switches break paragraph
    /// continuity and inflate rarity — is not promoted.
    func rarityHeading(
        line: PdfTextLine, lineIndex: Int, lineFontSize: Float, plainTrimmed: String,
        state: PdfWriterState
    ) -> Int? {
        if lineFontSize < baseSize * 0.95 { return nil }
        let wordCount = plainTrimmed.rustSplitWhitespace().count
        if !(1...15).contains(wordCount) { return nil }
        if analysis.wrappedBoldParagraphLines.contains(lineIndex) { return nil }

        let rarity = pdfFontSizeRarity(lineFontSize, analysis.fontStats)
        let allBold = !line.items.isEmpty && line.items.allSatisfy(\.isBold)
        let standalone = !state.inParagraph
        let isolated = analysis.isolatedLines.contains(lineIndex)
        let score =
            rarity * 0.5 + (allBold ? 0.3 : 0) + (standalone ? 0.2 : 0) + (isolated ? 0.3 : 0)

        let hasStrongSignal = allBold || isolated || (rarity >= 0.97 && wordCount <= 8)
        // Single-word headings are common, so one word passes when it is
        // all bold and at least four bytes. A mixed-bold lead-in like
        // `Note: …` is excluded by `allBold`.
        let enoughWords = wordCount >= 2 || (allBold && plainTrimmed.utf8.count >= 4)
        let numberedBold = allBold && pdfStartsWithSectionNumberAndTitle(plainTrimmed)
        if numberedBold || (score >= 0.5 && standalone && enoughWords && hasStrongSignal) {
            return pdfBoldHeadingLevel(analysis.headingTiers)
        }
        return nil
    }
}
