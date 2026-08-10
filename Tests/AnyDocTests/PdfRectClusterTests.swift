import Testing

@testable import AnyDoc

/// Clustering drawn rectangles into candidate tables.
@Suite struct PdfRectClusterTests {
    private typealias Rect = (x: Float, y: Float, width: Float, height: Float)

    private func grid(rows: Int, columns: Int, cellW: Float = 50, cellH: Float = 20) -> [Rect] {
        var cells: [Rect] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x: Float = 100 + Float(column) * cellW
                let y: Float = 700 - Float(row) * cellH
                cells.append((x: x, y: y, width: cellW, height: cellH))
            }
        }
        return cells
    }

    /// Abutting cell borders touch rather than overlap, which is what the
    /// tolerance is for.
    @Test func abuttingCellsClusterTogether() {
        let cells = grid(rows: 4, columns: 4)
        let groups = pdfClusterRects(cells, tolerance: 2, minimumSize: 4)
        #expect(groups.count == 1)
        #expect(groups[0].count == 16)
    }

    /// Cells spaced further apart than the tolerance do not connect.
    @Test func separatedCellsDoNotCluster() {
        var spread: [Rect] = []
        for row in 0..<4 {
            for column in 0..<4 {
                let x: Float = 100 + Float(column) * 60
                let y: Float = 700 - Float(row) * 30
                spread.append((x: x, y: y, width: 50, height: 20))
            }
        }
        #expect(pdfClusterRects(spread, tolerance: 1, minimumSize: 4).isEmpty)
    }

    /// A border drawn around the cells joins everything into one component.
    @Test func anEnclosingBorderUnifiesTheCluster() {
        let rects: [Rect] = [
            (100, 700, 200, 80), (110, 710, 50, 20), (170, 710, 50, 20),
        ]
        #expect(pdfClusterRects(rects, tolerance: 2, minimumSize: 2)[0].count == 3)
    }

    @Test func smallGroupsAreDropped() {
        let rects: [Rect] = [(100, 700, 50, 20), (150, 700, 50, 20), (400, 400, 10, 10)]
        let groups = pdfClusterRects(rects, tolerance: 2, minimumSize: 2)
        #expect(groups.count == 1)
        #expect(groups[0] == [0, 1])
    }

    /// Groups come back ordered by root index, which is what makes the
    /// output stable rather than dictionary-ordered.
    @Test func groupOrderIsDeterministic() {
        let rects: [Rect] = [
            (100, 700, 50, 20), (150, 700, 50, 20),
            (400, 700, 50, 20), (450, 700, 50, 20),
        ]
        let first = pdfClusterRects(rects, tolerance: 2, minimumSize: 2)
        for _ in 0..<10 {
            #expect(pdfClusterRects(rects, tolerance: 2, minimumSize: 2) == first)
        }
        #expect(first == [[0, 1], [2, 3]])
    }

    @Test func overlapIsTestedAfterGrowingBothSides() {
        let a: Rect = (100, 700, 50, 20)
        let b: Rect = (152, 700, 50, 20)
        #expect(!pdfRectsOverlap(a, b, tolerance: 0))
        // 1pt each side closes a 2pt gap.
        #expect(pdfRectsOverlap(a, b, tolerance: 1))
    }

    // MARK: splitting

    /// Two tables side by side cluster together when their borders abut;
    /// the split finds the empty column band between them.
    @Test func aWideGapSplitsTheCluster() {
        let rects: [Rect] = [
            (100, 700, 50, 20), (150, 700, 50, 20),
            (300, 700, 50, 20), (350, 700, 50, 20),
        ]
        let split = try! #require(pdfSplitWideCluster(rects, minimumGap: 40, minimumGroupSize: 2))
        #expect(split.left.count == 2)
        #expect(split.right.count == 2)
    }

    @Test func anarrowGapDoesNotSplit() {
        let rects: [Rect] = [(100, 700, 50, 20), (160, 700, 50, 20)]
        #expect(pdfSplitWideCluster(rects, minimumGap: 200, minimumGroupSize: 2) == nil)
    }

    /// Both halves must be substantial, or the "split" is just a stray
    /// rectangle beside a table.
    @Test func aLopsidedSplitIsRejected() {
        let rects: [Rect] = [
            (100, 700, 20, 20), (300, 700, 20, 20), (330, 700, 20, 20), (360, 700, 20, 20),
        ]
        #expect(pdfSplitWideCluster(rects, minimumGap: 40, minimumGroupSize: 3) == nil)
    }
}
