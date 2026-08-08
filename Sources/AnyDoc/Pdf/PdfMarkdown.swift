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
enum PdfBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
}

/// Turn laid-out lines into blocks: headings by size, everything else
/// gathered into paragraphs.
func pdfBuildBlocks(_ lines: [PdfTextLine]) -> [PdfBlock] {
    let bodySize = pdfBodyFontSize(lines)
    let tiers = pdfHeadingTiers(lines, bodySize: bodySize)

    var blocks: [PdfBlock] = []
    // Lines that are not headings accumulate into a paragraph until a
    // heading or a paragraph break interrupts them.
    var pending: [PdfTextLine] = []

    func flushPending() {
        guard !pending.isEmpty else { return }
        for group in pdfGroupIntoParagraphs(pending) {
            let text = group.map(pdfLineText).filter { !$0.isEmpty }.joined(separator: " ")
            if !text.isEmpty { blocks.append(.paragraph(text)) }
        }
        pending = []
    }

    for line in lines {
        let text = pdfLineText(line)
        if text.isEmpty { continue }
        let size = line.items.first?.fontSize ?? 0
        if let level = pdfHeadingLevel(fontSize: size, bodySize: bodySize, tiers: tiers) {
            flushPending()
            blocks.append(.heading(level: level, text: text))
            continue
        }
        pending.append(line)
    }
    flushPending()
    return blocks
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
        }
    }
    // Blocks are separated by a blank line, and the document ends with one
    // newline — the same contract the Markdown renderer holds for every
    // other format in this port.
    let body = parts.joined(separator: "\n\n")
    return body.isEmpty ? "" : body + "\n"
}
