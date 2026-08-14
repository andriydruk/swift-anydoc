/// Heading detection and Markdown assembly, ported from pdf-inspector's
/// `analysis.rs` and `markdown/`.
///
/// A PDF has no headings, only text that happens to be larger. The reference
/// recovers them by size: the most common size on the page is the body, and
/// the distinct sizes above it — clustered, largest first — are the heading
/// levels.
///
/// Ported here is that size-based core. The reference's further signals —
/// numbering sequences, bold-only headings at body size, visual-style
/// sequences, table and chart exclusions — are **not** ported yet, so a
/// document whose headings differ from the body only by weight will not have
/// them detected.

/// The most common font size across the lines, weighted by how much text is
/// set in it. Weighting by characters rather than by run keeps a page of
/// short large captions from outvoting its body text.
func pdfBodyFontSize(_ lines: [PdfTextLine]) -> Float {
    var weight: [Int: Int] = [:]
    for line in lines {
        for item in line.items {
            let trimmed = item.text.rustTrim()
            if trimmed.isEmpty { continue }
            // Bucket to a tenth of a point: nominally equal sizes differ in
            // the last bits after the transform.
            let bucket = Int((item.fontSize * 10).rounded())
            weight[bucket, default: 0] += trimmed.unicodeScalars.count
        }
    }
    guard let best = weight.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) else {
        return 0
    }
    return Float(best.key) / 10
}

/// Boldness by *character mass*, so a heading with an unbold section-number
/// prefix — `4. ` followed by a bold title — still counts as bold.
///
/// Half the characters is the bar, and it is inclusive.
func pdfLineIsMostlyBold(_ line: PdfTextLine) -> Bool {
    var bold = 0
    var total = 0
    for item in line.items {
        let count = item.text.rustTrim().unicodeScalars.count
        total += count
        if item.isBold { bold += count }
    }
    return total > 0 && bold * 2 >= total
}

/// The distinct heading sizes, largest first.
///
/// Only a line's *first* item votes, as in the reference: a heading's size is
/// the size it starts at. Lines with no letters — folios, rule numbers — are
/// excluded, or a large page number would claim the top tier and displace
/// the document's real headings.
func pdfHeadingTiers(_ lines: [PdfTextLine], bodySize: Float) -> [Float] {
    // No guard on a zero body size: the reference has none, and relies on
    // float division giving infinity — every line then clears the ratio gate
    // rather than the document producing no tiers at all.
    var sizes: [Float] = []
    for line in lines {
        guard let first = line.items.first else { continue }
        guard first.fontSize / bodySize >= 1.2 else { continue }
        let text = pdfLineText(line).rustTrim()
        if text.isEmpty { continue }
        if !text.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) { continue }
        sizes.append(first.fontSize)
    }
    sizes.sort(by: >)
    // Cluster within half a point, keeping the first seen as the tier. The
    // reference compares against *any* existing tier; since the sizes descend
    // and tiers only grow, the last one is always the closest, so comparing
    // against it alone is equivalent.
    var tiers: [Float] = []
    for size in sizes {
        if let last = tiers.last, abs(last - size) < 0.5 { continue }
        tiers.append(size)
    }

    // Books often set section headings barely above body size — 11pt bold
    // over 10pt text — and nothing clears the 1.2 gate. Falling back to bold
    // lines modestly larger than the body gives those documents an H1
    // instead of every heading defaulting to H2.
    if tiers.isEmpty {
        var boldSizes: [Float] = []
        for line in lines {
            let text = pdfLineText(line).rustTrim()
            if text.isEmpty { continue }
            if !text.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) { continue }
            guard let first = line.items.first else { continue }
            if first.isBold && first.fontSize / bodySize >= 1.05 { boldSizes.append(first.fontSize) }
        }
        boldSizes.sort(by: >)
        for size in boldSizes where !tiers.contains(where: { abs($0 - size) < 0.5 }) {
            tiers.append(size)
        }
    }

    // Four tiers at most, which is also as deep as the levels below go.
    if tiers.count > 4 { tiers.removeLast(tiers.count - 4) }
    return tiers
}

/// The heading level of a line's size, or `nil` for body text.
///
/// Three routes, and the order matters. A bold line between 1.05 and 1.2
/// times the body size is checked against the tiers *first*: sub-gate tiers
/// only exist because of the bold fallback above, and honouring them for
/// non-bold text at the same size would promote every caption.
func pdfHeadingLevel(
    fontSize: Float, bodySize: Float, tiers: [Float], isBold: Bool = false
) -> Int? {
    // Again no zero guard. A zero body size makes the ratio infinite and
    // every line a heading; a zero *font* size makes it NaN, and since every
    // NaN comparison is false the ratio gate is passed and the fallback
    // returns 4. Both are the reference's behaviour.
    let ratio = fontSize / bodySize

    if ratio >= 1.05 && ratio < 1.2 && isBold && !tiers.isEmpty {
        for (index, tier) in tiers.enumerated() where abs(fontSize - tier) < 0.5 {
            return index + 1
        }
    }

    // Below a fifth larger than the body it is not a heading by size alone.
    if ratio < 1.2 { return nil }

    if !tiers.isEmpty {
        for (index, tier) in tiers.enumerated() where abs(fontSize - tier) < 0.5 {
            return index + 1
        }
        // Much larger but matching no tier: place it after the known tiers.
        if ratio >= 1.5 { return min(tiers.count + 1, 4) }
        return nil
    }

    // No tiers were discovered at all, so the ratio decides alone. Note this
    // never returns `nil`: past the 1.2 gate with no tiers, everything is a
    // heading of some level.
    if ratio >= 2.0 { return 1 }
    if ratio >= 1.5 { return 2 }
    if ratio >= 1.25 { return 3 }
    return 4
}

/// A block of the reconstructed document.
enum PdfBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// A figure or table caption, which stands alone rather than joining the
    /// paragraph around it.
    case caption(String)
    /// A run of list items, each already carrying its Markdown marker.
    case list([String])
    /// Lines set in a monospace font, rendered as a fenced block.
    case code([String])
}

/// A heading needs more than three bytes and at most fifteen words. Below the
/// one it is a fragment; above it, prose that happens to be large.
private let headingMinimumBytes = 3
private let headingMaximumWords = 15

/// A list item's continuation may start this far right of the item's own left
/// edge, and this far left of it, and still belong to it.
private let listContinuationLeftSlack: Float = 5
private let listContinuationRightSlack: Float = 50

/// Turn laid-out lines into blocks, following the reference's order of
/// decision: captions, then headings, then list items and their
/// continuations, then code, then paragraphs. `styles` supplies each font's
/// emphasis, which becomes `**`/`*` markers in the text.
///
/// The reference streams these straight into one output string; blocks are
/// kept here because the rest of this port's Markdown writers work that way,
/// and the two agree after `pdfRenderMarkdown` puts the separators back.
func pdfBuildBlocks(_ lines: [PdfTextLine], formatted: Bool = false) -> [PdfBlock] {
    let bodySize = pdfBodyFontSize(lines)
    let tiers = pdfHeadingTiers(lines, bodySize: bodySize)
    let paragraphThreshold = pdfParagraphThreshold(lines, bodySize: bodySize)

    var blocks: [PdfBlock] = []
    // The paragraph, list or code block being accumulated. Only one is ever
    // open, since every branch below closes the others first.
    var paragraph: [String] = []
    var paragraphHadDotLeaders = false
    var list: [String] = []
    var listX: Float?
    var code: [String] = []
    var previousY: Float?

    func render(_ line: PdfTextLine) -> String {
        formatted ? pdfLineTextWithEmphasis(line) : pdfLineText(line)
    }
    func closeParagraph() {
        if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined())) }
        paragraph = []
        paragraphHadDotLeaders = false
    }
    func closeList() {
        if !list.isEmpty { blocks.append(.list(list)) }
        list = []
        listX = nil
    }
    func closeCode() {
        if !code.isEmpty { blocks.append(.code(code)) }
        code = []
    }

    for line in lines {
        let plain = pdfLineText(line).rustTrim()
        let formatted = render(line).rustTrim()
        let lineX = line.items.first?.x ?? 0
        // A backward jump is as much a break as a forward one: newspaper
        // columns come out of the content stream one after the other.
        let gap = previousY.map { $0 - line.y } ?? .infinity
        previousY = line.y

        if abs(gap) > paragraphThreshold { closeParagraph() }
        if formatted.isEmpty { continue }

        let isCodeLine = line.items.contains { pdfIsMonospaceFont($0.fontName) }
        if !isCodeLine { closeCode() }

        if pdfIsCaptionLine(plain) {
            closeParagraph()
            closeList()
            blocks.append(.caption(formatted))
            continue
        }

        // A wrapped list item must not be promoted to a heading: PDFs often
        // bold the lead phrase of an item across its wrap lines, and an
        // all-bold middle line would otherwise split one item in two.
        let looksLikeListContinuation =
            !list.isEmpty && listX.map { isListContinuation(lineX, of: $0) } == true
            && gap >= 0 && gap <= paragraphThreshold && !pdfIsListItem(plain)

        let size = line.items.first?.fontSize ?? 0
        let level =
            isCodeLine || looksLikeListContinuation || plain.utf8.count <= headingMinimumBytes
            || plain.rustSplitWhitespace().count > headingMaximumWords
            || pdfStartsWithBulletMarker(plain)
            ? nil
            : pdfHeadingLevel(
                fontSize: size, bodySize: bodySize, tiers: tiers,
                isBold: pdfLineIsMostlyBold(line))

        if let level {
            closeParagraph()
            closeList()
            closeCode()
            // A heading is already emphasized by being a heading; markers
            // inside one would render as literal asterisks in most viewers.
            blocks.append(.heading(level: level, text: plain))
            continue
        }

        if pdfIsListItem(plain) {
            closeParagraph()
            closeCode()
            list.append(pdfFormatListItem(formatted))
            listX = lineX
            continue
        }
        if !list.isEmpty {
            // A continuation sits under the item's own text and follows it
            // closely enough — up to seven lines' worth of leading, which is
            // generous, but the reference is generous here.
            let isContinuation =
                listX.map { isListContinuation(lineX, of: $0) } == true
                && gap < bodySize * 7 && !pdfHasDotLeaders(plain)
            if isContinuation {
                list[list.count - 1] += " " + formatted
                continue
            }
            closeList()
        }

        if isCodeLine {
            closeParagraph()
            code.append(plain)
            continue
        }

        // Ordinary text joins the paragraph above it with a space — unless
        // either line carries dot leaders, where the break is the point.
        let dotLeaders = pdfHasDotLeaders(plain)
        if !paragraph.isEmpty {
            paragraph.append(dotLeaders || paragraphHadDotLeaders ? "\n" : " ")
        }
        paragraph.append(formatted)
        paragraphHadDotLeaders = dotLeaders
    }
    closeParagraph()
    closeList()
    closeCode()
    return blocks
}

/// Whether a line starting at `x` sits under a list item whose text starts at
/// `listX`: at or just left of it, and not so far right as to be a new block.
private func isListContinuation(_ x: Float, of listX: Float) -> Bool {
    x >= listX - listContinuationLeftSlack && x <= listX + listContinuationRightSlack
}

/// Render blocks as Markdown.
func pdfRenderMarkdown(
    _ blocks: [PdfBlock], cleanup: PdfCleanupOptions = PdfCleanupOptions()
) -> String {
    var parts: [String] = []
    for block in blocks {
        switch block {
        case .heading(let level, let text):
            parts.append(String(repeating: "#", count: max(1, min(level, 6))) + " " + text)
        case .paragraph(let text):
            parts.append(text)
        case .caption(let text):
            parts.append(text)
        case .list(let items):
            parts.append(items.joined(separator: "\n"))
        case .code(let lines):
            parts.append("```\n" + lines.joined(separator: "\n") + "\n```")
        }
    }
    // Blocks are separated by a blank line, and the document ends with one
    // newline — the same contract the Markdown renderer holds for every
    // other format in this port. The cleanup pass then repairs the residue
    // that reassembling fragments leaves behind, as it does in the
    // reference, which runs it over the whole document at the end.
    let body = parts.joined(separator: "\n\n")
    return body.isEmpty ? "" : pdfCleanMarkdown(body + "\n", options: cleanup)
}
