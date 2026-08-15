/// The leaves of heading-sequence detection, ported from
/// `markdown/heading.rs`: `has_displaced_baseline_peer`,
/// `numbering_has_section_separation` and `sequence_level`.
///
/// Waves 76–78 built the three signals — numbering, title-likeness, visual
/// style. These are the tests that decide when a *run* of lines sharing one
/// of them is really a heading level rather than a coincidence, and the
/// level such a run should be given.
///
/// The assembly that consumes them, `classify_heading_sequences`, is not
/// ported yet.

/// Two baselines within this are the same row.
private let pdfBaselinePeerTolerance: Float = 2
/// Indents differing by this much are different columns.
private let pdfPeerXBucketPoints: Float = 24

/// A line under consideration as a heading.
struct PdfHeadingCandidate {
    var lineIndex: Int
    var fontSize: Float
    var style: PdfVisualStyle
    var numbering: PdfNumbering?
}

/// Whether a line has a peer beside it at a displaced indent.
///
/// A fixed-size sidebar label needs stronger evidence than typography alone:
/// table headers and parallel-column fragments repeat the same small bold
/// font at a displaced x. The peer may survive as a separate line, or it may
/// already have been grouped into *this* line — so both are checked.
func pdfHasDisplacedBaselinePeer(_ lines: [PdfTextLine], _ lineIndex: Int) -> Bool {
    guard lineIndex >= 0, lineIndex < lines.count else { return false }
    let line = lines[lineIndex]
    guard let x = line.items.first?.x else { return false }

    // Within the line: a wide void between two runs is a column boundary the
    // grouper did not split. Note the raw width, floored at zero.
    let sorted = line.items.enumerated().sorted { left, right in
        if left.element.x != right.element.x { return left.element.x < right.element.x }
        return left.offset < right.offset
    }.map(\.element)
    for index in 0..<max(sorted.count - 1, 0) {
        let leftEdge = sorted[index].x + max(sorted[index].width, 0)
        if sorted[index + 1].x - leftEdge >= pdfPeerXBucketPoints { return true }
    }

    // Across lines: another line on the same page sharing this baseline but
    // starting at a different indent.
    for (otherIndex, other) in lines.enumerated() where otherIndex != lineIndex {
        guard other.page == line.page, abs(other.y - line.y) <= pdfBaselinePeerTolerance,
            let otherX = other.items.first?.x
        else { continue }
        if abs(otherX - x) >= pdfPeerXBucketPoints { return true }
    }
    return false
}

/// Whether two numbered candidates are far enough apart to be sections.
///
/// A compact parent/child run — `1.` immediately followed by `1.1.` — is an
/// ordered list far more often than a document hierarchy, because genuine
/// section headings have body content between them. Two intervening lines is
/// the bar, or a page boundary, which settles it outright.
func pdfNumberingHasSectionSeparation(
    _ left: PdfHeadingCandidate, _ right: PdfHeadingCandidate, _ lines: [PdfTextLine]
) -> Bool {
    guard left.lineIndex >= 0, left.lineIndex < lines.count,
        right.lineIndex >= 0, right.lineIndex < lines.count
    else { return false }
    if lines[left.lineIndex].page != lines[right.lineIndex].page { return true }
    return abs(left.lineIndex - right.lineIndex) >= 3
}

/// The heading level a candidate should be given.
///
/// Numbering wins outright when present — its depth *is* the level, clamped
/// to the six Markdown offers. Otherwise size decides, and a line that size
/// rejects still becomes a heading by weight: `pdfBoldHeadingLevel` is the
/// fallback rather than a refusal, which is what admits a bold section
/// heading set at exactly body size.
func pdfSequenceLevel(
    _ candidate: PdfHeadingCandidate, bodySize: Float, tiers: [Float]
) -> Int {
    if let numbering = candidate.numbering {
        return min(max(numbering.depth, 1), 6)
    }
    return pdfHeadingLevel(
        fontSize: candidate.fontSize, bodySize: bodySize, tiers: tiers,
        isBold: candidate.style.bold) ?? pdfBoldHeadingLevel(tiers)
}
