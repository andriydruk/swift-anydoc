import Testing

@testable import AnyDoc

/// The parallel-prose rejection.
///
/// **No corpus document reaches this yet.** Its precondition is a page with
/// exactly one chart region spanning a two-column prose split, *and* a
/// heuristic candidate whose cells satisfy seven interacting conditions.
/// Building that document is its own wave; these test the predicate
/// directly, which is where all the judgement lives.
///
/// Each negative case removes exactly one signal from the positive one, so a
/// condition dropped from the port fails a named test rather than quietly
/// widening the rejection — which would delete real tables from chart pages.
@Suite struct PdfParallelProseTests {
    /// Two independent prose columns projected onto a grid: long sentences
    /// in both columns, broken across rows, with holes where the columns
    /// break asynchronously.
    private func parallelProse() -> PdfTable {
        PdfTable(
            columns: [72, 320],
            rows: [700, 680, 660, 640],
            cells: [
                [
                    "The first paragraph of the left column begins here and",
                    "Meanwhile the right column pursues an entirely separate",
                ],
                [
                    "continues across the row boundary without any full stop",
                    "argument that has nothing to do with the left one and",
                ],
                [
                    "before finally reaching its conclusion on this line.",
                    "carries on regardless of where the left column breaks",
                ],
                ["", "which is the asynchrony that betrays the layout."],
            ])
    }

    @Test func twoProseColumnsAreRejected() {
        #expect(pdfIsParallelProseTable(parallelProse()))
    }

    /// A header of short filled cells makes it a real table, however wordy
    /// the body. This is the guard that keeps a genuine table on a chart
    /// page.
    @Test func aCompactHeaderSavesTheCandidate() {
        var table = parallelProse()
        table.cells.insert(["Region", "Commentary"], at: 0)
        table.rows.insert(720, at: 0)
        #expect(!pdfIsParallelProseTable(table))
    }

    /// A fully populated grid is positive evidence for a real table:
    /// independent columns break asynchronously and leave holes.
    @Test func aCompleteGridIsNotParallelProse() {
        var table = parallelProse()
        table.cells[3][0] = "and the left column also fills its final row here completely."
        #expect(!pdfIsParallelProseTable(table))
    }

    /// Without sentences broken across rows there is no continuation
    /// evidence, and a lowercase cell alone proves nothing — headerless
    /// tables use sentence fragments as values all the time.
    @Test func selfContainedCellsAreNotContinuations() {
        var table = parallelProse()
        for row in table.cells.indices {
            for column in table.cells[row].indices where !table.cells[row][column].isEmpty {
                table.cells[row][column] = table.cells[row][column] + "."
            }
        }
        #expect(!pdfIsParallelProseTable(table))
    }

    /// Four columns is not the shape two prose columns project onto.
    @Test func aWideGridIsOutOfScope() {
        var table = parallelProse()
        table.columns = [72, 200, 320, 450]
        #expect(!pdfIsParallelProseTable(table))
    }

    /// Short values are not prose, however many rows there are.
    @Test func aTableOfShortValuesIsKept() {
        let table = PdfTable(
            columns: [72, 320],
            rows: [700, 680, 660],
            cells: [["North", "1,240"], ["South", "980"], ["East", "1,505"]])
        #expect(!pdfIsParallelProseTable(table))
    }

    /// Fewer than three rows cannot show a continuation pattern at all.
    @Test func aTwoRowCandidateIsOutOfScope() {
        var table = parallelProse()
        table.cells = Array(table.cells.prefix(2))
        table.rows = Array(table.rows.prefix(2))
        #expect(!pdfIsParallelProseTable(table))
    }
}
