import Testing

@testable import AnyDoc

/// Underlines cleared inside ruled tables.
@Suite struct PdfTableUnderlineTests {
    private func item(_ text: String, x: Float, y: Float, underlined: Bool = true)
        -> PdfLayoutItem
    {
        var value = PdfLayoutItem(
            text: text, x: x, y: y, width: 40, fontSize: 10, fontName: "F1")
        value.isUnderline = underlined
        return value
    }

    private func table(cells: [[String]], indices: [Int] = []) -> PdfTable {
        PdfTable(cells: cells, itemIndices: indices)
    }

    @Test func aGridOfShortValuesIsPlausible() {
        #expect(pdfTableIsPlausible(table(cells: [["a", "b"], ["1", "2"]])))
    }

    @Test func aGridOfProseIsNot() {
        // A cell holding a paragraph means the detector captured flowing
        // text, not a data table — the reference's note records a 4×8 grid
        // claiming every item on a prose page.
        let paragraph = String(repeating: "x", count: 101)
        #expect(!pdfTableIsPlausible(table(cells: [[paragraph, paragraph]])))
    }

    @Test func theProseBarIsThirtyPercentOfNonEmptyCells() {
        let long = String(repeating: "x", count: 101)
        // Three long of ten is 30% — not *under* the bar, so not plausible.
        var cells = Array(repeating: "short", count: 7)
        cells.append(contentsOf: Array(repeating: long, count: 3))
        #expect(!pdfTableIsPlausible(table(cells: [cells])))
        // Two of ten is 20% and survives.
        var fewer = Array(repeating: "short", count: 8)
        fewer.append(contentsOf: Array(repeating: long, count: 2))
        #expect(pdfTableIsPlausible(table(cells: [fewer])))
    }

    @Test func exactlyAHundredCharactersIsShort() {
        // The test is `> 100`, so a hundred-character cell is still a value.
        #expect(pdfTableIsPlausible(table(cells: [[String(repeating: "x", count: 100)]])))
        #expect(!pdfTableIsPlausible(table(cells: [[String(repeating: "x", count: 101)]])))
    }

    @Test func aTableWithNoContentIsNotPlausible() {
        #expect(!pdfTableIsPlausible(table(cells: [])))
        #expect(!pdfTableIsPlausible(table(cells: [["", "   "]])))
    }

    @Test func aPageWithNoDecorationCostsNothing() {
        // The early return matters: both detectors are expensive, and a page
        // with no underline anywhere must not pay for them.
        var items = [item("a", x: 10, y: 100, underlined: false)]
        let before = items
        pdfSuppressTableUnderlines(&items, rects: [], lines: [])
        #expect(items.map(\.isUnderline) == before.map(\.isUnderline))
    }

    @Test func underlinesSurviveWhenNoTableIsFound() {
        var items = [item("underlined text", x: 10, y: 100)]
        pdfSuppressTableUnderlines(&items, rects: [], lines: [])
        #expect(items[0].isUnderline)
    }
}
