import Testing

@testable import AnyDoc

/// Which lines a repetition proves are headings.
///
/// Every case here exercises the whole heading stack — numbering,
/// title-likeness, visual style, the sequence tests — so a divergence
/// anywhere beneath shows up as a wrong promotion.
@Suite struct PdfHeadingClassifyTests {

    private func line(
        _ y: Float, _ text: String, x: Float = 20, size: Float = 10, bold: Bool = false,
        font: String = "Body", page: Int = 1
    ) -> PdfTextLine {
        var item = PdfLayoutItem(
            text: text, x: x, y: y, width: 40, fontSize: size, fontName: font)
        item.isBold = bold
        return PdfTextLine(items: [item], y: y, page: page)
    }

    private func body(_ y: Float) -> PdfTextLine {
        line(y, "a long line of body text here")
    }

    private func classify(
        _ lines: [PdfTextLine], tiers: [Float] = [], excluded: Set<Int> = []
    ) -> [Int: Int] {
        pdfClassifyHeadingSequences(
            lines, bodySize: 10, tiers: tiers, excludedLines: excluded)
    }

    // MARK: - the numbered hierarchy

    /// `1.` and `1.1.` separated by `gap` lines.
    private func hierarchy(
        gap: Int = 4, second: String = "1.1. Method", size: Float = 12, font: String = "Head"
    ) -> [PdfTextLine] {
        var out = [line(760, "1. Introduction", size: size, bold: true, font: font)]
        var y: Float = 740
        for _ in 0..<max(gap - 1, 0) {
            out.append(body(y))
            y -= 14
        }
        out.append(line(y, second, size: size, bold: true, font: font))
        return out
    }

    @Test func aNumberedHierarchyPromotesBothItsLines() {
        let decisions = classify(hierarchy())
        #expect(decisions.count == 2)
        // The numbering's depth is the level.
        #expect(decisions[0] == 1)
        #expect(decisions[4] == 2)
    }

    @Test func adjacentNumbersAreAListNotAHierarchy() {
        // Genuine sections have body content between them.
        #expect(classify(hierarchy(gap: 2)).isEmpty)
        #expect(classify(hierarchy(gap: 3)).count == 2)
    }

    @Test func siblingsAreNotAHierarchy() {
        #expect(classify(hierarchy(second: "2. Method")).isEmpty)
        #expect(classify(hierarchy(second: "1.1.1. Deep")).count == 2)
    }

    @Test func theNumberingMustBeSetApartFromTheBody() {
        // Either by size — 1.05× the body — or by a bold face the body does
        // not use. Isolating the size bar means setting the headings in the
        // *body's* font, or the face alone carries them at any size.
        #expect(classify(hierarchy(size: 10.4, font: "Body")).isEmpty)
        #expect(classify(hierarchy(size: 10.5, font: "Body")).count == 2)
        // With a distinct face the size no longer matters.
        #expect(classify(hierarchy(size: 10.4, font: "Head")).count == 2)
    }

    // MARK: - the displaced sidebar

    /// Three small bold labels at a far indent, four body lines apart.
    private func sidebar(
        labels: [String] = ["Alpha", "Beta", "Gamma"], x: Float = 200, size: Float = 8
    ) -> [PdfTextLine] {
        var out: [PdfTextLine] = []
        var y: Float = 700
        var index = 0
        for _ in 0..<3 {
            for _ in 0..<4 {
                out.append(body(y))
                y -= 14
            }
            if index < labels.count {
                out.append(
                    line(y + 7, labels[index], x: x, size: size, bold: true, font: "Side"))
                index += 1
            }
        }
        return out
    }

    @Test func aDisplacedSidebarPromotesItsWholeGroup() {
        let decisions = classify(sidebar())
        #expect(decisions.count == 3)
        #expect(decisions.keys.sorted() == [4, 9, 14])
        // With no tiers, the bold fallback gives H2.
        #expect(decisions.values.allSatisfy { $0 == 2 })
    }

    @Test func theSidebarMustSitWellAwayFromTheBodyIndent() {
        // Four buckets of 24pt, so about a hundred points from the body.
        #expect(classify(sidebar(x: 20)).isEmpty)
        #expect(classify(sidebar(x: 100)).isEmpty)
        #expect(classify(sidebar(x: 200)).count == 3)
    }

    @Test func theSidebarMustBeSmallerThanTheBody() {
        // Under 0.95× — a label at body size is not a sidebar.
        #expect(classify(sidebar(size: 9.5)).isEmpty)
        #expect(classify(sidebar(size: 9.4)).count == 3)
    }

    @Test func aFixedSizeSidebarNeedsDistinctLabels() {
        // All one size *and* all one label is a repeated running header, not
        // a sequence of headings.
        #expect(classify(sidebar(labels: ["Alpha", "Alpha", "Alpha"])).isEmpty)
        #expect(classify(sidebar(labels: ["Alpha", "Alpha", "Beta"])).count == 3)
    }

    @Test func anIncompleteLabelDisqualifiesTheWholeGroup() {
        // One wrapped or dangling label and the sidebar evidence collapses.
        #expect(classify(sidebar(labels: ["Alpha with-", "Beta", "Gamma"])).isEmpty)
        #expect(classify(sidebar(labels: ["ends with the", "Beta", "Gamma"])).isEmpty)
    }

    // MARK: - the guards around both

    @Test func anExcludedLineCannotSupportASequence() {
        // Which is what stops table headers and list labels manufacturing
        // one. Excluding either end of a hierarchy dissolves it.
        #expect(classify(hierarchy()).count == 2)
        #expect(classify(hierarchy(), excluded: [0]).isEmpty)
        #expect(classify(hierarchy(), excluded: [4]).isEmpty)
    }

    @Test func aDocumentDenseWithCandidatesPromotesNothing() {
        // A "sequence" covering more than a fifth of the document is the
        // body text. Twelve candidates and nothing else exceeds the ceiling.
        let dense = (0..<12).map {
            line(700 - Float($0) * 14, "Alpha \($0)", x: 200, size: 8, bold: true, font: "Side")
        }
        #expect(classify(dense).isEmpty)
    }

    @Test func anEmptyOrPlainDocumentPromotesNothing() {
        #expect(classify([]).isEmpty)
        #expect(classify((0..<20).map { body(700 - Float($0) * 14) }).isEmpty)
    }

    @Test func tiersChangeTheLevelANonNumberedPromotionReceives() {
        // The sidebar's level comes from the bold fallback, which sits below
        // every size tier.
        #expect(classify(sidebar()).values.allSatisfy { $0 == 2 })
        #expect(classify(sidebar(), tiers: [24, 16]).values.allSatisfy { $0 == 3 })
        #expect(classify(sidebar(), tiers: [24, 16, 13, 11]).values.allSatisfy { $0 == 5 })
    }
}
