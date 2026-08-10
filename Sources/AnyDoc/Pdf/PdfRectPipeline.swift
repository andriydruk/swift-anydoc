/// Preparing a page's rectangles for table detection, and the direct
/// detection chain, ported from `detect_tables_from_rects`'s preprocessing
/// and `detect_table_from_rect_group` in `tables/detect_rects.rs`.
///
/// Before any strategy sees them, a page's rectangles need cleaning: negative
/// extents normalised, decoration dropped, page-spanning fills removed, and
/// cell-internal shading deduplicated. Every one of those exists because
/// leaving it in corrupts the grid — a background fill contributes spurious
/// x-edges, a shaded content area inside a cell splits one visual row into
/// two thin ones.

/// Below this in either dimension a rectangle is a border, a dot or
/// decoration rather than a cell.
private let pdfMinimumCellSide: Float = 5

/// A rectangle this many times wider than the median is a page-spanning clip
/// path or a row-spanning fill.
private let pdfOversizedWidthFactor: Float = 10

/// Beyond this many rectangles the quadratic sub-rect dedup is skipped — a
/// page of vector drawing would not benefit from it anyway.
private let pdfMaxDedupRects = 2000

/// Normalise and filter a page's rectangles.
///
/// The oversized filter keys on median **width**, not area, and that choice
/// matters: a row-stripe table has every rectangle at the same full width, so
/// its median *is* the table width and nothing gets dropped. A cell grid has
/// narrow cells, so a full-width background stands out sharply.
func pdfPreparePageRects(
    _ rects: [(x: Float, y: Float, width: Float, height: Float)]
) -> [(x: Float, y: Float, width: Float, height: Float)] {
    var prepared: [(x: Float, y: Float, width: Float, height: Float)] = []
    for rect in rects {
        var (x, y, width, height) = rect
        // A transform can flip either axis, giving negative extents.
        if width < 0 {
            x += width
            width = -width
        }
        if height < 0 {
            y += height
            height = -height
        }
        if width < pdfMinimumCellSide || height < pdfMinimumCellSide { continue }
        prepared.append((x, y, width, height))
    }

    // Both remaining filters need enough rectangles for a median to mean
    // something.
    guard prepared.count >= 6 else { return prepared }

    let widths = prepared.map(\.width).sorted()
    let threshold = widths[widths.count / 2] * pdfOversizedWidthFactor
    prepared = prepared.filter { $0.width <= threshold }

    guard prepared.count < pdfMaxDedupRects else { return prepared }

    // Drop a rectangle fully inside a similarly-sized one: cell-internal
    // shading, which would otherwise add y-edges and split a visual row.
    //
    // Only a *similar* container counts. A table-wide background dwarfing the
    // sub-rectangle is not shading, and an origin-anchored page background is
    // disqualified outright — it usually exceeds the height ratio, but when
    // the inner rectangle is itself a tall table frame the ratio can fall
    // under the gate, and dropping that frame breaks cluster adjacency
    // between neighbouring column groups.
    let snapshot = prepared
    return prepared.filter { inner in
        let tolerance: Float = 2
        return !snapshot.contains { container in
            let containerIsPageBackground = container.x < 5 && container.y < 5
            return container.width * container.height > inner.width * inner.height * 1.2
                && container.height < inner.height * 4
                && !containerIsPageBackground
                && container.x <= inner.x + tolerance
                && container.x + container.width >= inner.x + inner.width - tolerance
                && container.y <= inner.y + tolerance
                && container.y + container.height >= inner.y + inner.height - tolerance
        }
    }
}

/// Build a table from one rectangle group, retrying without page backgrounds.
///
/// The retry is the point. A full-page background fill adds margin columns and
/// makes merged-cell propagation collapse every row's text into the first —
/// which surfaces as `fewNonEmptyRows` rather than an outright failure,
/// precisely so this can try again with those rectangles excluded from the
/// column edges.
///
/// The retry is gated on the group having at least twelve y-edges. Full-page
/// backgrounds only cause this trouble on dense tables; on a small grid the
/// stricter retry would manufacture false positives instead.
func pdfDetectTableFromRectGroup(
    items: [PdfLayoutItem],
    groupRects: [(x: Float, y: Float, width: Float, height: Float)]
) -> PdfTable? {
    let noSkip = [Bool](repeating: false, count: groupRects.count)
    switch pdfTryBuildGrid(items: items, groupRects: groupRects, skipRects: noSkip, strict: false)
    {
    case .ok(let table): return table
    case .failed: return nil
    case .fewNonEmptyRows: break  // worth a retry — see above
    }

    guard let xMin = groupRects.map(\.x).min(),
        let xMax = groupRects.map({ $0.x + $0.width }).max(),
        let yMin = groupRects.map(\.y).min(),
        let yMax = groupRects.map({ $0.y + $0.height }).max()
    else { return nil }
    let groupWidth = xMax - xMin
    let groupHeight = yMax - yMin

    let isPageBackground = groupRects.map { rect in
        rect.x < 5 && rect.y < 5 && rect.width >= groupWidth * 0.95
            && rect.height >= groupHeight * 0.9
    }
    guard isPageBackground.contains(true) else { return nil }

    let yEdges = pdfSnapEdges(
        groupRects.flatMap { [$0.y, $0.y + $0.height] }, tolerance: 6)
    guard yEdges.count >= 12 else { return nil }

    if case .ok(let table) = pdfTryBuildGrid(
        items: items, groupRects: groupRects, skipRects: isPageBackground, strict: true)
    {
        return table
    }
    return nil
}

/// Try the three strategies that work on a group directly, in the
/// reference's order: a proper grid, then row stripes, then stacked boxes.
///
/// The order is the confidence order — a grid is backed by rectangles on both
/// axes, stripes by rectangles on one, and a stacked box by nothing but the
/// stack itself.
func pdfDetectDirectRectTable(
    items: [PdfLayoutItem],
    rects: [(x: Float, y: Float, width: Float, height: Float)]
) -> PdfTable? {
    pdfDetectTableFromRectGroup(items: items, groupRects: rects)
        ?? pdfDetectRowStripeTable(items: items, groupRects: rects)
        ?? pdfDetectStackedBoxTable(items: items, groupRects: rects)
}
