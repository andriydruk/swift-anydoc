import Testing

@testable import AnyDoc

/// Deciding whether a rectangle cluster is really a grid.
@Suite struct PdfRectGridTests {
    private typealias Rect = (x: Float, y: Float, width: Float, height: Float)

    private func cells(rows: Int, columns: Int, cw: Float = 60, ch: Float = 20) -> [Rect] {
        var out: [Rect] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x: Float = 100 + Float(column) * cw
                let y: Float = 700 - Float(row) * ch
                out.append((x: x, y: y, width: cw, height: ch))
            }
        }
        return out
    }

    private func text(rows: Int, columns: Int, cw: Float = 60, ch: Float = 20) -> [PdfLayoutItem] {
        var out: [PdfLayoutItem] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x: Float = 100 + Float(column) * cw + 10
                let y: Float = 700 - Float(row) * ch + 5
                out.append(
                    PdfLayoutItem(
                        text: "v\(row)\(column)", x: x, y: y, width: 30, fontSize: 10,
                        fontName: "F1"))
            }
        }
        return out
    }

    private func build(
        _ rects: [Rect], _ items: [PdfLayoutItem], skips: [Bool]? = nil, strict: Bool = false
    ) -> PdfGridResult {
        pdfTryBuildGrid(
            items: items, groupRects: rects,
            skipRects: skips ?? [Bool](repeating: false, count: rects.count), strict: strict)
    }

    @Test func aWellFormedClusterBecomesATable() {
        guard case .ok(let table) = build(cells(rows: 3, columns: 3), text(rows: 3, columns: 3))
        else { return #expect(Bool(false), "expected a table") }
        #expect(table.columns.count == 3)
        #expect(table.rows.count == 3)
        #expect(table.cells[0] == ["v00", "v01", "v02"])
    }

    /// Three column edges give two columns; the row bar is higher, because
    /// two rows of ruling is as often a header underline as a table.
    @Test func tooFewEdgesIsNotAGrid() {
        #expect(build(cells(rows: 1, columns: 2), text(rows: 1, columns: 2)) == .failed)
    }

    /// A drawn grid with almost no text is *structurally* fine — the
    /// rectangles cover their cells — so it comes back as `.fewNonEmptyRows`
    /// rather than `.failed`. The caller can retry; a structural failure
    /// cannot be retried, which is why the two verdicts are distinct.
    @Test func aDrawnGridWithoutTextIsRetryable() {
        let drawn = cells(rows: 4, columns: 3)
        #expect(build(drawn, text(rows: 1, columns: 1)) == .fewNonEmptyRows)
    }

    /// Rectangles must actually cover the cells their edges imply. Edges far
    /// apart with only a few small rectangles between them fail outright.
    @Test func edgesWithoutCoveringRectsAreRejected() {
        let scattered: [Rect] = [
            (x: 100, y: 700, width: 10, height: 10),
            (x: 300, y: 700, width: 10, height: 10),
            (x: 100, y: 600, width: 10, height: 10),
            (x: 300, y: 600, width: 10, height: 10),
            (x: 200, y: 650, width: 10, height: 10),
        ]
        #expect(build(scattered, text(rows: 2, columns: 2)) == .failed)
    }

    /// A form's scattered field boxes make a huge grid, so the column count
    /// is capped — high enough for a real statistical table.
    @Test func tooManyColumnsIsRejected() {
        let wide = cells(rows: 3, columns: 28, cw: 20)
        #expect(build(wide, text(rows: 3, columns: 28, cw: 20)) == .failed)
    }

    /// A page background contributes page-boundary column edges, which would
    /// manufacture empty margin columns — hence the skip flags.
    @Test func skippedRectsDoNotContributeColumnEdges() {
        var rects: [Rect] = [(x: 50, y: 400, width: 500, height: 340)]
        rects += cells(rows: 3, columns: 3)
        var skips = [Bool](repeating: false, count: rects.count)
        skips[0] = true
        guard case .ok(let table) = build(rects, text(rows: 3, columns: 3), skips: skips) else {
            return #expect(Bool(false), "expected a table")
        }
        #expect(table.columns.count == 3, "the background must not add margin columns")
    }

    /// Strict mode rejects a paragraph swept into a cell; loose mode does not.
    @Test func strictModeRejectsParagraphText() {
        let rects = cells(rows: 3, columns: 3)
        var items = text(rows: 3, columns: 3)
        items.append(
            PdfLayoutItem(
                text: String(repeating: "x", count: 240), x: 110, y: 665, width: 30,
                fontSize: 10, fontName: "F1"))
        #expect(build(rects, items, strict: true) == .failed)
        if case .failed = build(rects, items, strict: false) {
            #expect(Bool(false), "loose mode should still accept it")
        }
    }

    /// A rectangle spanning several rows is a merged cell: its text gathers
    /// into the first sub-row so the formatter can collapse the group.
    @Test func mergedCellsGatherIntoTheirFirstRow() {
        var cells: [[String]] = [["label", "a"], ["", "b"], ["", "c"]]
        let spanning: [Rect] = [(x: 100, y: 640, width: 60, height: 60)]
        pdfPropagateMergedCells(
            &cells, columnEdges: [100, 160, 220], rowEdges: [700, 680, 660, 640],
            groupRects: spanning, skipRects: [false])
        #expect(cells[0][0] == "label")
        #expect(cells[1][0].isEmpty)
    }

    /// The span test demands real overlap, not tolerance slack: a rectangle
    /// whose top merely meets a row's bottom lies entirely below it, and
    /// treating that as a span cascades unrelated rows together.
    @Test func touchingRowsAreNotSpanned() {
        var cells: [[String]] = [["one", "a"], ["two", "b"]]
        // Sits exactly below the first row, touching its bottom edge.
        let touching: [Rect] = [(x: 100, y: 660, width: 60, height: 20)]
        pdfPropagateMergedCells(
            &cells, columnEdges: [100, 160, 220], rowEdges: [700, 680, 660],
            groupRects: touching, skipRects: [false])
        #expect(cells == [["one", "a"], ["two", "b"]], "no merge should have happened")
    }
}
