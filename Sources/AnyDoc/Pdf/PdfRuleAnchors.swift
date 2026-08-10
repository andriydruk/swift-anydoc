/// The anchor primitives of line-based table detection, ported from
/// `collect_anchored_rows`, `logical_row_anchors`, `nearest_anchor_column`,
/// `matched_anchor_column_count` and `combine_non_overlapping_tables` in
/// pdf-inspector's `tables/detect_lines.rs`.
///
/// A booktabs table draws two or three rules and no column borders at all, so
/// its columns exist only in where the text starts. These functions are how
/// that is read: gather the text a run of rules encloses, group it into rows,
/// and infer each row's column anchors from the gaps between word spans. The
/// strategies built on top compare rows against those anchors to decide
/// whether a band of text is really tabular.

/// A row of text inside a ruled band: its baseline, and the items on it with
/// their original indices.
typealias PdfAnchoredRow = (y: Float, items: [(index: Int, item: PdfLayoutItem)])

/// Gather the text a run of rules encloses, grouped into rows.
///
/// The bounds come from the rules themselves — the highest and lowest
/// baselines, and the widest span — loosened by the same tolerances used to
/// merge the rules in the first place, so a caption sitting just outside is
/// not clipped off mid-table.
///
/// Rows are formed against the row in progress rather than a fixed grid, and
/// items arrive sorted down the page, so a superscript or a slightly raised
/// glyph joins the row it belongs to rather than starting a new one.
func pdfCollectAnchoredRows(
    items: [PdfLayoutItem], rules: [PdfHorizontalRule]
) -> [PdfAnchoredRow] {
    // Folded exactly as the reference does, which means an empty rule list
    // leaves the bounds inverted — `yBottom` at +∞ and `yTop` at -∞ — and no
    // item can satisfy both. No rules therefore selects *nothing*, which is
    // the useful answer even though it reads like an accident.
    var yTop = -Float.infinity
    var yBottom = Float.infinity
    var xMin = Float.infinity
    var xMax = -Float.infinity
    for rule in rules {
        yTop = max(yTop, rule.y)
        yBottom = min(yBottom, rule.y)
        xMin = min(xMin, rule.xMin)
        xMax = max(xMax, rule.xMax)
    }

    // The reference also skips image placeholders here. The port has no such
    // items yet, so that filter is a no-op — see `PdfRectTables.swift`.
    var selected = items.enumerated().filter { _, item in
        !item.text.rustTrim().isEmpty
            && item.y >= yBottom - pdfRuleYTolerance && item.y <= yTop + pdfRuleYTolerance
            && item.x + max(item.width, 0) >= xMin - pdfRuleJoinGap
            && item.x <= xMax + pdfRuleJoinGap
    }.map { (index: $0.offset, item: $0.element) }

    // Down the page, then left to right. Rust's `sort_by` is stable and
    // Swift's `sort` is not, so the original index breaks exact ties — which
    // is what stability would have given, and matters because two items at
    // the same point land in the same row in a fixed order.
    selected.sort {
        $0.item.y != $1.item.y
            ? $0.item.y > $1.item.y
            : ($0.item.x != $1.item.x ? $0.item.x < $1.item.x : $0.index < $1.index)
    }

    var rows: [PdfAnchoredRow] = []
    for entry in selected {
        if let last = rows.last, abs(last.y - entry.item.y) <= pdfTextRowTolerance {
            rows[rows.count - 1].items.append(entry)
        } else {
            rows.append((y: entry.item.y, items: [entry]))
        }
    }
    for index in rows.indices {
        rows[index].items.sort {
            $0.item.x != $1.item.x ? $0.item.x < $1.item.x : $0.index < $1.index
        }
    }
    return rows
}

/// The x positions a row's columns start at.
///
/// Word spans are swept left to right and joined while they touch: a gap wider
/// than the rule-join gap starts a new anchor. So "Net revenue" is one anchor
/// rather than two, and the anchors of a row are its logical cells.
func pdfLogicalRowAnchors(_ row: [(index: Int, item: PdfLayoutItem)]) -> [Float] {
    let spans = row.map { (left: $0.item.x, right: $0.item.x + max($0.item.width, 0)) }
        .sorted { $0.left < $1.left }

    var anchors: [Float] = []
    var currentRight = -Float.infinity
    for span in spans {
        if anchors.isEmpty || span.left > currentRight + pdfRuleJoinGap {
            anchors.append(span.left)
            // Note the running right edge is *replaced* when an anchor opens,
            // not extended — so a wide span followed by a narrow one inside it
            // shortens the reach.
            currentRight = span.right
        } else {
            currentRight = max(currentRight, span.right)
        }
    }
    return anchors
}

/// The anchor an item belongs to: the nearest by *start* position.
///
/// Distance is measured from the item's left edge only, so a centred cell is
/// attributed to the anchor its text begins after, not the one it straddles.
/// `min_by` keeps the first of equal distances, so an item exactly between two
/// anchors goes to the left one.
func pdfNearestAnchorColumn(_ item: PdfLayoutItem, anchors: [Float]) -> Int? {
    var best: (index: Int, distance: Float)?
    for (index, anchor) in anchors.enumerated() {
        let distance = abs(anchor - item.x)
        if best == nil || distance < best!.distance { best = (index, distance) }
    }
    return best?.index
}

/// How many distinct anchors a row's items reach.
///
/// This is the row's evidence of being tabular: a prose line puts every word
/// near the same one or two anchors, while a data row spreads across most of
/// them.
func pdfMatchedAnchorColumnCount(
    _ row: [(index: Int, item: PdfLayoutItem)], anchors: [Float]
) -> Int {
    var seen = Set<Int>()
    for entry in row {
        if let column = pdfNearestAnchorColumn(entry.item, anchors: anchors) { seen.insert(column) }
    }
    return seen.count
}

/// Add the secondary tables that claim no item the primary ones already have,
/// then order everything down the page.
///
/// Two strategies proposing the same table is the normal case, not the
/// exception, so overlap is settled by *item ownership* rather than geometry:
/// a table sharing even one item with an accepted one is dropped whole.
func pdfCombineNonOverlappingTables(_ primary: [PdfTable], _ secondary: [PdfTable]) -> [PdfTable] {
    var claimed = Set<Int>()
    for table in primary { claimed.formUnion(table.itemIndices) }

    var combined = primary
    combined.append(
        contentsOf: secondary.filter { table in
            table.itemIndices.allSatisfy { !claimed.contains($0) }
        })
    // A table with no rows sorts as though its top were zero, which puts it
    // last — reproduced as written. Sorted stably, since the reference's sort
    // is: two tables starting on the same baseline keep the order the
    // strategies produced them in.
    return combined.enumerated()
        .sorted {
            let left = $0.element.rows.first ?? 0
            let right = $1.element.rows.first ?? 0
            return left != right ? left > right : $0.offset < $1.offset
        }
        .map(\.element)
}
