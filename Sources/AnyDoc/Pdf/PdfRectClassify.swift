/// Saying what a rectangle cluster *is*, ported from the classifiers in
/// pdf-inspector's `tables/detect_rects.rs`.
///
/// Not every cluster of drawn rectangles is a table, and the ways it can fail
/// to be one are specific enough to test for. A page background repeated
/// behind everything. A run of shaded bands with no vertical rules at all. A
/// bar chart, whose bars read as cell rectangles and would grid their own
/// axis labels into a phantom table.
///
/// These run before grid building and decide which strategy — if any — a
/// cluster should go to.

/// A page-scale rectangle repeated at least this many times is a background
/// the producer stamps behind every element, not a table cell.
private let pdfDominantBackgroundMinRepetitions = 8

/// Whether the rectangles are a row-stripe pattern: full-width shaded bands.
///
/// Alternating row shading produces rectangles that all share an x position
/// and width, so normal grid detection sees **two** x-edges and concludes
/// there is one column. The stripes still carry the row boundaries, though,
/// so recognising the pattern lets the columns be recovered from the text
/// instead.
func pdfIsRowStripePattern(
    _ rects: [(x: Float, y: Float, width: Float, height: Float)]
) -> Bool {
    guard rects.count >= 3 else { return false }

    let widths = rects.map(\.width).sorted()
    let median = widths[widths.count / 2]
    // A stripe spans the table; anything narrower is a cell.
    guard median > 200 else { return false }

    let alike = rects.count(where: { abs($0.width - median) <= median * 0.10 })
    return Float(alike) / Float(rects.count) > 0.75
}

/// Drop the page-background rectangles a producer stamps behind everything.
///
/// Only when there are *many* of them: one full-page rectangle is a legitimate
/// backdrop and harmless, but eight or more means the producer emits one per
/// element, and they would otherwise contribute page-boundary edges to every
/// grid on the page. Below the threshold the input is returned untouched.
func pdfWithoutDominantPageBackgrounds(
    _ rects: [(x: Float, y: Float, width: Float, height: Float)]
) -> [(x: Float, y: Float, width: Float, height: Float)] {
    let maxX = rects.map { $0.x + $0.width }.reduce(0, max)
    let maxY = rects.map { $0.y + $0.height }.reduce(0, max)
    func isPageScale(_ r: (x: Float, y: Float, width: Float, height: Float)) -> Bool {
        r.x < 5 && r.y < 5 && r.width >= maxX * 0.9 && r.height >= maxY * 0.9
    }
    guard rects.count(where: isPageScale) >= pdfDominantBackgroundMinRepetitions else {
        return rects
    }
    return rects.filter { !isPageScale($0) }
}

/// Whether the cluster is a bar chart rather than a table.
///
/// Bars drawn as filled rectangles look exactly like cell backgrounds, and
/// without this test a chart's axis labels get gridded into a phantom table.
/// The signature is a family of equal-*breadth* rectangles, standing in
/// separated columns, whose *length* varies because it encodes data — and
/// which contain only numbers, if anything.
///
/// The whole test runs twice with the axes swapped, which is what catches a
/// horizontal bar chart as well as a vertical one.
func pdfIsChartBarCluster(
    items: [PdfLayoutItem],
    groupRects: [(x: Float, y: Float, width: Float, height: Float)]
) -> Bool {
    /// Whether a rectangle holds only numeric labels, or nothing.
    ///
    /// Any number of figures inside a bar is chart-like; a single run of
    /// *words* means it is a table cell.
    func numericOrEmpty(_ rect: (x: Float, y: Float, width: Float, height: Float)) -> Bool {
        let inside = items.filter { item in
            let centreX = item.x + item.width / 2
            return centreX >= rect.x && centreX <= rect.x + rect.width && item.y >= rect.y
                && item.y <= rect.y + rect.height
        }
        return inside.allSatisfy { item in
            let text = item.text.rustTrim()
            if text.isEmpty { return true }
            let dataCharacters = text.unicodeScalars.count(where: {
                ($0 >= "0" && $0 <= "9") || $0 == "," || $0 == "." || $0 == "%" || $0 == "-"
            })
            return dataCharacters * 2 >= text.unicodeScalars.count
        }
    }

    /// One orientation of the test. `position` and `breadth` are the axis the
    /// bars are spaced along; `length` is the direction the data drives;
    /// `along` is where the bar starts.
    func barFamily(
        position: (Rect) -> Float, breadth: (Rect) -> Float,
        length: (Rect) -> Float, along: (Rect) -> Float
    ) -> Bool {
        groupRects.contains { anchor in
            let barBreadth = breadth(anchor)
            guard barBreadth > 0 else { return false }

            let family = groupRects.filter { rect in
                abs(breadth(rect) - barBreadth) <= max(barBreadth * 0.1, 2)
                    && length(rect) > 0 && length(rect) < barBreadth * 20
            }
            guard family.count >= 4 else { return false }

            // Distinct positions along the axis — the bar columns.
            var positions: [Float] = []
            for rect in family {
                let p = position(rect)
                if !positions.contains(where: { abs($0 - p) <= 2 }) { positions.append(p) }
            }
            guard positions.count >= 2 else { return false }
            positions.sort()

            // Bars stand apart; a table's cell rectangles touch.
            let minimumGap = zip(positions, positions.dropFirst())
                .map { $1 - $0 - barBreadth }.min() ?? .infinity
            guard minimumGap >= barBreadth * 0.5 else { return false }

            // Length has to vary, because it encodes data. A checkbox or
            // cell grid is uniform.
            let lengths = family.map(length)
            guard let shortest = lengths.min(), let longest = lengths.max(),
                longest >= shortest * 1.3
            else { return false }

            // A table's cells have same-extent partners in other columns,
            // because its rows are uniform. Chart segments start where the
            // previous datum ended, so they rarely pair up across positions.
            let matched = family.count(where: { rect in
                family.contains { other in
                    abs(position(other) - position(rect)) > 2
                        && abs(along(other) - along(rect)) <= 3
                        && abs(length(other) - length(rect)) <= 3
                }
            })
            guard matched * 5 < family.count * 3 else { return false }

            return family.count(where: numericOrEmpty) * 3 >= family.count * 2
        }
    }

    // Vertical bars, then the mirror for horizontal ones.
    return barFamily(position: { $0.x }, breadth: { $0.width }, length: { $0.height },
                     along: { $0.y })
        || barFamily(position: { $0.y }, breadth: { $0.height }, length: { $0.width },
                     along: { $0.x })
}

/// A drawn rectangle, named for readability inside the chart test.
private typealias Rect = (x: Float, y: Float, width: Float, height: Float)
