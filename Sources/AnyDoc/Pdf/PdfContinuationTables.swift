/// Merging a table that runs across a page break, ported from
/// `merge_continuation_tables` in `markdown/convert.rs`.
///
/// A long table in a report is one table to its reader and several to the
/// extractor: each page carries a copy of the header, and the rows below it
/// arrive as a separate grid. Emitted that way the Markdown holds three
/// tables where the document has one, and the repeated header rows read as
/// data to anything consuming it.
///
/// **The conditions are strict, and each one prevents a specific wrong
/// merge.** Consecutive page numbers, because a table cannot continue across
/// a page it skips. Exactly one table per page, because two tables on a page
/// give no way to say which continues. The same column count, because a
/// different width is a different table. And every page involved must be
/// **table-only** — no prose at all — since text between two tables means
/// the second starts a new thought rather than continuing the first.

/// `pdfCountTableColumns` lives in `PdfMergeBoldHeadings.swift`, which
/// needed it first. It reads the separator row through `rustLines()` — Rust's
/// `.lines()`, which drops a trailing empty line where Swift's `split` keeps
/// one, and that difference decides the count on a table ending in a newline.

/// Merge each run of continuation tables into the first page's table.
///
/// - Parameters:
///   - pageTables: the per-page rendered tables, modified in place. A page
///     whose table is absorbed is removed entirely.
///   - tableOnlyPages: pages carrying a table and no prose.
func pdfMergeContinuationTables(
    _ pageTables: inout [Int: [PdfPositionedMarkdown]], tableOnlyPages: Set<Int>
) {
    let sortedPages = pageTables.keys.sorted()
    guard sortedPages.count >= 2 else { return }

    var index = 0
    while index < sortedPages.count {
        let firstPage = sortedPages[index]
        guard let firstTables = pageTables[firstPage], firstTables.count == 1,
            tableOnlyPages.contains(firstPage)
        else {
            index += 1
            continue
        }
        let columns = pdfCountTableColumns(firstTables[0].markdown)
        guard columns > 0 else {
            index += 1
            continue
        }

        // Walk forward while every condition still holds. The first failure
        // ends the run rather than skipping the page — a gap means the table
        // stopped there.
        var continuationPages: [Int] = []
        var next = index + 1
        while next < sortedPages.count {
            let candidate = sortedPages[next]
            let previous = continuationPages.last ?? firstPage
            guard candidate == previous + 1, tableOnlyPages.contains(candidate),
                let tables = pageTables[candidate], tables.count == 1,
                pdfCountTableColumns(tables[0].markdown) == columns
            else { break }
            continuationPages.append(candidate)
            next += 1
        }

        guard !continuationPages.isEmpty else {
            index += 1
            continue
        }

        // Everything from the third line on: the header and its separator
        // are the repeat, and the rows beneath them are the continuation.
        var extraRows = ""
        for page in continuationPages {
            guard let tables = pageTables[page] else { continue }
            for (offset, line) in tables[0].markdown.rustLines().enumerated() where offset >= 2 {
                extraRows += line + "\n"
            }
        }
        pageTables[firstPage]?[0].markdown += extraRows
        for page in continuationPages { pageTables.removeValue(forKey: page) }

        // Resume *after* the run, not inside it: a merged page has no table
        // left to start a run of its own.
        index = next
    }
}
