import Testing

@testable import AnyDoc

/// The horizontal-rule primitives. The probe covers 1,512 generated segment
/// sets; these name each decision.
@Suite struct PdfTableRulesTests {
    private func rule(_ y: Float, _ xMin: Float, _ xMax: Float) -> PdfHorizontalRule {
        PdfHorizontalRule(y: y, xMin: xMin, xMax: xMax)
    }
    private func item(_ text: String, x: Float = 120, y: Float) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: 60, fontSize: 10, fontName: "F1")
    }

    /// A form strokes one segment per cell. They join across a small gap so
    /// the path endpoints do not become false column edges.
    @Test func touchingSegmentsJoinIntoOneRule() {
        let merged = pdfMergeHorizontalSegments([
            rule(700, 100, 200), rule(700, 205, 300), rule(700, 310, 400),
        ])
        // 5pt joins, 10pt does not.
        #expect(merged == [rule(700, 100, 300), rule(700, 310, 400)])
    }

    /// Grouping compares against the row's *first* rule, so slowly drifting
    /// baselines do not chain into one row.
    @Test func driftingBaselinesDoNotChain() {
        let merged = pdfMergeHorizontalSegments(
            (0..<5).map { rule(700 - Float($0) * 1.5, 100, 400) })
        #expect(merged.count > 1, "a 1.5pt drift must not collapse into one rule")
    }

    @Test func rulesSharingASpanGroupTogether() {
        let groups = pdfGroupRulesBySpan([
            rule(700, 100, 400), rule(660, 102, 399), rule(500, 200, 300),
        ])
        #expect(groups.count == 2)
        #expect(groups[0].count == 2)
    }

    @Test func numberedCaptionsAreRecognised() {
        for text in ["Table 3", "Table 12.", "table (4) x"] {
            #expect(pdfIsNumberedTableCaption(text), "\(text) should be a caption")
        }
        for text in ["Tables 3", "Table x", "Table", "A table 3"] {
            #expect(!pdfIsNumberedTableCaption(text), "\(text) should not be a caption")
        }
    }

    /// Two booktabs tables often share x endpoints. A numbered caption
    /// between them is an explicit separator.
    @Test func aCaptionSplitsTwoTables() {
        let rules = [
            rule(700, 100, 400), rule(660, 100, 400), rule(500, 100, 400), rule(460, 100, 400),
        ]
        let runs = pdfSplitIndependentRuleRuns(rules, items: [item("Table 2", y: 580)])
        #expect(runs.count == 2)
        #expect(runs[0].count == 2)
    }

    /// Failing a caption, a large empty band splits them — but the same band
    /// filled with text does not.
    @Test func anEmptyBandSplitsButAFullOneDoesNot() {
        let rules = [
            rule(700, 100, 400), rule(660, 100, 400), rule(500, 100, 400), rule(460, 100, 400),
        ]
        #expect(pdfSplitIndependentRuleRuns(rules, items: []).count == 2)

        let filled = (0..<9).map { item("row", y: 640 - Float($0) * 14) }
        #expect(pdfSplitIndependentRuleRuns(rules, items: filled).count == 1)
    }

    /// Both sides must keep two rules, which protects a long table whose
    /// top, middle and bottom rules straddle many text rows.
    @Test func aSplitNeedsTwoRulesEachSide() {
        let rules = [rule(700, 100, 400), rule(500, 100, 400), rule(460, 100, 400)]
        #expect(pdfSplitIndependentRuleRuns(rules, items: []).count == 1)
    }

    /// Ruled paper is evenly spaced to within two percent; a table's rows
    /// are not.
    @Test func uniformGridsAreDistinguished() {
        #expect(pdfRulesAreUniformGrid((0..<6).map { rule(700 - Float($0) * 20, 100, 400) }))
        let uneven = [700, 680, 659, 640, 618].map { rule(Float($0), 100, 400) }
        #expect(!pdfRulesAreUniformGrid(uneven))
        // Fewer than five rules is never a grid.
        #expect(!pdfRulesAreUniformGrid((0..<4).map { rule(700 - Float($0) * 20, 100, 400) }))
    }

    /// Segment endpoints that recur down the table are its columns; ragged
    /// ones are not.
    @Test func recurringEndpointsBecomeColumns() {
        let segmented = (0..<4).flatMap { row -> [PdfHorizontalRule] in
            let y = 700 - Float(row) * 20
            return [rule(y, 100, 200), rule(y, 205, 300), rule(y, 305, 400)]
        }
        let columns = try! #require(pdfDeriveColumnsFromHorizontalSegments(segmented))
        #expect(columns.count >= 3)

        let ragged = (0..<4).map { rule(700 - Float($0) * 20, 100 + Float($0) * 9, 400) }
        #expect(pdfDeriveColumnsFromHorizontalSegments(ragged) == nil)
    }

    /// Snapping measures from the last value *kept*, not from the previous
    /// value — so an evenly spaced chain does not collapse to one edge.
    @Test func snappingMeasuresFromTheLastKeptValue() {
        #expect(pdfSnapEdges([100, 102, 104, 106, 108], tolerance: 3) == [100, 104, 108])
        #expect(pdfSnapEdges([100, 110, 120], tolerance: 3) == [100, 110, 120])
        // Values genuinely within tolerance of the survivor do collapse.
        #expect(pdfSnapEdges([100, 101, 102], tolerance: 3) == [100])
    }
}
