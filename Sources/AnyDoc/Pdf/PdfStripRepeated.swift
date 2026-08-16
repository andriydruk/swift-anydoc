/// The running-header remover, ported from `strip_repeated_lines` in
/// `markdown/preprocess.rs`.
///
/// A header or footer repeated on every page is noise once the document is
/// one Markdown stream. Finding it is a frequency problem with a lot of ways
/// to go wrong: a table's column headings also repeat, a page number changes
/// on every page, and a document title appearing once at the top of page one
/// must survive.
///
/// Six conditions have to hold together, and the port keeps all of them:
/// the text must appear on enough distinct pages, be at least ten bytes long
/// once normalised, not look structural, sit near a page edge, hold a
/// consistent vertical position across its pages, and not be a rule.
///
/// Lines sharing a baseline are additionally grouped into **Y-bands**, so a
/// column heading split into fragments too short to qualify individually is
/// caught by its row's combined text — and removing any member removes the
/// whole band.

/// A line this far into the page's distinct baselines, from either end,
/// counts as being in the margin. Five accommodates multi-line headers and
/// the stacked column headings of a tax form.
private let pdfEdgeLineCount = 5

/// Strip running headers and footers.
///
/// - Parameter pageCount: the document's page count, which sets the
///   frequency bar. Under three pages nothing is stripped: there is no such
///   thing as a repeated header on two pages.
func pdfStripRepeatedLines(_ lines: [PdfTextLine], pageCount: Int) -> [PdfTextLine] {
    if lines.isEmpty || pageCount < 3 { return lines }

    var pageYRange: [Int: (low: Float, high: Float)] = [:]
    var pageSortedYs: [Int: [Float]] = [:]
    for line in lines {
        if var range = pageYRange[line.page] {
            range.low = min(range.low, line.y)
            range.high = max(range.high, line.y)
            pageYRange[line.page] = range
        } else {
            pageYRange[line.page] = (line.y, line.y)
        }
        pageSortedYs[line.page, default: []].append(line.y)
    }
    for page in pageSortedYs.keys {
        // Sorted then deduplicated, so a page's *distinct* baselines are what
        // the edge test ranks against — twenty runs on one line count once.
        var sorted = pageSortedYs[page]!.sorted { $0 < $1 }
        var deduped: [Float] = []
        for value in sorted where deduped.last != value { deduped.append(value) }
        sorted = deduped
        pageSortedYs[page] = sorted
    }

    /// Whether a baseline is among the first or last five distinct ones.
    ///
    /// A page with ten or fewer distinct baselines is *entirely* margin —
    /// which is what lets a sparse cover page have its repeated title
    /// stripped even though the title sits in the middle of it.
    func isYAtEdge(_ y: Float, page: Int) -> Bool {
        guard let ys = pageSortedYs[page] else { return false }
        if ys.count <= pdfEdgeLineCount * 2 { return true }
        guard let position = ys.firstIndex(where: { abs($0 - y) < 0.1 }) else { return false }
        return position < pdfEdgeLineCount || position >= ys.count - pdfEdgeLineCount
    }

    let averageSpan: Float = {
        if pageYRange.isEmpty { return 1 }
        let total = pageYRange.values.reduce(Float(0)) { $0 + ($1.high - $1.low) }
        return max(total / Float(pageYRange.count), 1)
    }()

    // Bands are keyed on the baseline rounded to a tenth of a point, so runs
    // placed at 700.02 and 700.0 share one.
    var yBands: [PdfYBandKey: [Int]] = [:]
    for (index, line) in lines.enumerated() {
        let bucket = Int((line.y * 10).rounded(.toNearestOrAwayFromZero))
        yBands[PdfYBandKey(page: line.page, bucket: bucket), default: []].append(index)
    }

    /// The text a band contributes, which is its members' text in index
    /// order joined by spaces.
    func bandText(_ indices: [Int]) -> String {
        indices.sorted().map { pdfLineText(lines[$0]) }.joined(separator: " ")
    }

    /// Whether a normalised text is worth counting at all.
    func isCountable(_ normalized: String) -> Bool {
        // Bytes, as in the reference.
        normalized.utf8.count >= 10 && !pdfIsDecorativeSeparator(normalized)
    }

    var frequency: [String: Set<Int>] = [:]
    var yPositions: [String: [Float]] = [:]
    for line in lines where isYAtEdge(line.y, page: line.page) {
        let normalized = pdfNormalizeForComparison(pdfLineText(line))
        guard isCountable(normalized) else { continue }
        frequency[normalized, default: []].insert(line.page)
        yPositions[normalized, default: []].append(line.y)
    }

    // Bands of two or more members are counted separately on their combined
    // text: a column heading split into fragments that are each too short
    // still qualifies as a row.
    var bandFrequency: [String: Set<Int>] = [:]
    var bandYPositions: [String: [Float]] = [:]
    for (key, indices) in yBands where indices.count >= 2 {
        // The band's baseline is its *first-inserted* member's, not the
        // lowest — every member rounds to the same bucket, so they agree to
        // within the rounding.
        let bandY = lines[indices[0]].y
        guard isYAtEdge(bandY, page: key.page) else { continue }
        let normalized = pdfNormalizeForComparison(bandText(indices))
        guard isCountable(normalized) else { continue }
        bandFrequency[normalized, default: []].insert(key.page)
        bandYPositions[normalized, default: []].append(bandY)
    }

    // Integer division, so twenty pages need six occurrences and nineteen
    // need five — the bar steps rather than sliding.
    let threshold = max(3, pageCount * 30 / 100)

    /// Whether a text sits at the same height on every page it appears on.
    ///
    /// This is what separates a footer from a table cell that happens to
    /// land near the bottom margin. A single occurrence is always allowed.
    func hasConsistentY(_ text: String, in positions: [String: [Float]]) -> Bool {
        guard let values = positions[text], values.count >= 2 else { return true }
        let count = Float(values.count)
        let mean = values.reduce(0, +) / count
        // Population variance, dividing by n rather than n − 1.
        let variance = values.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / count
        return variance.squareRoot() / averageSpan < 0.05
    }

    func candidates(_ counts: [String: Set<Int>], _ positions: [String: [Float]]) -> Set<String> {
        var found: Set<String> = []
        for (text, pages) in counts
        where pages.count >= threshold && !pdfIsStructuralLine(text)
            && hasConsistentY(text, in: positions) {
            found.insert(text)
        }
        return found
    }

    let individualCandidates = candidates(frequency, yPositions)
    let bandCandidates = candidates(bandFrequency, bandYPositions)
    if individualCandidates.isEmpty && bandCandidates.isEmpty { return lines }

    var removal: Set<Int> = []

    // The first occurrence is kept, so a document title that also runs as a
    // header still appears once. **First in array order, not on the lowest
    // page** — the reference records the page of whichever line it reaches
    // first and never revises it, so lines fed out of page order keep a
    // later page's copy instead. The band pass below does take the minimum;
    // the two disagree, and both are reproduced.
    var firstPageIndividual: [String: Int] = [:]
    for (index, line) in lines.enumerated() where isYAtEdge(line.y, page: line.page) {
        let normalized = pdfNormalizeForComparison(pdfLineText(line))
        guard individualCandidates.contains(normalized) else { continue }
        let first = firstPageIndividual[normalized] ?? line.page
        firstPageIndividual[normalized] = first
        if line.page > first { removal.insert(index) }
    }

    var firstPageBand: [String: Int] = [:]
    for (key, indices) in yBands where indices.count >= 2 {
        let bandY = lines[indices[0]].y
        guard isYAtEdge(bandY, page: key.page) else { continue }
        let normalized = pdfNormalizeForComparison(bandText(indices))
        guard bandCandidates.contains(normalized) else { continue }
        firstPageBand[normalized] = min(firstPageBand[normalized] ?? key.page, key.page)
    }
    for (key, indices) in yBands where indices.count >= 2 {
        let bandY = lines[indices[0]].y
        guard isYAtEdge(bandY, page: key.page) else { continue }
        let normalized = pdfNormalizeForComparison(bandText(indices))
        guard bandCandidates.contains(normalized) else { continue }
        // Absent from the map means zero in the reference, which every real
        // page number exceeds.
        if key.page > (firstPageBand[normalized] ?? 0) { removal.formUnion(indices) }
    }

    // Sibling propagation, over *every* band including single-member ones:
    // one fragment of a split heading being removed takes the rest of its
    // row with it.
    for (key, indices) in yBands {
        let bandY = lines[indices[0]].y
        guard isYAtEdge(bandY, page: key.page) else { continue }
        if indices.contains(where: { removal.contains($0) }) { removal.formUnion(indices) }
    }

    if removal.isEmpty { return lines }
    return lines.enumerated().filter { !removal.contains($0.offset) }.map(\.element)
}

/// A page and a baseline rounded to a tenth of a point.
private struct PdfYBandKey: Hashable {
    var page: Int
    var bucket: Int
}
