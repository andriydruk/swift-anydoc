import Testing

@testable import AnyDoc

/// Underline and strikeout detection. The differential probe checks whole
/// PDFs; these pin the individual decisions, above all the ones that keep a
/// table ruling from being read as an underline.
@Suite struct PdfUnderlineTests {
    private func item(
        _ text: String, x: Float, y: Float, width: Float, size: Float = 12
    ) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: size, fontName: "F1")
    }
    private func rule(_ x1: Float, _ x2: Float, _ y: Float) -> PdfLineSegment {
        PdfLineSegment(x1: x1, y1: y, x2: x2, y2: y, strokeWidth: 0.5)
    }

    @Test func aRuleBelowTheBaselineUnderlines() {
        var items = [item("underlined", x: 100, y: 700, width: 120)]
        pdfMarkUnderlines(&items, rectangles: [], lines: [rule(100, 220, 697)])
        #expect(items[0].isUnderline)
        #expect(!items[0].isStrikeout)
    }

    @Test func aRuleThroughTheGlyphsStrikesOut() {
        var items = [item("struck", x: 100, y: 700, width: 120)]
        pdfMarkUnderlines(&items, rectangles: [], lines: [rule(100, 220, 704)])
        #expect(items[0].isStrikeout)
        #expect(!items[0].isUnderline)
    }

    /// A thin filled rectangle is an underline as much as a stroke is, and
    /// its extents are normalised so a flipped transform still works.
    @Test func aThinRectangleUnderlinesEvenWhenFlipped() {
        var items = [item("underlined", x: 100, y: 700, width: 120)]
        pdfMarkUnderlines(
            &items, rectangles: [PdfRect(x: 220, y: 697, width: -120, height: 1)], lines: [])
        #expect(items[0].isUnderline)
    }

    @Test func aThickBandIsNotARule() {
        var items = [item("banner", x: 100, y: 700, width: 120)]
        pdfMarkUnderlines(
            &items, rectangles: [PdfRect(x: 100, y: 694, width: 120, height: 6)], lines: [])
        #expect(!items[0].isUnderline)
    }

    /// A rule covering less than sixty percent of an item's width does not
    /// decorate it.
    @Test func aRuleMustCoverMostOfTheItem() {
        var items = [item("wide text", x: 100, y: 700, width: 200)]
        pdfMarkUnderlines(&items, rectangles: [], lines: [rule(100, 150, 697)])
        #expect(!items[0].isUnderline)
    }

    /// Full-width rules repeating down the page are table rulings: each
    /// overshoots its row's text, so none is snugly owned.
    @Test func repeatedFullWidthRulesAreRulings() {
        var items = (0..<4).map { row in
            item("row", x: 100, y: 700 - Float(row) * 40, width: 40)
        }
        let lines = (0..<4).map { row in rule(100, 500, 694 - Float(row) * 40) }
        pdfMarkUnderlines(&items, rectangles: [], lines: lines)
        #expect(items.allSatisfy { !$0.isUnderline })
    }

    /// A document that underlines many full-width lines looks like a ruled
    /// table to the repetition test, so snug ownership rescues it.
    @Test func snugOwnershipRescuesRepeatedUnderlines() {
        var items = (0..<4).map { row in
            item("a fully underlined line", x: 100, y: 700 - Float(row) * 40, width: 200)
        }
        let lines = (0..<4).map { row in rule(100, 300, 697 - Float(row) * 40) }
        pdfMarkUnderlines(&items, rectangles: [], lines: lines)
        #expect(items.allSatisfy { $0.isUnderline })
    }

    /// Separated segments on one row are per-column header separators, and
    /// that verdict beats snugness — each segment does snugly own its label.
    @Test func segmentedRowRulesAreAlwaysRulings() {
        var items = [
            item("alpha", x: 100, y: 700, width: 40),
            item("beta", x: 200, y: 700, width: 30),
            item("gamma", x: 300, y: 700, width: 45),
        ]
        let lines = [rule(100, 140, 694), rule(200, 230, 694), rule(300, 345, 694)]
        pdfMarkUnderlines(&items, rectangles: [], lines: lines)
        #expect(items.allSatisfy { !$0.isUnderline })
    }

    /// Vertical strokes rising from a rule's ends make it a box border.
    @Test func flankingVerticalsVetoAnUnderline() {
        var items = (0..<3).map { row in
            item("cell text here", x: 100, y: 700 - Float(row) * 40, width: 200)
        }
        var lines = (0..<3).map { row in rule(100, 300, 697 - Float(row) * 40) }
        // Verticals at both ends of the first rule's row.
        lines.append(PdfLineSegment(x1: 100, y1: 690, x2: 100, y2: 710, strokeWidth: 0.5))
        lines.append(PdfLineSegment(x1: 300, y1: 690, x2: 300, y2: 710, strokeWidth: 0.5))
        pdfMarkUnderlines(&items, rectangles: [], lines: lines)
        #expect(!items[0].isUnderline)
    }

    /// A narrow bar with a denominator hugging it below is a fraction.
    @Test func fractionBarsDoNotUnderline() {
        var items = [
            item("12", x: 100, y: 700, width: 18),
            item("34", x: 100, y: 683, width: 18),
        ]
        pdfMarkUnderlines(&items, rectangles: [], lines: [rule(100, 118, 696)])
        #expect(!items[0].isUnderline)
    }

    /// One rule under several items with column-sized gaps is a header
    /// separator, not an underline of any of them.
    @Test func aRuleSpanningColumnsIsATabularSeparator() {
        var items = [
            item("alpha", x: 100, y: 700, width: 40),
            item("beta", x: 250, y: 700, width: 30),
            item("gamma", x: 400, y: 700, width: 45),
        ]
        pdfMarkUnderlines(&items, rectangles: [], lines: [rule(100, 445, 694)])
        #expect(items.allSatisfy { !$0.isUnderline })
    }

    @Test func onlyPaintedInkCounts() {
        var graphics = PdfPageGraphics()
        graphics.paintedRectangles = [PdfRect(x: 100, y: 697, width: 120, height: 1)]
        graphics.clipRectangles = [PdfRect(x: 100, y: 657, width: 120, height: 1)]
        graphics.filledRectangles = [PdfRect(x: 100, y: 617, width: 120, height: 1)]
        let ink = pdfUnderlineInk(graphics)
        #expect(ink.count == 2, "clip-only rectangles draw nothing and must not be ink")
    }
}
