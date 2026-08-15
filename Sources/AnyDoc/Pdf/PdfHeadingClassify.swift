/// Heading levels from repeated sequences, ported from
/// `classify_heading_sequences` in `markdown/heading.rs`.
///
/// The heading half's assembly, and the counterpart to wave 71's layout one.
/// Waves 76–79 built the signals and the tests; this composes them into the
/// question that matters: which lines does a *repetition* prove are headings?
///
/// Repetition alone is weak evidence — captions, author lists and table rows
/// repeat too. So a group of lines sharing a visual style is promoted only on
/// one of two much stronger findings: a coherent **numbered hierarchy**
/// running through it, or a **displaced sidebar** style that clears six
/// separate guards at once.
///
/// The reference takes an `isolated_lines` set that it uses **only in a trace
/// log** and never consults. It is omitted here rather than carried unused.

/// A line under this fraction of the body size is too small to be a heading.
private let pdfMinFontRatio: Float = 0.72
/// Candidates may occupy at most this percentage of the document's lines: a
/// sequence covering more than a fifth of the page is the body text.
private let pdfMaxSequenceDensityPercent = 20

/// Heading levels keyed by line index, for lines a sequence supports.
///
/// - `excludedLines`: wrapped bold paragraphs, chart labels and lines with an
///   explicit non-heading structure role. They cannot support another line's
///   candidacy, which is what stops table headers and list labels
///   manufacturing a false sequence.
func pdfClassifyHeadingSequences(
    _ lines: [PdfTextLine], bodySize: Float, tiers: [Float], excludedLines: Set<Int> = []
) -> [Int: Int] {
    let bodyFont = pdfDocumentBodyFont(lines)
    let bodyXBucket = pdfDocumentBodyXBucket(lines)

    var candidates: [PdfHeadingCandidate] = []
    for (lineIndex, line) in lines.enumerated() {
        if excludedLines.contains(lineIndex) { continue }
        if line.items.isEmpty { continue }
        guard let fontSize = pdfDominantFontSize(line) else { continue }
        if fontSize < bodySize * pdfMinFontRatio { continue }

        let text = pdfLineText(line).rustTrim()
        let numbering = pdfParseNumbering(text)
        // A line that carries a second decimal number is prose *about* the
        // document rather than a heading of it.
        if numbering != nil && pdfHasAdditionalDecimalNumbering(text) { continue }
        guard let style = pdfVisualStyle(line) else { continue }
        if !pdfTitleLike(text, numbered: numbering != nil, bold: style.bold) { continue }

        candidates.append(
            PdfHeadingCandidate(
                lineIndex: lineIndex, fontSize: fontSize, style: style, numbering: numbering))
    }

    let eligibleLineCount = lines.enumerated().filter {
        !excludedLines.contains($0.offset) && !$0.element.items.isEmpty
    }.count
    let sparseCandidatePopulation =
        candidates.count * 100 <= eligibleLineCount * pdfMaxSequenceDensityPercent

    // Grouped by exact visual style: same font, same weight, same indent
    // bucket. Insertion order is preserved within each group, so the groups
    // are in line order — which the adjacency test below relies on.
    var groupOrder: [PdfVisualStyle] = []
    var visualGroups: [PdfVisualStyle: [PdfHeadingCandidate]] = [:]
    for candidate in candidates {
        if visualGroups[candidate.style] == nil { groupOrder.append(candidate.style) }
        visualGroups[candidate.style, default: []].append(candidate)
    }

    var decisions: [Int: Int] = [:]
    for style in groupOrder {
        guard let group = visualGroups[style], let first = group.first else { continue }
        let maximumSequenceLines = max(
            eligibleLineCount * pdfMaxSequenceDensityPercent / 100, 4)
        if group.count < 2 || group.count > maximumSequenceLines { continue }

        // A bold face that is not the body's own is the sidebar's signature.
        let distinctBoldFace = style.bold && (bodyFont == nil || style.font != bodyFont)

        // Only numbering that is *itself* set apart supports a hierarchy —
        // by size or by a distinct bold face. Numbering in body type is a
        // list.
        let supportedNumbered = group.filter { candidate in
            candidate.numbering != nil
                && (candidate.fontSize >= bodySize * 1.05
                    || (candidate.style.bold
                        && (bodyFont == nil || candidate.style.font != bodyFont)))
        }

        var hierarchicalLines: Set<Int> = []
        for (index, left) in supportedNumbered.enumerated() {
            guard let leftNumbering = left.numbering else { continue }
            for right in supportedNumbered.dropFirst(index + 1) {
                guard let rightNumbering = right.numbering else { continue }
                if leftNumbering.kind == rightNumbering.kind
                    && pdfNumberingFormsHierarchy(leftNumbering.parts, rightNumbering.parts)
                    && pdfNumberingHasSectionSeparation(left, right, lines)
                {
                    hierarchicalLines.insert(left.lineIndex)
                    hierarchicalLines.insert(right.lineIndex)
                }
            }
        }

        var smallestSize = Float.infinity
        var largestSize = -Float.infinity
        for candidate in group {
            smallestSize = min(smallestSize, candidate.fontSize)
            largestSize = max(largestSize, candidate.fontSize)
        }
        let sizeSpan = largestSize - smallestSize

        // A sidebar whose labels are all one size needs its own evidence:
        // several *distinct* labels, each complete, none of them beside a
        // displaced peer — which is what separates a sidebar from a column
        // of table headers.
        let distinctLabels = Set(
            group.map { pdfLineText(lines[$0.lineIndex]).rustTrim().rustLowercased() })
        let fixedSizeSidebarEvidence =
            sizeSpan < 0.4 && distinctLabels.count >= 2
            && group.allSatisfy { candidate in
                pdfCompleteSidebarLabel(pdfLineText(lines[candidate.lineIndex]))
                    && !pdfHasDisplacedBaselinePeer(lines, candidate.lineIndex)
            }

        // Six guards at once, and every one is needed: a distinct bold face,
        // a document not already dense with candidates, either varied sizes
        // or the fixed-size evidence above, one page, at least four lines
        // between entries, an indent well away from the body's, and type
        // smaller than the body.
        let displacedSidebar =
            distinctBoldFace && sparseCandidatePopulation
            && (sizeSpan >= 0.4 || fixedSizeSidebarEvidence)
            && group.allSatisfy { lines[$0.lineIndex].page == lines[first.lineIndex].page }
            && zip(group, group.dropFirst()).allSatisfy {
                $1.lineIndex >= $0.lineIndex + 4
            }
            && (bodyXBucket.map { abs(style.xBucket - $0) >= 4 } ?? false)
            && group.allSatisfy { $0.fontSize < bodySize * 0.95 }

        if hierarchicalLines.isEmpty && !displacedSidebar { continue }

        for candidate in group {
            // A hierarchy promotes only the lines that took part in it; a
            // sidebar promotes the whole group.
            if !displacedSidebar && !hierarchicalLines.contains(candidate.lineIndex) { continue }
            decisions[candidate.lineIndex] = pdfSequenceLevel(
                candidate, bodySize: bodySize, tiers: tiers)
        }
    }

    return decisions
}
