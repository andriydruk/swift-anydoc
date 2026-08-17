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
/// Ahead of all four sits **stage 0, the structure tree** (wave 113): a
/// table the author declared outranks any guess read from ink.
///
/// **This is the single-band, chart-free case.** The reference additionally
/// splits a page into side-by-side bands and retries merged, and masks chart
/// regions from every detector. Those are noted at the branches below.
/// Stage 3 arrived in wave 114, along with the heuristic's missing third
/// branch — see the comment on it below.

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
    items: [PdfLayoutItem], rects: [PdfRect], lines: [PdfLineSegment], baseSize: Float,
    structTables: [PdfStructTable] = [], page: Int = 1,
    chartRegions: [PdfImageRegion] = []
) -> PdfPageTableResult {
    var result = PdfPageTableResult()
    if items.isEmpty { return result }

    // The whole cascade runs **per band**, not per page: a two-column layout
    // shown to a detector all at once reads across the gutter. See
    // `PdfTableBands.swift`.
    let bands = pdfTableBands(items: items, rects: rects, lines: lines)
    for band in bands where !band.items.isEmpty {
        let found = pdfDetectTablesInBand(
            items: band.items, rects: band.rects, lines: band.lines, baseSize: baseSize,
            structTables: structTables, page: page, chartRegions: chartRegions)
        result.tables.append(contentsOf: found.tables)
        // A band's indices are its own; the page wants page indices.
        result.claimed.formUnion(found.claimed.compactMap {
            $0 < band.indexMap.count ? band.indexMap[$0] : nil
        })
    }

    // The retry. Splitting is a guess that fails in one specific way — a
    // borderless table's columns are indistinguishable from page-layout
    // columns — so a split page that found nothing is tried again whole.
    // Only the heuristic runs: the geometric detectors already saw every
    // rectangle and line their band contained.
    if bands.count > 1 && result.tables.isEmpty {
        // With columns detected on the page, body-size text is not allowed
        // to found a table on the retry — that is exactly the evidence which
        // just proved to be page layout. The second argument is whether the
        // page has chart regions, which are unported.
        //
        // Wave 115 wrote this rule out inline without noticing it was
        // already ported; wave 116's orphan sweep found the duplicate.
        let skipBodyFont = pdfMergedRetrySkipsBodyFont(
            detectedColumns: pdfDetectColumns(items, pageHasTable: false).count >= 2,
            hasChartRegions: false)
        for table in pdfDetectTables(items, baseFontSize: baseSize, skipBodyFont: skipBodyFont) {
            result.claimed.formUnion(table.itemIndices)
            result.tables.append(
                PdfPositionedMarkdown(
                    y: table.rows.first ?? 0, x: table.columns.first ?? 0,
                    markdown: pdfTableToMarkdown(table), chartOrder: nil))
        }
    }
    return result
}

/// The four-stage cascade, on one band's worth of a page.
private func pdfDetectTablesInBand(
    items: [PdfLayoutItem], rects: [PdfRect], lines: [PdfLineSegment], baseSize: Float,
    structTables: [PdfStructTable], page: Int,
    chartRegions: [PdfImageRegion] = []
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

    // The reference keeps *two* sets. `table_items` is what the prose must
    // not repeat; `rect_claimed` is what a later detector must not re-read.
    // They hold the same indices for stages 0 to 2 and diverge at stage 3,
    // where a hint region blocks every item inside it while only the items
    // the table actually used are withheld from the text.
    var blocked: Set<Int> = []

    // A bar chart's axis labels and data values sit in a tidy grid, and every
    // detector below reads them as one. They are **pre-blocked** so no
    // strategy can grid them — but deliberately *not* claimed, because
    // withholding them from the text as well would delete the chart's labels
    // from the document. Blocked, not claimed, is the whole distinction.
    if !chartRegions.isEmpty {
        for (index, item) in items.enumerated()
        where pdfItemIsInChartRegion(item, chartRegions) {
            blocked.insert(index)
        }
    }

    func claim(_ table: PdfTable) {
        result.claimed.formUnion(table.itemIndices)
        blocked.formUnion(table.itemIndices)
        result.tables.append(positioned(table))
    }

    // 0. The structure tree, which outranks all four geometric detectors —
    //    an author's own declaration beats any guess from ink. It is
    //    believed only when its tables cover at least **half** the page's
    //    items: a partially tagged document would otherwise claim a
    //    fragment and hide the rest from the detectors that see everything.
    if !structTables.isEmpty {
        for table in pdfDetectTablesFromStructTree(
            items: items, structTables: structTables, page: UInt32(page))
        {
            let coverage = Float(table.itemIndices.count) / Float(max(items.count, 1))
            if coverage < 0.5 { continue }
            claim(table)
        }
    }

    // 1. Rect-based. A table overlapping something already claimed is
    //    dropped whole rather than trimmed.
    let rectDetection = pdfDetectTablesFromRects(
        items: items,
        rects: rects.map { (x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
    for table in rectDetection.tables {
        if !blocked.isEmpty && table.itemIndices.contains(where: blocked.contains) { continue }
        claim(table)
    }
    let hints = rectDetection.hints

    // 2. Line-based, only when the rects found nothing at all. A page with
    //    both borders and rules is read by its borders.
    if blocked.isEmpty {
        for table in pdfDetectTablesFromLines(items: items, lines: lines) { claim(table) }
    }

    /// The items inside a hint's vertical span, and where they came from.
    /// `padding` is the reference's 15pt, which lets a caption or a stray
    /// baseline just outside the boxes still count as part of the region.
    func inside(_ hint: PdfRectHintRegion, horizontally: Bool) -> ([PdfLayoutItem], [Int]) {
        let padding: Float = 15
        var subset: [PdfLayoutItem] = []
        var map: [Int] = []
        for (index, item) in items.enumerated() {
            guard item.y >= hint.yBottom - padding, item.y <= hint.yTop + padding else { continue }
            if horizontally {
                guard item.x >= hint.xLeft - padding, item.x <= hint.xRight + padding else {
                    continue
                }
            }
            subset.append(item)
            map.append(index)
        }
        return (subset, map)
    }

    // 3. Rect-guided construction, for a cluster of boxes that did not grid —
    //    a calendar, most often. This is the only stage that reads the hint's
    //    x bounds as well as its y span.
    if blocked.isEmpty && !hints.isEmpty {
        for hint in hints where !hint.clusterRects.isEmpty {
            let (subset, map) = inside(hint, horizontally: true)
            guard
                let table = pdfBuildRectGuidedTable(
                    items: subset, clusterRects: hint.clusterRects)
            else { continue }
            var translated = table
            translated.itemIndices = table.itemIndices.compactMap {
                $0 < map.count ? map[$0] : nil
            }
            result.claimed.formUnion(translated.itemIndices)
            result.tables.append(positioned(translated))
            // The **whole region** is withheld from the heuristic, not only
            // the cells the table used: what is left inside a calendar is
            // the days it could not place, and re-reading them as a second
            // table would emit the same grid twice.
            blocked.formUnion(map)
        }
    }

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

    /// Everything no earlier stage blocked, and where it came from.
    func unblocked() -> ([PdfLayoutItem], [Int]) {
        var subset: [PdfLayoutItem] = []
        var map: [Int] = []
        for (index, item) in items.enumerated() where !blocked.contains(index) {
            subset.append(item)
            map.append(index)
        }
        return (subset, map)
    }

    if blocked.isEmpty && hints.isEmpty {
        runHeuristic(items, map: Array(items.indices), minimumItems: 6)
    } else if blocked.isEmpty {
        // With hints present the page is searched band by band instead:
        // inside each hint's vertical span, then everything outside them
        // all. A hint marks where a table probably is, so its rows are not
        // averaged in with the prose above and below.
        //
        // The span is vertical **only** here, where stage 3 above also
        // bounded it horizontally — a borderless table may extend past the
        // boxes that hinted at it.
        for hint in hints {
            let (subset, map) = inside(hint, horizontally: false)
            runHeuristic(subset, map: map, minimumItems: 6)
            blocked.formUnion(map)
        }
        let (outside, outsideMap) = unblocked()
        runHeuristic(outside, map: outsideMap, minimumItems: 6)
    } else {
        // Something above found a table. The rest of the page is still
        // searched — a bordered table and a borderless one can share a page,
        // and stopping here loses the second. This branch was absent until
        // wave 114 and is the reason stage 3 needed it: stage 3 always
        // leaves the page blocked.
        let (subset, map) = unblocked()
        runHeuristic(subset, map: map, minimumItems: 6)
    }

    return result
}
