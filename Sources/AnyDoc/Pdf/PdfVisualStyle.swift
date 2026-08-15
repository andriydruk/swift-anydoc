/// A line's visual identity, ported from `markdown/heading.rs`:
/// `dominant_font`, `dominant_font_size`, `document_body_font`,
/// `document_body_x_bucket` and `visual_style`.
///
/// The third and last of the signals `PdfMarkdown.swift` records as missing.
/// Size and numbering say what a line *is*; this says what it *looks like*,
/// so that a run of lines sharing a font, an indent and a weight can be
/// recognised as one level of heading even when none of them is larger than
/// the body.
///
/// Every one of these is a weighted vote, and the tie-breaks are not
/// uniform — two prefer the smaller key and one the larger. They are spelled
/// out individually below rather than shared.

/// Indents are bucketed this coarsely, so a line nudged a point or two still
/// counts as the same indent.
private let pdfXBucketPoints: Float = 24

/// A line's visual identity: its font, its indent bucket and its weight.
struct PdfVisualStyle: Equatable, Hashable {
    var font: String
    var xBucket: Int
    var bold: Bool
}

/// The font most of a line's characters are set in.
///
/// Weighted by trimmed character count, with every run counting at least
/// one — so a line of empty runs still has a dominant font rather than none.
/// Ties go to the **lexicographically smaller** name.
func pdfDominantFont(_ line: PdfTextLine) -> String? {
    var weights: [String: Int] = [:]
    for item in line.items {
        let weight = max(item.text.rustTrim().unicodeScalars.count, 1)
        weights[item.fontName, default: 0] += weight
    }
    var bestFont: String?
    var bestWeight = -1
    for (font, weight) in weights {
        if weight > bestWeight || (weight == bestWeight && font < (bestFont ?? font)) {
            bestFont = font
            bestWeight = weight
        }
    }
    return bestFont
}

/// The size most of a line's characters are set at.
///
/// A section number is sometimes a separate, smaller run — occasionally a
/// superscript — so taking the *first* run's size would reject a heading
/// whose title is at the document's heading size. Character weighting lets
/// the longer title win while leaving an ordinary one-run line exact.
///
/// Note the tie goes to the **larger** size here, the opposite of every other
/// vote in this file: between two equally weighted sizes the heading is the
/// bigger one.
func pdfDominantFontSize(_ line: PdfTextLine) -> Float? {
    var weights: [Int: Int] = [:]
    for item in line.items {
        // Rounded to a tenth, unlike the font statistics of wave 74, which
        // truncate. Different function, different rule.
        let bucket = Int((item.fontSize * 10).rounded())
        let weight = max(item.text.rustTrim().unicodeScalars.count, 1)
        weights[bucket, default: 0] += weight
    }
    var bestBucket: Int?
    var bestWeight = -1
    for (bucket, weight) in weights {
        if weight > bestWeight || (weight == bestWeight && bucket > (bestBucket ?? bucket)) {
            bestBucket = bucket
            bestWeight = weight
        }
    }
    return bestBucket.map { Float($0) / 10 }
}

/// The font the document's body text is set in.
///
/// Bold runs are skipped outright: the body is what is *not* emphasised, and
/// counting bold text would let a heavily headed document elect a heading
/// font as its body. Ties go to the lexicographically smaller name.
func pdfDocumentBodyFont(_ lines: [PdfTextLine]) -> String? {
    var weights: [String: Int] = [:]
    for line in lines {
        for item in line.items where !item.isBold {
            // No `max(_, 1)` here, so an empty run contributes nothing at
            // all — unlike `pdfDominantFont`, where it contributes one.
            weights[item.fontName, default: 0] += item.text.rustTrim().unicodeScalars.count
        }
    }
    var bestFont: String?
    var bestWeight = -1
    for (font, weight) in weights {
        if weight > bestWeight || (weight == bestWeight && font < (bestFont ?? font)) {
            bestFont = font
            bestWeight = weight
        }
    }
    return bestFont
}

/// The indent the document's body text starts at.
///
/// Whole lines vote here rather than runs, weighted by the line's own text,
/// and a mostly-bold line does not vote at all. Ties go to the smaller
/// bucket — the leftmost indent.
func pdfDocumentBodyXBucket(_ lines: [PdfTextLine]) -> Int? {
    var weights: [Int: Int] = [:]
    for line in lines {
        guard let first = line.items.first else { continue }
        if pdfLineIsMostlyBold(line) { continue }
        let weight = pdfLineText(line).rustTrim().unicodeScalars.count
        weights[Int((first.x / pdfXBucketPoints).rounded()), default: 0] += weight
    }
    var bestBucket: Int?
    var bestWeight = -1
    for (bucket, weight) in weights {
        if weight > bestWeight || (weight == bestWeight && bucket < (bestBucket ?? bucket)) {
            bestBucket = bucket
            bestWeight = weight
        }
    }
    return bestBucket
}

/// A line's visual style, or nothing when it has no runs at all.
///
/// The indent comes from the **first** run rather than from the dominant
/// one: where a line starts is what the eye reads as its indent, however its
/// characters are distributed.
func pdfVisualStyle(_ line: PdfTextLine) -> PdfVisualStyle? {
    guard let first = line.items.first, let font = pdfDominantFont(line) else { return nil }
    return PdfVisualStyle(
        font: font, xBucket: Int((first.x / pdfXBucketPoints).rounded()),
        bold: pdfLineIsMostlyBold(line))
}
