import Testing

@testable import AnyDoc

/// A single-column table from a vertical stack of framed rows.
@Suite struct PdfStackedBoxTests {
    private typealias Rect = (x: Float, y: Float, width: Float, height: Float)

    private func stack(_ count: Int, height: Float = 24, gap: Float = 2) -> [Rect] {
        var out: [Rect] = []
        for index in 0..<count {
            let y: Float = 700 - Float(index) * (height + gap)
            out.append((x: 100, y: y, width: 300, height: height))
        }
        return out
    }

    private func labels(_ boxes: [Rect], _ make: (Int) -> String) -> [PdfLayoutItem] {
        boxes.enumerated().map { index, box in
            PdfLayoutItem(
                text: make(index), x: 110, y: box.y + box.height / 2, width: 120,
                fontSize: 10, fontName: "F1")
        }
    }

    @Test func aFramedListBecomesASingleColumnTable() {
        let boxes = stack(5)
        let table = try! #require(
            pdfDetectStackedBoxTable(items: labels(boxes) { "Item \($0)" }, groupRects: boxes))
        #expect(table.columns.count == 1)
        #expect(table.rows.count == 5)
        #expect(table.cells[0] == ["Item 0"])
    }

    @Test func fewerThanThreeBoxesIsNotAStack() {
        let boxes = stack(2)
        #expect(pdfDetectStackedBoxTable(items: labels(boxes) { "x\($0)" }, groupRects: boxes)
            == nil)
    }

    /// A gap wider than a row means the boxes are unrelated.
    @Test func widelySeparatedBoxesAreNotAStack() {
        let boxes: [Rect] = [
            (x: 100, y: 700, width: 300, height: 24),
            (x: 100, y: 600, width: 300, height: 24),
            (x: 100, y: 500, width: 300, height: 24),
        ]
        #expect(pdfDetectStackedBoxTable(items: labels(boxes) { "g\($0)" }, groupRects: boxes)
            == nil)
    }

    /// Something beside a box at the same height means it is one column of a
    /// wider structure — that belongs to the grid strategies.
    @Test func flankedBoxesAreLeftToTheGridStrategies() {
        let boxes = stack(5)
        var items = labels(boxes) { "Item \($0)" }
        items += boxes.enumerated().map { index, box in
            PdfLayoutItem(
                text: "v\(index)", x: 460, y: box.y + box.height / 2, width: 60,
                fontSize: 10, fontName: "F1")
        }
        #expect(pdfDetectStackedBoxTable(items: items, groupRects: boxes) == nil)
    }

    /// Two runs on the same baseline in most boxes is multi-column content
    /// that must not collapse into one column.
    @Test func boxesHoldingTwoRunsAreRejected() {
        let boxes = stack(5)
        var items = labels(boxes) { "L\($0)" }
        items += boxes.enumerated().map { index, box in
            PdfLayoutItem(
                text: "R\(index)", x: 250, y: box.y + box.height / 2, width: 60,
                fontSize: 10, fontName: "F1")
        }
        #expect(pdfDetectStackedBoxTable(items: items, groupRects: boxes) == nil)
    }

    /// A sentence wrapping across boxes is prose behind stripes, not rows.
    @Test func wrappingProseIsRejected() {
        let boxes = stack(5)
        let lines = [
            "the quick brown fox jumps over the lazy dog and then,",
            "continues running for a while before it finally stops",
            "at the edge of the field where the fence has a gap in",
            "it that leads through to the neighbouring property and",
            "onwards to the road beyond the hill",
        ]
        let items = boxes.enumerated().map { index, box in
            PdfLayoutItem(
                text: lines[index], x: 110, y: box.y + box.height / 2, width: 250,
                fontSize: 10, fontName: "F1")
        }
        #expect(pdfDetectStackedBoxTable(items: items, groupRects: boxes) == nil)
    }

    /// Numbered items behind decorative stripes stay a list.
    @Test func numberedListsStayLists() {
        let boxes = stack(5)
        let items = labels(boxes) { "\($0 + 1)) something here" }
        #expect(pdfDetectStackedBoxTable(items: items, groupRects: boxes) == nil)
    }

    @Test func listMarkersAreRecognised() {
        for text in ["1) x", "(ii) x", "a. x", "12) x"] {
            #expect(pdfHasListMarker(text), "\(text) should read as a list item")
        }
        for text in ["Item 1", "x", "", "1234) too long"] {
            #expect(!pdfHasListMarker(text), "\(text) should not")
        }
    }
}
