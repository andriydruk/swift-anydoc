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

/// The distinct heading sizes, largest first.
///
/// Only a line's *first* item votes, as in the reference: a heading's size is
/// the size it starts at. Lines with no letters — folios, rule numbers — are
/// excluded, or a large page number would claim the top tier and displace
/// the document's real headings.
func pdfHeadingTiers(_ lines: [PdfTextLine], bodySize: Float) -> [Float] {
    guard bodySize > 0 else { return [] }
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
    // Cluster within half a point, keeping the first seen as the tier.
    var tiers: [Float] = []
    for size in sizes {
        if let last = tiers.last, abs(last - size) < 0.5 { continue }
        tiers.append(size)
    }
    return tiers
}

/// The heading level of a line's size, or `nil` for body text.
func pdfHeadingLevel(fontSize: Float, bodySize: Float, tiers: [Float]) -> Int? {
    guard bodySize > 0 else { return nil }
    let ratio = fontSize / bodySize
    // Below a fifth larger than the body it is not a heading by size alone.
    if ratio < 1.2 { return nil }
    for (index, tier) in tiers.enumerated() where abs(fontSize - tier) < 0.5 {
        return index + 1
    }
    // Much larger but matching no tier: place it after the known tiers.
    if ratio >= 1.5 { return min(tiers.count + 1, 4) }
    return nil
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
func pdfBuildBlocks(_ lines: [PdfTextLine], styles: [String: PdfFontStyle] = [:]) -> [PdfBlock] {
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
        styles.isEmpty ? pdfLineText(line) : pdfLineTextWithEmphasis(line, styles: styles)
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
            : pdfHeadingLevel(fontSize: size, bodySize: bodySize, tiers: tiers)

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
func pdfRenderMarkdown(_ blocks: [PdfBlock]) -> String {
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
    // other format in this port.
    let body = parts.joined(separator: "\n\n")
    return body.isEmpty ? "" : body + "\n"
}
