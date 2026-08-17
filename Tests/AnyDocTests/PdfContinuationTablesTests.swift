import Testing

@testable import AnyDoc

/// Merging a table that runs across a page break.
///
/// `table-continuation.pdf` covers the happy path end to end — without the
/// merge it emits the header twice and the file stops matching. These pin
/// the four conditions that *prevent* a merge, none of which one document
/// can show, and each of which exists to stop a specific wrong join.
@Suite struct PdfContinuationTablesTests {
    private func table(_ markdown: String) -> [PdfPositionedMarkdown] {
        [PdfPositionedMarkdown(y: 700, x: 72, markdown: markdown, chartOrder: nil)]
    }

    private let first = "|Region|Total|\n|---|---|\n|R1|11|\n|R2|22|\n"
    private let second = "|Region|Total|\n|---|---|\n|R3|33|\n|R4|44|\n"

    @Test func consecutiveTableOnlyPagesMerge() {
        var pages = [1: table(first), 2: table(second)]
        pdfMergeContinuationTables(&pages, tableOnlyPages: [1, 2])
        #expect(pages.count == 1)
        #expect(pages[1]?[0].markdown == "|Region|Total|\n|---|---|\n|R1|11|\n|R2|22|\n|R3|33|\n|R4|44|\n")
    }

    /// A page with prose on it is not a continuation: the text between the
    /// two tables means the second starts something new.
    @Test func aPageWithProseDoesNotMerge() {
        var pages = [1: table(first), 2: table(second)]
        pdfMergeContinuationTables(&pages, tableOnlyPages: [1])
        #expect(pages.count == 2)
    }

    /// A gap in the page numbers ends the run — a table cannot continue
    /// across a page it skips.
    @Test func nonConsecutivePagesDoNotMerge() {
        var pages = [1: table(first), 3: table(second)]
        pdfMergeContinuationTables(&pages, tableOnlyPages: [1, 3])
        #expect(pages.count == 2)
    }

    /// A different column count is a different table.
    @Test func differentWidthsDoNotMerge() {
        var pages = [1: table(first), 2: table("|A|B|C|\n|---|---|---|\n|1|2|3|\n")]
        pdfMergeContinuationTables(&pages, tableOnlyPages: [1, 2])
        #expect(pages.count == 2)
    }

    /// Two tables on a page give no way to say which one continues.
    @Test func aPageWithTwoTablesDoesNotMerge() {
        var pages = [1: table(first), 2: table(second) + table(second)]
        pdfMergeContinuationTables(&pages, tableOnlyPages: [1, 2])
        #expect(pages.count == 2)
    }

    /// A run of three merges into one, and the scan resumes *after* it — a
    /// merged page has no table left to start a run of its own.
    @Test func aRunOfThreeMergesIntoOne() {
        let third = "|Region|Total|\n|---|---|\n|R5|55|\n"
        var pages = [1: table(first), 2: table(second), 3: table(third)]
        pdfMergeContinuationTables(&pages, tableOnlyPages: [1, 2, 3])
        #expect(pages.count == 1)
        #expect(pages[1]?[0].markdown.contains("|R5|55|") == true)
        // Three headers in, one header out.
        #expect(pages[1]?[0].markdown.components(separatedBy: "|Region|Total|").count == 2)
    }

    /// Something that is not a table at all — no separator row — is left
    /// alone rather than spliced.
    @Test func aNonTableIsNotMerged() {
        var pages = [1: table("just a line of text\n"), 2: table(second)]
        pdfMergeContinuationTables(&pages, tableOnlyPages: [1, 2])
        #expect(pages.count == 2)
        #expect(pdfCountTableColumns("just a line of text\n") == 0)
    }
}
