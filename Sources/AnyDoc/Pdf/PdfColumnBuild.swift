/// Turning candidate gutters into columns, ported from `extractor/layout.rs`
/// in pdf-inspector: `columns_have_prose` and `validate_and_build_columns`.
///
/// Wave 61 found the dips in the projection histogram. A dip is only a
/// *candidate*: a table's column separator, the gap beside a figure and the
/// space after a list's bullets all look identical to it. These two functions
/// are the arbiters — one asks whether what sits either side of a proposed
/// split actually reads like prose, the other checks that both sides carry
/// enough text over enough of the page's height to be columns at all.
///
/// Neither reports a failure. `validate_and_build_columns` always returns at
/// least one region, so a page that fails every test comes back as a single
/// full-width column and the caller carries on.

/// Whether every proposed column is filled with prose rather than a table.
///
/// Each column must independently pass, and the first failure ends the
/// question — so this is "all of them" rather than "most of them". The tests
/// are deliberately blunt, because the alternative being guarded against is a
/// table whose column separator produced a convincing gutter.
func pdfColumnsHaveProse(_ columns: [PdfColumnRegion], _ items: [PdfLayoutItem]) -> Bool {
    /// Baselines within this are the same line.
    let yTolerance: Float = 3
    /// A line must reach 45% across its column to count as full.
    let lineFillThreshold: Float = 0.45
    /// And 40% of lines must be full.
    let minimumProseRatio: Float = 0.40
    /// Fewer lines than this is not enough to judge from.
    let minimumLines = 8
    /// A narrow strip is a sidebar or a fragment, not a column.
    let minimumColumnWidth: Float = 120
    /// Prose runs one to three items per line; a table or form has one per
    /// cell and so many more.
    let maximumAverageItemsPerLine: Float = 3.5

    for column in columns {
        let columnWidth = column.xMax - column.xMin
        if columnWidth < minimumColumnWidth { return false }

        // Membership is by the item's *centre*, so a word overhanging the
        // gutter still belongs to the column it mostly sits in.
        let columnItems = items.filter { item in
            let centre = item.x + pdfEffectiveItemWidth(item) / 2
            return centre >= column.xMin && centre <= column.xMax
        }
        if columnItems.count < minimumLines { return false }

        // Descending y is top to bottom in PDF coordinates. Rust's `sort_by`
        // is stable and Swift's `sort` is not, so the original index breaks
        // ties — items sharing a baseline must keep their order, since the
        // line grouping below walks them in sequence.
        let sorted = columnItems.enumerated().sorted { left, right in
            if left.element.y != right.element.y { return left.element.y > right.element.y }
            return left.offset < right.offset
        }.map(\.element)

        var fullLines = 0
        var totalLines = 0
        var totalItemsInLines = 0
        var lineItems: [PdfLayoutItem] = []

        func flushLine() {
            if lineItems.isEmpty { return }
            totalLines += 1
            totalItemsInLines += lineItems.count
            // The span is clipped to the column, so an item reaching past
            // the gutter does not make the line look fuller than it is.
            var left = Float.infinity
            var right = -Float.infinity
            for item in lineItems {
                left = min(left, max(item.x, column.xMin))
                right = max(right, min(item.x + pdfEffectiveItemWidth(item), column.xMax))
            }
            let span = max(right - left, 0)
            if span >= columnWidth * lineFillThreshold { fullLines += 1 }
        }

        // A line is measured against the baseline of its *first* item, which
        // never moves as the line grows — so gradually drifting text does not
        // chain into one enormous line.
        var lineY = Float.nan
        for item in sorted {
            if lineItems.isEmpty || abs(lineY - item.y) < yTolerance {
                if lineItems.isEmpty { lineY = item.y }
                lineItems.append(item)
            } else {
                flushLine()
                lineItems.removeAll()
                lineY = item.y
                lineItems.append(item)
            }
        }
        flushLine()

        // Checked again after grouping: enough *items* does not mean enough
        // lines, since they may all share a baseline.
        if totalLines < minimumLines { return false }

        let ratio = Float(fullLines) / Float(totalLines)
        if ratio < minimumProseRatio { return false }
        let averageItems = Float(totalItemsInLines) / Float(totalLines)
        if averageItems > maximumAverageItemsPerLine { return false }
    }

    return true
}

/// Check each candidate gutter and build the columns that survive.
///
/// `centreAssign` chooses how an item is filed against a gutter: by its
/// midpoint, which suits justified text whose last word overhangs, or by its
/// edges, which is stricter. The edge test is deliberately asymmetric — an
/// item must end before the gutter to be left of it, and begin after it to be
/// right — so a straddling item is counted on neither side.
func pdfValidateAndBuildColumns(
    valleys: [(lower: Int, upper: Int)],
    items: [PdfLayoutItem],
    xMin: Float,
    binWidth: Float,
    xMax: Float,
    minimumItems: Int,
    minimumVerticalSpan: Float,
    centreAssign: Bool
) -> [PdfColumnRegion] {
    // The page's vertical extent is measured from *narrow* items only — the
    // same ones the histogram counted. A full-width caption or title would
    // otherwise stretch the range and sink the overlap ratio for columns
    // that legitimately occupy only part of the page, such as two columns of
    // text below a figure.
    var itemsRight = -Float.infinity
    var itemsLeft = Float.infinity
    for item in items {
        itemsRight = max(itemsRight, item.x + pdfEffectiveItemWidth(item))
        itemsLeft = min(itemsLeft, item.x)
    }
    let xSpan = itemsRight - itemsLeft
    let narrow = items.filter { pdfEffectiveItemWidth($0) <= xSpan * 0.6 }

    // With no narrow items the folds run over nothing, leaving the range
    // negatively infinite — which the `> 0` test below then skips. That is
    // the reference's behaviour and not an accident worth repairing here.
    var yMin = Float.infinity
    var yMax = -Float.infinity
    for item in narrow {
        yMin = min(yMin, item.y)
        yMax = max(yMax, item.y)
    }
    let yRange = yMax - yMin

    // (lower, upper, left count, right count)
    var validValleys: [(lower: Int, upper: Int, left: Int, right: Int)] = []
    for valley in valleys {
        let gutterLeft = xMin + Float(valley.lower) * binWidth
        let gutterRight = xMin + Float(valley.upper) * binWidth
        let gutterCentre = (gutterLeft + gutterRight) / 2

        let leftItems = items.filter { item in
            centreAssign
                ? item.x + pdfEffectiveItemWidth(item) / 2 <= gutterCentre
                : item.x + pdfEffectiveItemWidth(item) <= gutterCentre
        }
        let rightItems = items.filter { item in
            centreAssign
                ? item.x + pdfEffectiveItemWidth(item) / 2 > gutterCentre
                : item.x >= gutterCentre
        }

        // A symmetric layout needs the full count on both sides; a sidebar
        // is accepted when the dominant side has it and the smaller side has
        // at least three items.
        let leftIsSmaller = leftItems.count <= rightItems.count
        let smaller = leftIsSmaller ? leftItems.count : rightItems.count
        let larger = leftIsSmaller ? rightItems.count : leftItems.count
        if larger < minimumItems || smaller < 3 { continue }

        // A list sets its bullets on the margin and its text further in,
        // which reads as a gutter. The smaller side is the bullets.
        if pdfIsListMarkerColumn(leftIsSmaller ? leftItems : rightItems) { continue }

        // Two columns run alongside each other. Text above a figure and text
        // below it do not, however convincing the gap between them looks.
        if yRange > 0 {
            var leftYMin = Float.infinity
            var leftYMax = -Float.infinity
            for item in leftItems {
                leftYMin = min(leftYMin, item.y)
                leftYMax = max(leftYMax, item.y)
            }
            var rightYMin = Float.infinity
            var rightYMax = -Float.infinity
            for item in rightItems {
                rightYMin = min(rightYMin, item.y)
                rightYMax = max(rightYMax, item.y)
            }
            let overlap = max(min(leftYMax, rightYMax) - max(leftYMin, rightYMin), 0)
            if overlap / yRange < minimumVerticalSpan { continue }
        }

        validValleys.append((valley.lower, valley.upper, leftItems.count, rightItems.count))
    }

    // Nothing survived: the page is one column, which is also what a page
    // with no candidate gutters at all comes back as.
    if validValleys.isEmpty { return [PdfColumnRegion(xMin: xMin, xMax: xMax)] }

    // At most three gutters, so four columns. A wide gutter with plenty of
    // text on its thinner side scores best, which prefers a real column
    // break over a chance alignment.
    if validValleys.count > 3 {
        func score(_ valley: (lower: Int, upper: Int, left: Int, right: Int)) -> Float {
            Float(valley.upper - valley.lower) * Float(min(valley.left, valley.right))
        }
        validValleys = validValleys.enumerated().sorted { left, right in
            let a = score(left.element)
            let b = score(right.element)
            // Both sorts are stable in the reference, so equal scores keep
            // the order they were found in.
            if a != b { return b < a }
            return left.offset < right.offset
        }.map(\.element)
        validValleys.removeLast(validValleys.count - 3)
        validValleys = validValleys.enumerated().sorted { left, right in
            if left.element.lower != right.element.lower {
                return left.element.lower < right.element.lower
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    // The columns are the spaces between the gutter centres, with the first
    // running from the page's left edge and the last to its right.
    var columns: [PdfColumnRegion] = []
    var start = xMin
    for valley in validValleys {
        let centre = xMin + (Float(valley.lower + valley.upper) / 2) * binWidth
        columns.append(PdfColumnRegion(xMin: start, xMax: centre))
        start = centre
    }
    columns.append(PdfColumnRegion(xMin: start, xMax: xMax))
    return columns
}
