/// The leaf tests of column detection, ported from `extractor/layout.rs` in
/// pdf-inspector: `find_relative_valleys`, `is_list_marker_column`,
/// `spans_multiple_columns` and `is_page_number`.
///
/// Column detection projects every text item onto the page's x axis and looks
/// for the gutter — a vertical band the text avoids. On a ragged page the
/// gutter is empty and easy to find; on a *justified* two-column page it is
/// not, because the text reaches the gutter's edge on both sides and the
/// histogram never drops to zero. `find_relative_valleys` is the fallback for
/// that case: it looks for a *relative* dip between two substantial peaks
/// rather than an absolute gap.
///
/// The other three are the guards that stop a dip being believed. Between
/// them they reject a column of bullets, a full-width heading and a page
/// number — each of which produces a convincing valley that means nothing.

/// A column's horizontal extent.
struct PdfColumnRegion: Equatable {
    var xMin: Float
    var xMax: Float
}

// Tuning constants, all the reference's own.

/// Half-width of the gutter a valley is reported as, in bins — so the range
/// is five bins wide, about 10pt.
private let pdfMinGutterBins = 2
/// A valley must fall below 60% of the peaks flanking it.
private let pdfContrastThreshold: Float = 0.60
/// How far to either side the flanking peaks are sought: 25 bins, ~50pt.
private let pdfPeakWindow = 25
/// A flanking peak below this is not a dense text column.
private let pdfMinPeakHeight: Float = 20

/// Find gutters as *relative* dips in a projection histogram.
///
/// Returns bin ranges, at most one. Multi-column layouts with three or more
/// columns have clear empty gutters that the absolute detection already
/// handles, so this fallback deliberately reports a single valley — it exists
/// for the two-column justified page, and returning more would let it
/// second-guess the detector that called it.
func pdfFindRelativeValleys(
    histogram: [UInt32],
    binCount: Int,
    binWidth: Float,
    pageWidth: Float,
    marginThreshold: Float
) -> [(lower: Int, upper: Int)] {
    if binCount < 10 { return [] }

    // Smooth with a five-bin moving average. The window is clamped at both
    // ends rather than wrapping or zero-padding, so the mean is taken over
    // however many bins actually exist there.
    var smoothed = [Float](repeating: 0, count: binCount)
    let halfWindow = 2
    for index in 0..<binCount {
        let low = max(index - halfWindow, 0)
        let high = min(index + halfWindow + 1, binCount)
        var sum: UInt32 = 0
        for bin in low..<high { sum &+= histogram[bin] }
        smoothed[index] = Float(sum) / Float(high - low)
    }

    // (bin, valley value, contrast)
    var candidates: [(bin: Int, value: Float, contrast: Float)] = []

    // Rust's `PEAK_WINDOW..num_bins.saturating_sub(PEAK_WINDOW)` is simply
    // empty when the page is narrower than two windows; Swift would trap on
    // the reversed range, so it is guarded rather than clamped.
    let scanEnd = binCount >= pdfPeakWindow ? binCount - pdfPeakWindow : 0
    if pdfPeakWindow < scanEnd {
        for index in pdfPeakWindow..<scanEnd {
            let value = smoothed[index]
            // An empty margin is not a valley between columns.
            if value < 1 { continue }

            // A local minimum, allowing half a unit of slack so a flat floor
            // still qualifies.
            let localLow = max(index - 3, 0)
            let localHigh = min(index + 4, binCount)
            var isLocalMinimum = true
            for bin in localLow..<localHigh where smoothed[bin] < value - 0.5 {
                isLocalMinimum = false
                break
            }
            if !isLocalMinimum { continue }

            var leftPeak: Float = 0
            for bin in max(index - pdfPeakWindow, 0)..<index {
                leftPeak = max(leftPeak, smoothed[bin])
            }
            var rightPeak: Float = 0
            for bin in (index + 1)..<min(index + 1 + pdfPeakWindow, binCount) {
                rightPeak = max(rightPeak, smoothed[bin])
            }
            if leftPeak < pdfMinPeakHeight || rightPeak < pdfMinPeakHeight { continue }

            // Both peaks must be comparable. Without this, the drop-off at a
            // ragged right margin reads as a gutter on a single-column page.
            let balance = min(leftPeak, rightPeak) / max(leftPeak, rightPeak)
            if balance < 0.40 { continue }

            let referencePeak = min(leftPeak, rightPeak)
            let contrast = value / referencePeak
            if contrast < pdfContrastThreshold {
                // A dip inside the page margin is the margin, not a gutter.
                let centre = Float(index) * binWidth
                if centre > marginThreshold && centre < pageWidth - marginThreshold {
                    candidates.append((index, value, contrast))
                }
            }
        }
    }

    if candidates.isEmpty { return [] }

    // Adjacent candidates describe one gutter, so they are grouped and the
    // deepest point of each group kept.
    var valleys: [(lower: Int, upper: Int)] = []
    var bestBin = candidates[0].bin
    var bestContrast = candidates[0].contrast

    func closeGroup() {
        valleys.append(
            (max(bestBin - pdfMinGutterBins, 0), min(bestBin + pdfMinGutterBins + 1, binCount)))
    }

    for index in 1..<max(candidates.count, 1) {
        let previous = candidates[index - 1]
        let next = candidates[index]
        if next.bin - previous.bin <= 5 {
            if next.contrast < bestContrast {
                bestBin = next.bin
                bestContrast = next.contrast
            }
        } else {
            closeGroup()
            bestBin = next.bin
            bestContrast = next.contrast
        }
    }
    closeGroup()

    if valleys.count > 1 {
        // Keep the group whose deepest nearby candidate has the best
        // contrast. The search is by *bin distance* from the midpoint rather
        // than by which candidates built the group, so a group with no
        // candidate within five bins of its own midpoint is passed over.
        var bestIndex = 0
        var best = Float.greatestFiniteMagnitude
        for (position, valley) in valleys.enumerated() {
            let middle = (valley.lower + valley.upper) / 2
            var nearest: Float?
            for candidate in candidates where abs(candidate.bin - middle) <= 5 {
                nearest = nearest.map { min($0, candidate.contrast) } ?? candidate.contrast
            }
            if let nearest, nearest < best {
                best = nearest
                bestIndex = position
            }
        }
        return [valleys[bestIndex]]
    }

    return valleys
}

/// The bullet glyphs that form a marker column.
private let pdfListMarkerScalars: Set<Unicode.Scalar> = [
    "•", "●", "○", "◦", "▪", "▫", "◆", "◇", "■", "□",
]

/// Whether one side of a candidate gutter is really a column of bullets.
///
/// A list sets its markers on the left margin and its text further in, which
/// puts a genuine valley between them. Believing it splits every list item
/// across two columns, so the side is checked for being almost nothing but
/// standalone markers.
///
/// Four fifths is the bar rather than all of them: a stray page number or
/// footnote reference among the bullets should not rescue the split.
func pdfIsListMarkerColumn(_ items: [PdfLayoutItem]) -> Bool {
    if items.isEmpty { return false }
    var markers = 0
    for item in items {
        // Exactly one scalar, and that scalar a marker — a bullet glued to
        // its text is not a marker column.
        var scalars = item.text.rustTrim().unicodeScalars.makeIterator()
        guard let first = scalars.next(), scalars.next() == nil else { continue }
        if pdfListMarkerScalars.contains(first) { markers += 1 }
    }
    return Float(markers) / Float(items.count) >= 0.8
}

/// Whether an item reaches across two or more columns — a full-width heading
/// or title, which must not be filed under either column.
///
/// A column counts as touched when the overlap is more than a tenth of its
/// width *or* more than 20pt outright. The second test is what catches a
/// heading that only just enters a wide column.
func pdfSpansMultipleColumns(_ item: PdfLayoutItem, _ columns: [PdfColumnRegion]) -> Bool {
    let right = item.x + pdfEffectiveItemWidth(item)
    var touched = 0
    for column in columns {
        let start = max(item.x, column.xMin)
        let end = min(right, column.xMax)
        let overlap = max(end - start, 0)
        if overlap > (column.xMax - column.xMin) * 0.10 || overlap > 20 { touched += 1 }
    }
    return touched >= 2
}

/// Whether an item is a standalone page number, which Markdown output drops.
///
/// One to four digits and nothing else, sitting in the top or bottom band of
/// the page. The bands are absolute point values rather than fractions, so
/// they assume a page of roughly Letter or A4 height — a much taller page
/// would put its footer outside the bottom band entirely.
func pdfIsPageNumber(_ item: PdfLayoutItem) -> Bool {
    let text = item.text.rustTrim()
    // `len()` is bytes in the reference; every accepted character is ASCII,
    // so this only matters for rejecting long multi-byte text early.
    if text.isEmpty || text.utf8.count > 4 { return false }
    for scalar in text.unicodeScalars where !pdfIsAsciiDigitScalarValue(scalar) { return false }
    return item.y > 720 || item.y < 100
}
