/// Scoping for the text-anchor strategy, ported from
/// `detect_text_anchor_rule_tables` and `line_overlaps_text_anchor_band` in
/// pdf-inspector's `tables/detect_lines.rs`.
///
/// Wave 37 built a table from a run of rules. This decides which runs are
/// allowed to be asked in the first place — and the answer is essentially
/// "only where the page is otherwise bare". Text-anchor inference is the
/// sparse-geometry fallback of last resort, so any sign that a better-informed
/// detector could own the region disqualifies it: dense line art, or vertical
/// strokes suggesting a real drawn grid.

/// A text-anchor table together with the band of page it claims.
///
/// The bounds are kept because later stages need to know what area the table
/// covers without re-deriving it — to drop path lines that fall inside it, and
/// to settle overlaps against competing hypotheses.
struct PdfTextAnchorBand {
    var table: PdfTable
    var xLeft: Float
    var xRight: Float
    var yBottom: Float
    var yTop: Float
}

/// Every text-anchor table on a page, each with its band.
///
/// Segments are merged into logical rules, grouped by span, and split where
/// two tables share endpoints — the same front end as the open-edge grid — and
/// each resulting run is then tested for whether the page around it is quiet
/// enough to trust anchors inferred from text alone.
func pdfDetectTextAnchorRuleTables(
    items: [PdfLayoutItem],
    horizontals: [PdfHorizontalRule],
    verticals: [PdfVerticalRule],
    pathLines: [PdfLineSegment]
) -> [PdfTextAnchorBand] {
    let logicalRules = pdfMergeHorizontalSegments(horizontals)
    var bands: [PdfTextAnchorBand] = []

    for spanGroup in pdfGroupRulesBySpan(logicalRules) {
        for rules in pdfSplitIndependentRuleRuns(spanGroup, items: items) {
            var yTop = -Float.infinity
            var yBottom = Float.infinity
            var xLeft = Float.infinity
            var xRight = -Float.infinity
            for rule in rules {
                yTop = max(yTop, rule.y)
                yBottom = min(yBottom, rule.y)
                xLeft = min(xLeft, rule.xMin)
                xRight = max(xRight, rule.xMax)
            }

            // Two hundred path lines crossing the band means a chart or a
            // schematic. The count stops at 200 rather than totalling them —
            // the question is only whether the threshold is reached.
            var crossingLines = 0
            for line in pathLines {
                guard max(line.x1, line.x2) >= xLeft - pdfRuleJoinGap,
                    min(line.x1, line.x2) <= xRight + pdfRuleJoinGap,
                    max(line.y1, line.y2) >= yBottom - pdfRuleYTolerance,
                    min(line.y1, line.y2) <= yTop + pdfRuleYTolerance
                else { continue }
                crossingLines += 1
                if crossingLines >= 200 { break }
            }
            if crossingLines >= 200 { continue }

            let bandVerticals = verticals.filter {
                $0.x >= xLeft - pdfRuleJoinGap && $0.x <= xRight + pdfRuleJoinGap
                    && $0.yMax >= yBottom - pdfRuleYTolerance
                    && $0.yMin <= yTop + pdfRuleYTolerance
            }
            let spanningXs = bandVerticals.filter {
                $0.yMin <= yBottom + pdfRuleYTolerance && $0.yMax >= yTop - pdfRuleYTolerance
            }.map(\.x)
            let bandXs = bandVerticals.map(\.x)

            // Two spanning coordinates can be the outer borders of an
            // otherwise borderless table, so they are allowed; a third means
            // an interior divider, and that is a physical grid. Separately,
            // six strokes of any length inside the band is diagram evidence
            // even though no single one proves a cell exists.
            if pdfSnapEdges(spanningXs, tolerance: 3).count >= 3
                || pdfSnapEdges(bandXs, tolerance: 3).count >= 6
            {
                continue
            }

            if let table = pdfBuildTextAnchorTable(items: items, rules: rules) {
                bands.append(
                    PdfTextAnchorBand(
                        table: table, xLeft: xLeft, xRight: xRight, yBottom: yBottom,
                        yTop: yTop))
            }
        }
    }

    // Down the page. Sorted stably, since the reference's sort is — bands
    // starting on the same baseline keep the order the span groups gave them.
    return bands.enumerated()
        .sorted {
            let left = $0.element.table.rows.first ?? 0
            let right = $1.element.table.rows.first ?? 0
            return left != right ? left > right : $0.offset < $1.offset
        }
        .map(\.element)
}

/// Whether a path line touches a band, loosened by the usual tolerances.
///
/// Used to drop the rules a text-anchor table has already accounted for, so
/// they cannot be counted twice as evidence by another detector.
func pdfLineOverlapsTextAnchorBand(_ line: PdfLineSegment, band: PdfTextAnchorBand) -> Bool {
    let lineXMin = min(line.x1, line.x2)
    let lineXMax = max(line.x1, line.x2)
    let lineYMin = min(line.y1, line.y2)
    let lineYMax = max(line.y1, line.y2)
    return lineXMax >= band.xLeft - pdfRuleJoinGap && lineXMin <= band.xRight + pdfRuleJoinGap
        && lineYMax >= band.yBottom - pdfRuleYTolerance
        && lineYMin <= band.yTop + pdfRuleYTolerance
}
