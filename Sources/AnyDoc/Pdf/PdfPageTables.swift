/// Per-page table detection, ported from the cascade inside
/// `to_markdown_from_items_with_rects_and_lines` in `markdown/mod.rs`.
///
/// Four detectors run in priority order and each *claims* the items it uses,
/// so a later one never re-reads text an earlier one already gridded:
///
/// 1. **rect-based** — a bordered table, from the `re` rectangles;
/// 2. **line-based** — a ruled table, from stroked segments, tried only when
///    rects found nothing;
/// 3. **rect-guided** — a table built from a cluster of rects that did not
///    grid on their own;
/// 4. **heuristic** — a borderless table, from text alignment alone.
///
/// The claimed items are then withheld from the text stream: a table's cells
/// must not also appear as prose.
///
/// **This is the single-band, chart-free, untagged case.** The reference
/// additionally splits a page into side-by-side bands and retries merged,
/// masks chart regions from every detector, and gives structure-tree tables
/// priority over all four. Those are noted at the branches below and are
/// wave 104. Stage 3 is also absent — `try_build_rect_guided_table` is
/// unported — so a page whose rects cluster without gridding yields no table
/// where the reference finds one.

/// What a page's table detection produced.
struct PdfPageTableResult {
    /// Rendered tables, positioned at their first row and column.
    var tables: [PdfPositionedMarkdown] = []
    /// Indices into the page's items that a table claimed. These must not
    /// reach the text stream.
    var claimed: Set<Int> = []
}

/// Detect the tables on one page.
///
/// - Parameters:
///   - items: the page's text items, after the merge passes.
///   - rects: the page's filled rectangles.
///   - lines: the page's stroked segments.
///   - baseSize: the document's body size, which the heuristic detector
///     measures its candidates against.
func pdfDetectPageTables(
    items: [PdfLayoutItem], rects: [PdfRect], lines: [PdfLineSegment], baseSize: Float
) -> PdfPageTableResult {
    var result = PdfPageTableResult()
    if items.isEmpty { return result }

    /// A table's Markdown, positioned at its first row and column — which is
    /// what lets the writer interleave it with the prose around it.
    func positioned(_ table: PdfTable) -> PdfPositionedMarkdown {
        PdfPositionedMarkdown(
            y: table.rows.first ?? 0, x: table.columns.first ?? 0,
            markdown: pdfTableToMarkdown(table), chartOrder: nil)
    }

    func claim(_ table: PdfTable) {
        result.claimed.formUnion(table.itemIndices)
        result.tables.append(positioned(table))
    }

    // A structure-tree stage runs before all of these in the reference, and
    // takes priority when its tables cover at least half the page's items.
    // Unported: `structure_tree.rs`'s `from_doc` has no document walker yet.

    // 1. Rect-based. A table overlapping something already claimed is
    //    dropped whole rather than trimmed.
    let rectDetection = pdfDetectTablesFromRects(
        items: items,
        rects: rects.map { (x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
    for table in rectDetection.tables {
        if !result.claimed.isEmpty && table.itemIndices.contains(where: result.claimed.contains) {
            continue
        }
        claim(table)
    }
    let hints = rectDetection.hints

    // 2. Line-based, only when the rects found nothing at all. A page with
    //    both borders and rules is read by its borders.
    if result.claimed.isEmpty {
        for table in pdfDetectTablesFromLines(items: items, lines: lines) { claim(table) }
    }

    // 3. Rect-guided construction over the hint regions would run here.
    //    Unported, so a hint region reaches the heuristic below unbuilt.

    // 4. Heuristic, on whatever is still unclaimed. Six items is the floor:
    //    fewer cannot describe a grid.
    func runHeuristic(_ subset: [PdfLayoutItem], map: [Int], minimumItems: Int) {
        guard subset.count >= minimumItems else { return }
        for table in pdfDetectTables(subset, baseFontSize: baseSize) {
            var translated = table
            translated.itemIndices = table.itemIndices.compactMap {
                $0 < map.count ? map[$0] : nil
            }
            claim(translated)
        }
    }

    if result.claimed.isEmpty && hints.isEmpty {
        runHeuristic(items, map: Array(items.indices), minimumItems: 6)
    } else if result.claimed.isEmpty {
        // With hints present the page is searched band by band instead:
        // inside each hint's vertical span, then everything outside them
        // all. A hint marks where a table probably is, so its rows are not
        // averaged in with the prose above and below.
        let padding: Float = 15
        var insideAny: Set<Int> = []
        for hint in hints {
            var subset: [PdfLayoutItem] = []
            var map: [Int] = []
            for (index, item) in items.enumerated()
            where item.y >= hint.yBottom - padding && item.y <= hint.yTop + padding {
                subset.append(item)
                map.append(index)
            }
            runHeuristic(subset, map: map, minimumItems: 6)
            insideAny.formUnion(map)
        }
        var outside: [PdfLayoutItem] = []
        var outsideMap: [Int] = []
        for (index, item) in items.enumerated() where !insideAny.contains(index) {
            outside.append(item)
            outsideMap.append(index)
        }
        runHeuristic(outside, map: outsideMap, minimumItems: 6)
    }

    return result
}
