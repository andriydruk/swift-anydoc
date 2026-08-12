#!/bin/sh
# Build the graphics oracle: a vendored pdf-inspector 0.1.7 carrying one
# additive entry point, plus a binary that dumps the reference's own path
# extraction for a PDF.
#
# The path walker lives inside a 1,300-line crate-private function and is not
# reachable from the published API, so the crate is vendored from the cargo
# registry and given a single `probe_graphics` function. Nothing else in the
# reference is changed: `probe_graphics` only calls existing code. The
# manifest is trimmed (optional pyo3, dev-dependencies, the crate's own
# binaries) so it resolves and builds offline.
#
#   scripts/gen-graphics-oracle.sh <work-dir>
#   scripts/gen-pdf-corpus.py <corpus-dir>
#   for f in <corpus-dir>/*.pdf; do
#     <work-dir>/pdfinspector/target/release/graphicsprobe "$f" > "$f.graphics"
#   done
#   ANYDOC_PDF_CORPUS=<corpus-dir> swift test --filter PdfGraphicsProbe
#
# This oracle is also what table detection will need, which is why it is a
# script rather than a one-off.
set -eu

if [ $# -lt 1 ]; then
    echo "usage: $0 <work-dir>" >&2
    exit 2
fi
work=$1
mkdir -p "$work"

reference=$(ls -d "$HOME"/.cargo/registry/src/*/pdf-inspector-0.1.7 2>/dev/null | head -1)
if [ -z "$reference" ]; then
    echo "pdf-inspector 0.1.7 not found in the cargo registry." >&2
    echo "Fetch it with: cargo add pdf-inspector@0.1.7 (in a scratch crate)" >&2
    exit 1
fi

crate=$work/pdfinspector
rm -rf "$crate"
cp -R "$reference" "$crate"
chmod -R u+w "$crate"

# Reach the path walker without widening a dozen private items.
perl -pi -e 's/^pub\(crate\) mod content_stream;/pub mod content_stream;/' \
    "$crate/src/extractor/mod.rs"
perl -pi -e 's/^pub\(crate\) fn extract_page_text_items\(/pub fn extract_page_text_items(/' \
    "$crate/src/extractor/content_stream.rs"

# Same for the table-grid geometry, which is otherwise unreachable.
perl -pi -e 's/^pub\(crate\) mod grid;/pub mod grid;/; s/^mod grid;/pub mod grid;/' \
    "$crate/src/tables/mod.rs"
perl -pi -e 's/^pub\(crate\) mod tables;/pub mod tables;/' "$crate/src/lib.rs"
perl -pi -e 's/^pub\(crate\) fn (find_column_boundaries|find_row_boundaries|find_column_index|find_row_index|join_cell_items)\(/pub fn $1(/' \
    "$crate/src/tables/grid.rs"
perl -pi -e 's/^pub\(crate\) enum TableDetectionMode/pub enum TableDetectionMode/' \
    "$crate/src/tables/mod.rs"
perl -pi -e 's/^pub\(crate\) mod format;/pub mod format;/; s/^mod format;/pub mod format;/' \
    "$crate/src/tables/mod.rs"
perl -pi -e 's/^pub\(crate\) mod detect_heuristic;/pub mod detect_heuristic;/; s/^mod detect_heuristic;/pub mod detect_heuristic;/' \
    "$crate/src/tables/mod.rs"
perl -pi -e 's/^pub\(super\) fn (is_page_number_toc|is_dot_leader_toc|is_tabular_toc|is_inline_leader_index)\(/pub fn $1(/' \
    "$crate/src/tables/detect_heuristic.rs"
perl -pi -e 's/^fn detect_table_in_region\(/pub fn detect_table_in_region(/' \
    "$crate/src/tables/detect_heuristic.rs"
perl -pi -e 's/^pub\(crate\) fn merge_adjacent_items\(/pub fn merge_adjacent_items(/' \
    "$crate/src/tables/detect_heuristic.rs"
perl -pi -e 's/^fn (find_table_regions|find_table_regions_strict)\(/pub fn $1(/' \
    "$crate/src/tables/detect_heuristic.rs"
perl -pi -e 's/^pub\(crate\) mod detect_lines;/pub mod detect_lines;/; s/^mod detect_lines;/pub mod detect_lines;/' \
    "$crate/src/tables/mod.rs"
perl -pi -e 's/^fn (merge_horizontal_segments|group_rules_by_span|numbered_table_caption|split_independent_rule_runs|rules_are_uniform_grid|derive_columns_from_horizontal_segments)\(/pub fn $1(/' \
    "$crate/src/tables/detect_lines.rs"
perl -pi -e "s/^fn (build_dense_row_anchor_table)/pub fn \$1/" \
    "$crate/src/tables/detect_lines.rs"
perl -pi -e "s/^fn (detect_text_anchor_rule_tables|line_overlaps_text_anchor_band)/pub fn \$1/; s/^struct TextAnchorTable/pub struct TextAnchorTable/" \
    "$crate/src/tables/detect_lines.rs"
perl -pi -e "s/^    table: Table,/    pub table: Table,/; s/^    x_left: f32,/    pub x_left: f32,/; s/^    x_right: f32,/    pub x_right: f32,/; s/^    y_bottom: f32,/    pub y_bottom: f32,/; s/^    y_top: f32,/    pub y_top: f32,/" \
    "$crate/src/tables/detect_lines.rs"
perl -pi -e "s/^fn (build_text_anchor_table)/pub fn \$1/" \
    "$crate/src/tables/detect_lines.rs"
perl -pi -e "s/^fn (build_stacked_token_table|build_open_edge_grid_table_for_rules|build_open_edge_grid_tables)/pub fn \$1/" \
    "$crate/src/tables/detect_lines.rs"
perl -pi -e "s/^fn (collect_anchored_rows|logical_row_anchors|nearest_anchor_column|matched_anchor_column_count|combine_non_overlapping_tables)/pub fn \$1/" \
    "$crate/src/tables/detect_lines.rs"
perl -pi -e 's/^fn (table_evidence_score|select_non_overlapping_hypotheses|tables_share_items|overlaps_multiple_tables|select_table_hypothesis)\(/pub fn $1(/' \
    "$crate/src/tables/detect_lines.rs"
perl -pi -e 's/^pub\(crate\) mod detect_rects;/pub mod detect_rects;/; s/^mod detect_rects;/pub mod detect_rects;/' \
    "$crate/src/tables/mod.rs"
perl -pi -e 's/^pub\(crate\) fn (rects_overlap|cluster_rects)\(/pub fn $1(/; s/^fn split_wide_cluster\(/pub fn split_wide_cluster(/' \
    "$crate/src/tables/detect_rects.rs"
perl -pi -e 's/^pub\(crate\) fn assign_items_to_grid\(/pub fn assign_items_to_grid(/; s/^fn remove_inner_delimiter_spaces\(/pub fn remove_inner_delimiter_spaces(/' \
    "$crate/src/tables/detect_rects.rs"
perl -pi -e 's/^fn try_build_grid\(/pub fn try_build_grid(/; s/^enum GridResult \{/pub enum GridResult {/' \
    "$crate/src/tables/detect_rects.rs"
perl -pi -e 's/^fn (is_row_stripe_pattern|without_dominant_page_backgrounds|is_chart_bar_cluster)\(/pub fn $1(/' \
    "$crate/src/tables/detect_rects.rs"
perl -pi -e 's/^fn (detect_row_stripe_table|cluster_x_positions|has_dominant_prose_cell|row_stripe_is_sparse_prose_outline)\(/pub fn $1(/' \
    "$crate/src/tables/detect_rects.rs"
perl -pi -e 's/^fn detect_stacked_box_table\(/pub fn detect_stacked_box_table(/' \
    "$crate/src/tables/detect_rects.rs"
perl -pi -e 's/^fn detect_merged_cluster_table\(/pub fn detect_merged_cluster_table(/' \
    "$crate/src/tables/detect_rects.rs"
perl -pi -e 's/^fn detect_direct_rect_table\(/pub fn detect_direct_rect_table(/' \
    "$crate/src/tables/detect_rects.rs"
cat >> "$crate/src/tables/mod.rs" <<'RS2'

/// Probe shim (added for swift-anydoc): expose the financial expansion.
pub fn financial_probe_expand(
    items: &[crate::types::TextItem],
) -> (Vec<crate::types::TextItem>, Vec<usize>) {
    let mut expanded = Vec::new();
    let mut index_map = Vec::new();
    for (orig_idx, item) in items.iter().enumerate() {
        if let Some(subs) = financial::try_split_financial_item(item) {
            for sub in subs {
                expanded.push(sub);
                index_map.push(orig_idx);
            }
        } else {
            expanded.push(item.clone());
            index_map.push(orig_idx);
        }
    }
    (expanded, index_map)
}
RS2

# Drop the python bindings: pyo3 is optional but its dev-dependencies still
# have to resolve, and one of them is not vendored.
rm -f "$crate/src/python.rs" "$crate/src/bin/pdf2md.rs" \
    "$crate/src/bin/detect_pdf.rs" "$crate/src/bin/dump_ops.rs"
perl -0pi -e 's/#\[cfg\(feature = "python"\)\]\npub mod python;\n//' "$crate/src/lib.rs"

python3 - "$crate/Cargo.toml" <<'PYEOF'
import re
import sys

path = sys.argv[1]
manifest = open(path).read()
manifest = re.sub(r"\[dependencies\.pyo3\][\s\S]*?optional = true\n", "", manifest)
manifest = re.sub(r'\[dev-dependencies\.tempfile\]\nversion = "3.3"\n', "", manifest)
manifest = re.sub(
    r"\[target\.'cfg\(not\(target_arch = \"wasm32\"\)\)'\.dependencies\.env_logger\]\n"
    r'version = "0\.11"\n',
    "",
    manifest,
)
manifest = manifest.replace('python = ["pyo3"]\n', "")
manifest = manifest.replace('crate-type = [\n    "lib",\n    "cdylib",\n]', 'crate-type = ["lib"]')
manifest = re.sub(
    r'\[\[bin\]\]\nname = "(pdf2md|detect-pdf|dump_ops)"\npath = "[^"]*"\n', "", manifest
)
# Without the crate's own lockfile the resolver picks a `time` that is not in
# the local registry; pin it to one that is.
manifest += '\n[dependencies.time]\nversion = "=0.3.55"\n'
manifest += '\n[[bin]]\nname = "graphicsprobe"\npath = "src/bin/graphicsprobe.rs"\n'
open(path, "w").write(manifest)
PYEOF

cat >> "$crate/src/extractor/content_stream.rs" <<'RUSTEOF'

// ── Differential probe (added for swift-anydoc; not part of the crate) ──
//
// One additive entry point so an external binary needs none of the crate's
// private items made public. Everything it calls is the reference's own code.
/// Dump the path-extraction output for every page of a PDF held in memory.
pub fn probe_graphics(bytes: &[u8]) -> String {
    use crate::tounicode::FontCMaps;
    let mut out = String::new();
    let doc = match lopdf::Document::load_mem(bytes) {
        Ok(d) => d,
        Err(e) => return format!("#ERROR {e:?}\n"),
    };
    let pages = doc.get_pages();
    let mut numbers: Vec<u32> = pages.keys().copied().collect();
    numbers.sort();
    let cmaps = FontCMaps::from_doc_pages_fast(&doc, None);
    for n in numbers {
        let page_id = pages[&n];
        let mut cache = FontStyleCache::default();
        match extract_page_text_items(&doc, page_id, n, &cmaps, false, &mut cache) {
            Ok(((_, rects, lines), _, rotated)) => {
                out.push_str(&format!("#PAGE {n} rotated={rotated}\n"));
                for r in &rects {
                    out.push_str(&format!(
                        "rect {:.3} {:.3} {:.3} {:.3}\n",
                        r.x, r.y, r.width, r.height
                    ));
                }
                for l in &lines {
                    out.push_str(&format!(
                        "line {:.3} {:.3} {:.3} {:.3}\n",
                        l.x1, l.y1, l.x2, l.y2
                    ));
                }
            }
            Err(e) => out.push_str(&format!("#PAGE {n} error={e:?}\n")),
        }
    }
    out
}

/// Dump the underline and strikeout flags the reference marked on each text
/// item. `mark_underlined_items` runs inside `extract_page_text_items`, so
/// the items come back already decorated.
pub fn probe_underline(bytes: &[u8]) -> String {
    use crate::tounicode::FontCMaps;
    let mut out = String::new();
    let doc = match lopdf::Document::load_mem(bytes) {
        Ok(d) => d,
        Err(e) => return format!("#ERROR {e:?}\n"),
    };
    let pages = doc.get_pages();
    let mut numbers: Vec<u32> = pages.keys().copied().collect();
    numbers.sort();
    let cmaps = FontCMaps::from_doc_pages_fast(&doc, None);
    for n in numbers {
        let page_id = pages[&n];
        let mut cache = FontStyleCache::default();
        if let Ok(((items, _, _), _, _)) =
            extract_page_text_items(&doc, page_id, n, &cmaps, false, &mut cache)
        {
            out.push_str(&format!("#PAGE {n}\n"));
            for i in &items {
                out.push_str(&format!(
                    "item {} {} {:.3} {}\n",
                    i.is_underline as u8,
                    i.is_strikeout as u8,
                    i.width,
                    i.text.trim()
                ));
            }
        }
    }
    out
}
RUSTEOF

cat >> "$crate/src/tables/grid.rs" <<'RUSTEOF'

// ── Differential probe (added for swift-anydoc; not part of the crate) ──
/// Read `x y width font_size text` lines from a description and report the
/// grid the reference derives: columns, rows, each item's cell, and the
/// joined text of every cell.
pub fn probe_grid(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    let mut items: Vec<TextItem> = Vec::new();
    for line in input.lines() {
        let line = line.trim_end();
        if line.is_empty() {
            continue;
        }
        let mut parts = line.splitn(5, ' ');
        let x: f32 = parts.next().unwrap_or("0").parse().unwrap_or(0.0);
        let y: f32 = parts.next().unwrap_or("0").parse().unwrap_or(0.0);
        let w: f32 = parts.next().unwrap_or("0").parse().unwrap_or(0.0);
        let fs: f32 = parts.next().unwrap_or("0").parse().unwrap_or(0.0);
        let text = parts.next().unwrap_or("").to_string();
        items.push(TextItem {
            text,
            x,
            y,
            width: w,
            height: fs,
            font: "F1".to_string(),
            font_size: fs,
            page: 1,
            is_bold: false,
            is_italic: false,
            is_underline: false,
            is_strikeout: false,
            item_type: ItemType::Text,
            mcid: None,
        });
    }
    let indexed: Vec<(usize, &TextItem)> = items.iter().enumerate().collect();

    let mut out = String::new();
    for mode in [
        super::TableDetectionMode::SmallFont,
        super::TableDetectionMode::BodyFont,
    ] {
        let columns = find_column_boundaries(&indexed, mode);
        out.push_str(&format!("columns{:?}", mode));
        for c in &columns {
            out.push_str(&format!(" {c:.3}"));
        }
        out.push('\n');
    }
    let columns = find_column_boundaries(&indexed, super::TableDetectionMode::SmallFont);
    let rows = find_row_boundaries(&indexed);
    out.push_str("rows");
    for r in &rows {
        out.push_str(&format!(" {r:.3}"));
    }
    out.push('\n');
    for item in &items {
        out.push_str(&format!(
            "cell {:?} {:?}\n",
            find_column_index(&columns, item.x),
            find_row_index(&rows, item.y)
        ));
    }
    let refs: Vec<&TextItem> = items.iter().collect();
    out.push_str(&format!("join {}\n", join_cell_items(&refs)));
    out
}
RUSTEOF

cat >> "$crate/src/tables/format.rs" <<'RUSTEOF'

// ── Differential probe (added for swift-anydoc; not part of the crate) ──
/// Read tab-separated cell rows and report what the formatter makes of them:
/// the cleaned grid, the footnotes pulled out, the data-table rendering and
/// the contents-listing rendering.
pub fn probe_format(input: &str) -> String {
    let cells: Vec<Vec<String>> = input
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| l.split('\t').map(|c| c.to_string()).collect())
        .collect();
    if cells.is_empty() {
        return String::new();
    }
    let (cleaned, footnotes) = clean_table_cells(&cells);
    let mut out = String::new();
    for row in &cleaned {
        out.push_str(&format!("clean\t{}\n", row.join("\t")));
    }
    for f in &footnotes {
        out.push_str(&format!("footnote\t{f}\n"));
    }
    out.push_str(&format!(
        "kind\t{}\t{}\t{}\t{}\n",
        crate::tables::detect_heuristic::is_table_of_contents(&cells) as u8,
        crate::tables::detect_heuristic::is_page_number_toc(&cells) as u8,
        crate::tables::detect_heuristic::is_dot_leader_toc(&cells) as u8,
        crate::tables::detect_heuristic::is_tabular_toc(&cells) as u8,
    ));
    let data = Table::new(vec![], vec![], cells.clone(), vec![]);
    let mut data = data;
    data.kind = TableKind::Data;
    out.push_str("--data--
");
    out.push_str(&table_to_markdown(&data));
    out.push_str("--toc--
");
    out.push_str(&format_toc_as_list(&cells, &[]));
    out
}
RUSTEOF

cat >> "$crate/src/tables/grid.rs" <<'RUSTEOF'

/// Run the heuristic detector over a region's items and report the table it
/// produces, or that it rejected the region.
pub fn probe_detect(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    let mut items: Vec<TextItem> = Vec::new();
    for line in input.lines() {
        if line.trim_end().is_empty() {
            continue;
        }
        let mut parts = line.splitn(5, ' ');
        let x: f32 = parts.next().unwrap_or("0").parse().unwrap_or(0.0);
        let y: f32 = parts.next().unwrap_or("0").parse().unwrap_or(0.0);
        let w: f32 = parts.next().unwrap_or("0").parse().unwrap_or(0.0);
        let fs: f32 = parts.next().unwrap_or("0").parse().unwrap_or(0.0);
        let text = parts.next().unwrap_or("").to_string();
        items.push(TextItem {
            text, x, y, width: w, height: fs, font: "F1".to_string(), font_size: fs,
            page: 1, is_bold: false, is_italic: false, is_underline: false,
            is_strikeout: false, item_type: ItemType::Text, mcid: None,
        });
    }
    let indexed: Vec<(usize, &TextItem)> = items.iter().enumerate().collect();
    let mut out = String::new();
    let (merged, index_map) =
        crate::tables::detect_heuristic::merge_adjacent_items(&items);
    for (item, indices) in merged.iter().zip(index_map.iter()) {
        out.push_str(&format!(
            "merge\t{:.3}\t{:.3}\t{:.3}\t{:?}\t{}\n",
            item.x, item.y, item.width, indices, item.text
        ));
    }
    {
        let (expanded, map) = crate::tables::financial_probe_expand(&items);
        for (item, orig) in expanded.iter().zip(map.iter()) {
            out.push_str(&format!(
                "expand\t{:.3}\t{:.3}\t{orig}\t{}\n",
                item.x, item.width, item.text
            ));
        }
    }
    for (y0, y1) in crate::tables::detect_heuristic::find_table_regions(&indexed) {
        out.push_str(&format!("region\t{y0:.3}\t{y1:.3}\n"));
    }
    for (y0, y1, x0, x1) in crate::tables::detect_heuristic::find_table_regions_strict(&indexed) {
        out.push_str(&format!("strict\t{y0:.3}\t{y1:.3}\t{x0:.3}\t{x1:.3}\n"));
    }
    for base in [8.0f32, 10.0, 12.0] {
        for skip in [false, true] {
            let found = crate::tables::detect_heuristic::detect_tables(&items, base, skip);
            out.push_str(&format!("tables\t{base:.1}\t{skip}\t{}\n", found.len()));
            for t in &found {
                out.push_str(&format!(
                    "table\t{base:.1}\t{skip}\t{}\t{}\t{:?}\t{:?}\n",
                    t.columns.len(), t.rows.len(), t.kind, t.item_indices
                ));
                for row in &t.cells {
                    out.push_str(&format!("tcell\t{}\n", row.join("\t")));
                }
            }
        }
    }
    for (label, mode) in [
        ("SmallFont", super::TableDetectionMode::SmallFont),
        ("BodyFont", super::TableDetectionMode::BodyFont),
    ] {
        match crate::tables::detect_heuristic::detect_table_in_region(&indexed, mode) {
            None => out.push_str(&format!("{label}\tnone\n")),
            Some(t) => {
                out.push_str(&format!(
                    "{label}\t{}\t{}\t{:?}\n",
                    t.columns.len(),
                    t.rows.len(),
                    t.kind
                ));
                for row in &t.cells {
                    out.push_str(&format!("{label}cell\t{}\n", row.join("\t")));
                }
            }
        }
    }
    out
}
RUSTEOF

cat >> "$crate/src/tables/detect_lines.rs" <<'RUSTEOF'

/// Probe (added for swift-anydoc): report what the rule primitives make of a
/// set of horizontal segments. Input lines are `y x_min x_max`, then a blank
/// line, then optional text items as `x y width font_size text`.
/// Probe (added for swift-anydoc): the stacked-token and open-edge grid
/// strategies. Extends the rule case format with `v x y_min y_max` lines for
/// vertical rules, which the earlier rule probes ignore.
pub fn probe_openedge(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    let mut rules: Vec<(f32, f32, f32)> = Vec::new();
    let mut verticals: Vec<(f32, f32, f32)> = Vec::new();
    let mut path_lines: Vec<crate::types::PdfLine> = Vec::new();
    let mut items: Vec<TextItem> = Vec::new();
    let mut in_items = false;
    for line in input.lines() {
        if line.trim().is_empty() {
            in_items = true;
            continue;
        }
        let parts: Vec<&str> = line.split(' ').collect();
        if !in_items {
            if parts[0] == "p" && parts.len() >= 5 {
                path_lines.push(crate::types::PdfLine {
                    x1: parts[1].parse().unwrap_or(0.0),
                    y1: parts[2].parse().unwrap_or(0.0),
                    x2: parts[3].parse().unwrap_or(0.0),
                    y2: parts[4].parse().unwrap_or(0.0),
                    page: 1,
                });
            } else if parts[0] == "v" && parts.len() >= 4 {
                verticals.push((
                    parts[1].parse().unwrap_or(0.0),
                    parts[2].parse().unwrap_or(0.0),
                    parts[3].parse().unwrap_or(0.0),
                ));
            } else if parts.len() >= 3 {
                rules.push((
                    parts[0].parse().unwrap_or(0.0),
                    parts[1].parse().unwrap_or(0.0),
                    parts[2].parse().unwrap_or(0.0),
                ));
            }
        } else if parts.len() >= 5 {
            items.push(TextItem {
                text: parts[4..].join(" "),
                x: parts[0].parse().unwrap_or(0.0),
                y: parts[1].parse().unwrap_or(0.0),
                width: parts[2].parse().unwrap_or(0.0),
                height: parts[3].parse().unwrap_or(0.0),
                font: "F1".to_string(),
                font_size: parts[3].parse().unwrap_or(0.0),
                page: 1,
                is_bold: false, is_italic: false, is_underline: false, is_strikeout: false,
                item_type: ItemType::Text, mcid: None,
            });
        }
    }

    fn emit(out: &mut String, tag: &str, t: &Table) {
        out.push_str(&format!("{tag} {} {}\nc", t.columns.len(), t.rows.len()));
        for v in &t.columns { out.push_str(&format!(" {v:.3}")); }
        out.push_str("\nw");
        for v in &t.rows { out.push_str(&format!(" {v:.3}")); }
        out.push('\n');
        for row in &t.cells {
            out.push('x');
            for c in row { out.push('\t'); out.push_str(c); }
            out.push('\n');
        }
        out.push_str("i");
        for i in &t.item_indices { out.push_str(&format!(" {i}")); }
        out.push('\n');
    }

    let mut out = String::new();
    match build_text_anchor_table(&items, &rules, 1) {
        None => out.push_str("anchor none\n"),
        Some(t) => emit(&mut out, "anchor", &t),
    }
    let anchored = collect_anchored_rows(&items, &rules, 1);
    match build_stacked_token_table(&anchored, &rules) {
        None => out.push_str("stacked none\n"),
        Some(t) => emit(&mut out, "stacked", &t),
    }
    match build_dense_row_anchor_table(&items, &rules, &verticals, 1) {
        None => out.push_str("dense none\n"),
        Some(t) => emit(&mut out, "dense", &t),
    }
    let bands = detect_text_anchor_rule_tables(&items, &rules, &verticals, &path_lines, 1);
    out.push_str(&format!("bands {}\n", bands.len()));
    for b in &bands {
        out.push_str(&format!(
            "b {:.3} {:.3} {:.3} {:.3}\n", b.x_left, b.x_right, b.y_bottom, b.y_top));
        emit(&mut out, "bt", &b.table);
    }

    let grids = build_open_edge_grid_tables(&items, &rules, &verticals, 1);
    out.push_str(&format!("grids {}\n", grids.len()));
    for t in &grids { emit(&mut out, "g", t); }
    out
}

/// Probe (added for swift-anydoc): the anchor primitives. Shares the rule
/// case format — `y x_min x_max` lines, a blank line, then items.
pub fn probe_anchors(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    let mut rules: Vec<(f32, f32, f32)> = Vec::new();
    let mut items: Vec<TextItem> = Vec::new();
    let mut in_items = false;
    for line in input.lines() {
        if line.trim().is_empty() {
            in_items = true;
            continue;
        }
        let parts: Vec<&str> = line.split(' ').collect();
        if !in_items {
            if parts.len() >= 3 {
                rules.push((
                    parts[0].parse().unwrap_or(0.0),
                    parts[1].parse().unwrap_or(0.0),
                    parts[2].parse().unwrap_or(0.0),
                ));
            }
        } else if parts.len() >= 5 {
            items.push(TextItem {
                text: parts[4..].join(" "),
                x: parts[0].parse().unwrap_or(0.0),
                y: parts[1].parse().unwrap_or(0.0),
                width: parts[2].parse().unwrap_or(0.0),
                height: parts[3].parse().unwrap_or(0.0),
                font: "F1".to_string(),
                font_size: parts[3].parse().unwrap_or(0.0),
                page: 1,
                is_bold: false, is_italic: false, is_underline: false, is_strikeout: false,
                item_type: ItemType::Text, mcid: None,
            });
        }
    }
    let rows = collect_anchored_rows(&items, &rules, 1);
    let mut out = format!("rows {}\n", rows.len());
    for (y, row) in &rows {
        out.push_str(&format!("r {y:.3}"));
        for (i, _) in row { out.push_str(&format!(" {i}")); }
        out.push('\n');
        let anchors = logical_row_anchors(row);
        out.push_str("a");
        for a in &anchors { out.push_str(&format!(" {a:.3}")); }
        out.push_str(&format!("\nm {}\n", matched_anchor_column_count(row, &anchors)));
        out.push_str("k");
        for (_, item) in row {
            match nearest_anchor_column(item, &anchors) {
                Some(c) => out.push_str(&format!(" {c}")),
                None => out.push_str(" -"),
            }
        }
        out.push('\n');
    }
    out
}

pub fn probe_rules(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    let mut rules: Vec<(f32, f32, f32)> = Vec::new();
    let mut items: Vec<TextItem> = Vec::new();
    let mut in_items = false;
    for line in input.lines() {
        if line.trim().is_empty() {
            in_items = true;
            continue;
        }
        let parts: Vec<&str> = line.split(' ').collect();
        if !in_items {
            if parts.len() >= 3 {
                rules.push((
                    parts[0].parse().unwrap_or(0.0),
                    parts[1].parse().unwrap_or(0.0),
                    parts[2].parse().unwrap_or(0.0),
                ));
            }
        } else if parts.len() >= 5 {
            items.push(TextItem {
                text: parts[4..].join(" "),
                x: parts[0].parse().unwrap_or(0.0),
                y: parts[1].parse().unwrap_or(0.0),
                width: parts[2].parse().unwrap_or(0.0),
                height: parts[3].parse().unwrap_or(0.0),
                font: "F1".to_string(),
                font_size: parts[3].parse().unwrap_or(0.0),
                page: 1,
                is_bold: false, is_italic: false, is_underline: false, is_strikeout: false,
                item_type: ItemType::Text, mcid: None,
            });
        }
    }

    let mut out = String::new();
    let merged = merge_horizontal_segments(&rules);
    for r in &merged {
        out.push_str(&format!("merged {:.3} {:.3} {:.3}\n", r.0, r.1, r.2));
    }
    for (i, g) in group_rules_by_span(&merged).iter().enumerate() {
        out.push_str(&format!("group {i} {}\n", g.len()));
    }
    for (i, g) in split_independent_rule_runs(&merged, &items, 1).iter().enumerate() {
        out.push_str(&format!("run {i} {}\n", g.len()));
    }
    out.push_str(&format!("uniform {}\n", rules_are_uniform_grid(&merged) as u8));
    match derive_columns_from_horizontal_segments(&merged) {
        None => out.push_str("columns none\n"),
        Some(c) => {
            out.push_str("columns");
            for x in &c { out.push_str(&format!(" {x:.3}")); }
            out.push('\n');
        }
    }
    for t in ["Table 3", "Table 12.", "table (4) x", "Tables 3", "Table x", "Table"] {
        out.push_str(&format!("caption {} {}\n", numbered_table_caption(t) as u8, t));
    }
    out
}

/// Probe (added for swift-anydoc): score and select table hypotheses.
/// Input blocks are `L|A rowY cell,cell,... ; item,item,...` — one candidate
/// per line, tagged legacy or alternative.
pub fn probe_hypotheses(input: &str) -> String {
    use crate::tables::Table;
    let mut legacy: Vec<Table> = Vec::new();
    let mut alternatives: Vec<Table> = Vec::new();
    for line in input.lines() {
        if line.trim().is_empty() { continue }
        let parts: Vec<&str> = line.splitn(4, ' ').collect();
        if parts.len() < 4 { continue }
        let tag = parts[0];
        let row_y: f32 = parts[1].parse().unwrap_or(0.0);
        let cells: Vec<Vec<String>> = parts[2]
            .split(';')
            .map(|row| row.split(',').map(|c| c.replace('_', " ").trim().to_string()).collect())
            .collect();
        let items: Vec<usize> = parts[3]
            .split(',')
            .filter_map(|t| t.trim().parse().ok())
            .collect();
        let rows = vec![row_y; cells.len().max(1)];
        let cols = vec![0.0f32; cells.first().map_or(0, Vec::len)];
        let t = Table::new(cols, rows, cells, items);
        if tag == "L" { legacy.push(t) } else { alternatives.push(t) }
    }

    let mut out = String::new();
    for t in legacy.iter().chain(alternatives.iter()) {
        out.push_str(&format!("score {}\n", table_evidence_score(t)));
    }
    let all: Vec<Table> = legacy.iter().cloned().chain(alternatives.iter().cloned()).collect();
    for t in select_non_overlapping_hypotheses(all) {
        out.push_str(&format!("sel {:?}\n", t.item_indices));
    }
    for t in select_table_hypothesis(legacy.clone(), alternatives.clone(), 1) {
        out.push_str(&format!("hyp {:?}\n", t.item_indices));
    }
    if let (Some(a), Some(b)) = (legacy.first(), alternatives.first()) {
        out.push_str(&format!("share {}\n", tables_share_items(a, b) as u8));
        out.push_str(&format!(
            "multi {}\n",
            overlaps_multiple_tables(b, &legacy) as u8
        ));
    }
    out
}
RUSTEOF

cat >> "$crate/src/tables/detect_rects.rs" <<'RUSTEOF'

/// Probe (added for swift-anydoc): cluster rects and report the grouping.
/// Input lines are `x y w h`; the first line is `tol min_size gap min_group`.
pub fn probe_clusters(input: &str) -> String {
    let mut lines = input.lines();
    let header: Vec<f32> = lines
        .next()
        .unwrap_or("")
        .split_whitespace()
        .filter_map(|t| t.parse().ok())
        .collect();
    if header.len() < 4 {
        return String::new();
    }
    let (tol, min_size, gap, min_group) =
        (header[0], header[1] as usize, header[2], header[3] as usize);

    let mut rects: Vec<(f32, f32, f32, f32)> = Vec::new();
    for line in lines {
        let v: Vec<f32> = line.split_whitespace().filter_map(|t| t.parse().ok()).collect();
        if v.len() >= 4 {
            rects.push((v[0], v[1], v[2], v[3]));
        }
    }

    let mut out = String::new();
    for (i, g) in cluster_rects(&rects, tol, min_size).iter().enumerate() {
        out.push_str(&format!("group {i} {:?}\n", g));
    }
    if rects.len() >= 2 {
        out.push_str(&format!(
            "overlap {}\n",
            rects_overlap(&rects[0], &rects[1], tol) as u8
        ));
    }
    match split_wide_cluster(&rects, gap, min_group) {
        None => out.push_str("split none\n"),
        Some((l, r)) => out.push_str(&format!("split {} {}\n", l.len(), r.len())),
    }
    out
}

/// Probe (added for swift-anydoc): assign items to a grid.
/// Line 1: column edges. Line 2: row edges. Then `x y w size text` items.
pub fn probe_assign(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    let mut lines = input.lines();
    let cols: Vec<f32> = lines.next().unwrap_or("").split_whitespace()
        .filter_map(|t| t.parse().ok()).collect();
    let rows: Vec<f32> = lines.next().unwrap_or("").split_whitespace()
        .filter_map(|t| t.parse().ok()).collect();
    let mut items: Vec<TextItem> = Vec::new();
    for line in lines {
        let p: Vec<&str> = line.splitn(5, ' ').collect();
        if p.len() < 5 { continue }
        items.push(TextItem {
            text: p[4].to_string(),
            x: p[0].parse().unwrap_or(0.0),
            y: p[1].parse().unwrap_or(0.0),
            width: p[2].parse().unwrap_or(0.0),
            height: p[3].parse().unwrap_or(0.0),
            font: "F1".to_string(),
            font_size: p[3].parse().unwrap_or(0.0),
            page: 1,
            is_bold: false, is_italic: false, is_underline: false, is_strikeout: false,
            item_type: ItemType::Text, mcid: None,
        });
    }
    let mut out = String::new();
    if cols.len() >= 2 && rows.len() >= 2 {
        let (cells, indices) = assign_items_to_grid(&items, &cols, &rows, 1);
        for row in &cells {
            out.push_str(&format!("cell\t{}\n", row.join("\t")));
        }
        out.push_str(&format!("idx {:?}\n", indices));
    } else {
        out.push_str("skip\n");
    }
    for t in ["a ( b )", "a (b)", "x [ 1 ] y", "{ z }", "no brackets", "( )"] {
        out.push_str(&format!("delim {}|{}\n", t, remove_inner_delimiter_spaces(t)));
    }
    out
}

/// Probe (added for swift-anydoc): the cluster loop, tables only.
pub fn probe_rect_tables(input: &str) -> String {
    use crate::types::{ItemType, PdfRect, TextItem};
    let mut rects: Vec<PdfRect> = Vec::new();
    let mut items: Vec<TextItem> = Vec::new();
    for line in input.lines().skip(1) {
        let p: Vec<&str> = line.splitn(6, ' ').collect();
        if p.len() >= 5 && p[0] == "R" {
            rects.push(PdfRect {
                x: p[1].parse().unwrap_or(0.0), y: p[2].parse().unwrap_or(0.0),
                width: p[3].parse().unwrap_or(0.0), height: p[4].parse().unwrap_or(0.0),
                page: 1,
            });
        } else if p.len() >= 6 && p[0] == "I" {
            items.push(TextItem {
                text: p[5].to_string(),
                x: p[1].parse().unwrap_or(0.0), y: p[2].parse().unwrap_or(0.0),
                width: p[3].parse().unwrap_or(0.0), height: p[4].parse().unwrap_or(0.0),
                font: "F1".to_string(), font_size: p[4].parse().unwrap_or(0.0), page: 1,
                is_bold: false, is_italic: false, is_underline: false, is_strikeout: false,
                item_type: ItemType::Text, mcid: None,
            });
        }
    }
    let (tables, hints) = detect_tables_from_rects(&items, &rects, 1);
    let mut out = format!("tables {}\n", tables.len());
    for t in &tables {
        out.push_str(&format!("t {} {}\nc", t.columns.len(), t.rows.len()));
        for v in &t.columns { out.push_str(&format!(" {v:.3}")); }
        out.push_str("\nw");
        for v in &t.rows { out.push_str(&format!(" {v:.3}")); }
        out.push('\n');
        for row in &t.cells {
            out.push('x');
            for c in row { out.push('\t'); out.push_str(c); }
            out.push('\n');
        }
        out.push_str(&format!("n {}\n", t.item_indices.len()));
    }
    out.push_str(&format!("hints {}\n", hints.len()));
    for h in &hints {
        out.push_str(&format!(
            "h {:.3} {:.3} {:.3} {:.3} {}\n",
            h.y_top, h.y_bottom, h.x_left, h.x_right, h.cluster_rects.len()
        ));
    }
    let charts = detect_chart_regions(&items, &rects, 1);
    out.push_str(&format!("charts {}\n", charts.len()));
    for c in &charts {
        out.push_str(&format!("g {:.3} {:.3} {:.3} {:.3}\n", c.0, c.1, c.2, c.3));
    }
    out
}

/// Probe (added for swift-anydoc): the whole cell-rect stripe strategy.
pub fn probe_cell_stripe(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    let mut rects: Vec<(f32, f32, f32, f32)> = Vec::new();
    let mut items: Vec<TextItem> = Vec::new();
    for line in input.lines().skip(1) {
        let p: Vec<&str> = line.splitn(6, ' ').collect();
        if p.len() >= 5 && p[0] == "R" {
            rects.push((
                p[1].parse().unwrap_or(0.0), p[2].parse().unwrap_or(0.0),
                p[3].parse().unwrap_or(0.0), p[4].parse().unwrap_or(0.0),
            ));
        } else if p.len() >= 6 && p[0] == "I" {
            items.push(TextItem {
                text: p[5].to_string(),
                x: p[1].parse().unwrap_or(0.0), y: p[2].parse().unwrap_or(0.0),
                width: p[3].parse().unwrap_or(0.0), height: p[4].parse().unwrap_or(0.0),
                font: "F1".to_string(), font_size: p[4].parse().unwrap_or(0.0), page: 1,
                is_bold: false, is_italic: false, is_underline: false, is_strikeout: false,
                item_type: ItemType::Text, mcid: None,
            });
        }
    }
    match detect_row_stripe_table_from_cell_rects(&items, &rects, 1) {
        None => "cellstripe none\n".to_string(),
        Some(t) => {
            let mut out = format!("cellstripe {} {}\nc", t.columns.len(), t.rows.len());
            for v in &t.columns { out.push_str(&format!(" {v:.3}")); }
            out.push_str("\nw");
            for v in &t.rows { out.push_str(&format!(" {v:.3}")); }
            out.push('\n');
            for row in &t.cells {
                out.push('x');
                for c in row { out.push('\t'); out.push_str(c); }
                out.push('\n');
            }
            out.push_str(&format!("n {}\n", t.item_indices.len()));
            out
        }
    }
}

/// Probe (added for swift-anydoc): wrapped-description-row collapsing.
pub fn probe_collapse(input: &str) -> String {
    let mut row_edges: Vec<f32> = Vec::new();
    let mut col_edges: Vec<f32> = Vec::new();
    let mut cells: Vec<Vec<String>> = Vec::new();
    for line in input.lines().skip(1) {
        if let Some(rest) = line.strip_prefix("E ") {
            row_edges = rest.split(' ').filter_map(|v| v.parse().ok()).collect();
        } else if let Some(rest) = line.strip_prefix("X ") {
            col_edges = rest.split(' ').filter_map(|v| v.parse().ok()).collect();
        } else if let Some(rest) = line.strip_prefix("R\t") {
            cells.push(rest.split('\t').map(|c| c.replace('~', " ")).collect());
        } else if line == "R\t" || line == "R" {
            cells.push(Vec::new());
        }
    }
    let (out_cells, out_edges, wrapped) =
        collapse_multiline_description_rows(cells, row_edges, &col_edges);
    let mut out = format!("wrapped {wrapped}\ne");
    for v in &out_edges { out.push_str(&format!(" {v:.3}")); }
    out.push('\n');
    for row in &out_cells {
        out.push('r');
        for c in row { out.push('\t'); out.push_str(c); }
        out.push('\n');
    }
    out
}

/// Probe (added for swift-anydoc): the row-edge derivation at the head of
/// `detect_row_stripe_table_from_cell_rects`, reproduced here because that
/// function is being ported in stages.
pub fn probe_cell_rows(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    let mut rects: Vec<(f32, f32, f32, f32)> = Vec::new();
    let mut items: Vec<TextItem> = Vec::new();
    for line in input.lines().skip(1) {
        let p: Vec<&str> = line.splitn(6, ' ').collect();
        if p.len() >= 5 && p[0] == "R" {
            rects.push((
                p[1].parse().unwrap_or(0.0), p[2].parse().unwrap_or(0.0),
                p[3].parse().unwrap_or(0.0), p[4].parse().unwrap_or(0.0),
            ));
        } else if p.len() >= 6 && p[0] == "I" {
            items.push(TextItem {
                text: p[5].to_string(),
                x: p[1].parse().unwrap_or(0.0), y: p[2].parse().unwrap_or(0.0),
                width: p[3].parse().unwrap_or(0.0), height: p[4].parse().unwrap_or(0.0),
                font: "F1".to_string(), font_size: p[4].parse().unwrap_or(0.0), page: 1,
                is_bold: false, is_italic: false, is_underline: false, is_strikeout: false,
                item_type: ItemType::Text, mcid: None,
            });
        }
    }
    let mut y_edges: Vec<f32> = Vec::new();
    for &(_, y, _, h) in &rects { y_edges.push(y); y_edges.push(y + h); }
    let y_edges = snap_edges(&y_edges, 6.0);
    let row_edges: Option<Vec<f32>> = if y_edges.len() >= 4 {
        let mut e = y_edges; e.sort_by(|a, b| b.total_cmp(a)); Some(e)
    } else {
        let y_min = y_edges.first().copied().unwrap_or(0.0);
        let y_max = y_edges.last().copied().unwrap_or(0.0);
        let x_min = rects.iter().map(|r| r.0).reduce(f32::min).unwrap_or(0.0);
        let x_max = rects.iter().map(|r| r.0 + r.2).reduce(f32::max).unwrap_or(0.0);
        let region: Vec<&TextItem> = items.iter().filter(|i| {
            i.page == 1 && i.y >= y_min - 5.0 && i.y <= y_max + 5.0
                && i.x >= x_min - 5.0 && i.x <= x_max + 5.0
        }).collect();
        if region.len() < 4 { None } else {
            let median_h = {
                let mut hs: Vec<f32> = region.iter().map(|i| i.height).collect();
                hs.sort_by(|a, b| a.total_cmp(b));
                hs[hs.len() / 2]
            };
            let mut ys: Vec<f32> = region.iter().map(|i| i.y).collect();
            ys.sort_by(|a, b| b.total_cmp(a));
            let mut edges = Vec::new();
            let threshold = median_h * 0.8;
            let mut cluster_sum = ys[0];
            let mut cluster_count = 1.0f32;
            for &y in &ys[1..] {
                if (cluster_sum / cluster_count - y).abs() > threshold {
                    let c = cluster_sum / cluster_count;
                    edges.push(c + median_h * 0.5);
                    edges.push(c - median_h * 0.5);
                    cluster_sum = y; cluster_count = 1.0;
                } else { cluster_sum += y; cluster_count += 1.0; }
            }
            let c = cluster_sum / cluster_count;
            edges.push(c + median_h * 0.5);
            edges.push(c - median_h * 0.5);
            let mut e = snap_edges(&edges, 3.0);
            e.sort_by(|a, b| b.total_cmp(a));
            if e.len() < 4 { None } else { Some(e) }
        }
    };
    match row_edges {
        None => "rows none\n".to_string(),
        Some(e) => {
            let mut out = String::from("rows");
            for v in &e { out.push_str(&format!(" {v:.3}")); }
            out.push('\n');
            out
        }
    }
}

/// Probe (added for swift-anydoc): the rect preprocessing pipeline, mirroring
/// the filtering inline at the top of `detect_tables_from_rects`.
pub fn probe_prepare(input: &str) -> String {
    let mut raw: Vec<(f32, f32, f32, f32)> = Vec::new();
    for line in input.lines().skip(1) {
        let p: Vec<&str> = line.splitn(6, ' ').collect();
        if p.len() >= 5 && p[0] == "R" {
            raw.push((
                p[1].parse().unwrap_or(0.0), p[2].parse().unwrap_or(0.0),
                p[3].parse().unwrap_or(0.0), p[4].parse().unwrap_or(0.0),
            ));
        }
    }
    let mut page_rects: Vec<(f32, f32, f32, f32)> = Vec::new();
    for r in &raw {
        let (mut x, mut y, mut w, mut h) = *r;
        if w < 0.0 { x += w; w = -w; }
        if h < 0.0 { y += h; h = -h; }
        if w < 5.0 || h < 5.0 { continue }
        page_rects.push((x, y, w, h));
    }
    if page_rects.len() >= 6 {
        let mut widths: Vec<f32> = page_rects.iter().map(|&(_, _, w, _)| w).collect();
        widths.sort_by(|a, b| a.total_cmp(b));
        let threshold = widths[widths.len() / 2] * 10.0;
        page_rects.retain(|&(_, _, w, _)| w <= threshold);
        if page_rects.len() < MAX_CLUSTER_RECTS {
            let snapshot = page_rects.clone();
            page_rects.retain(|&(ax, ay, aw, ah)| {
                let tol = 2.0;
                !snapshot.iter().any(|&(bx, by, bw, bh)| {
                    let container_is_page_bg = bx < 5.0 && by < 5.0;
                    bw * bh > aw * ah * 1.2
                        && bh < ah * 4.0
                        && !container_is_page_bg
                        && bx <= ax + tol
                        && (bx + bw) >= (ax + aw) - tol
                        && by <= ay + tol
                        && (by + bh) >= (ay + ah) - tol
                })
            });
        }
    }
    let mut out = String::new();
    for r in &page_rects {
        out.push_str(&format!("p {:.3} {:.3} {:.3} {:.3}\n", r.0, r.1, r.2, r.3));
    }
    out
}

/// Probe (added for swift-anydoc): row-stripe table detection.
/// Same input shape as --gridbuild.
pub fn probe_stripe(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    let mut rects: Vec<(f32, f32, f32, f32)> = Vec::new();
    let mut items: Vec<TextItem> = Vec::new();
    for line in input.lines().skip(1) {
        let p: Vec<&str> = line.splitn(6, ' ').collect();
        if p.len() >= 5 && p[0] == "R" {
            rects.push((
                p[1].parse().unwrap_or(0.0), p[2].parse().unwrap_or(0.0),
                p[3].parse().unwrap_or(0.0), p[4].parse().unwrap_or(0.0),
            ));
        } else if p.len() >= 6 && p[0] == "I" {
            items.push(TextItem {
                text: p[5].to_string(),
                x: p[1].parse().unwrap_or(0.0), y: p[2].parse().unwrap_or(0.0),
                width: p[3].parse().unwrap_or(0.0), height: p[4].parse().unwrap_or(0.0),
                font: "F1".to_string(), font_size: p[4].parse().unwrap_or(0.0), page: 1,
                is_bold: false, is_italic: false, is_underline: false, is_strikeout: false,
                item_type: ItemType::Text, mcid: None,
            });
        }
    }
    let indexed: Vec<(usize, &TextItem)> = items.iter().enumerate().collect();
    let mut out = String::new();
    out.push_str("cols");
    for c in cluster_x_positions(&indexed, 15.0) {
        out.push_str(&format!(" {c:.3}"));
    }
    out.push('\n');
    match detect_direct_rect_table(&items, &rects, 1) {
        None => out.push_str("direct none\n"),
        Some(t) => out.push_str(&format!("direct {} {}\n", t.columns.len(), t.rows.len())),
    }
    match detect_merged_cluster_table(&items, &rects, 1) {
        None => out.push_str("merged none\n"),
        Some(t) => {
            out.push_str(&format!("merged {} {}\n", t.columns.len(), t.rows.len()));
            for row in &t.cells {
                out.push_str(&format!("m\t{}\n", row.join("\t")));
            }
        }
    }
    match detect_stacked_box_table(&items, &rects, 1) {
        None => out.push_str("stack none\n"),
        Some(t) => {
            out.push_str(&format!("stack {}\n", t.rows.len()));
            for row in &t.cells {
                out.push_str(&format!("k\t{}\n", row.join("\t")));
            }
        }
    }
    match detect_row_stripe_table(&items, &rects, 1) {
        None => out.push_str("stripe none\n"),
        Some(t) => {
            out.push_str(&format!("stripe {} {}\n", t.columns.len(), t.rows.len()));
            for row in &t.cells {
                out.push_str(&format!("s\t{}\n", row.join("\t")));
            }
        }
    }
    out
}

/// Probe (added for swift-anydoc): classify a rect cluster.
/// Same input shape as --gridbuild.
pub fn probe_classify(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    let mut rects: Vec<(f32, f32, f32, f32)> = Vec::new();
    let mut items: Vec<TextItem> = Vec::new();
    for line in input.lines().skip(1) {
        let p: Vec<&str> = line.splitn(6, ' ').collect();
        if p.len() >= 5 && p[0] == "R" {
            rects.push((
                p[1].parse().unwrap_or(0.0), p[2].parse().unwrap_or(0.0),
                p[3].parse().unwrap_or(0.0), p[4].parse().unwrap_or(0.0),
            ));
        } else if p.len() >= 6 && p[0] == "I" {
            items.push(TextItem {
                text: p[5].to_string(),
                x: p[1].parse().unwrap_or(0.0), y: p[2].parse().unwrap_or(0.0),
                width: p[3].parse().unwrap_or(0.0), height: p[4].parse().unwrap_or(0.0),
                font: "F1".to_string(), font_size: p[4].parse().unwrap_or(0.0), page: 1,
                is_bold: false, is_italic: false, is_underline: false, is_strikeout: false,
                item_type: ItemType::Text, mcid: None,
            });
        }
    }
    let kept = without_dominant_page_backgrounds(&rects);
    format!(
        "stripe {}\nchart {}\nkept {}\n",
        is_row_stripe_pattern(&rects) as u8,
        is_chart_bar_cluster(&items, &rects, 1) as u8,
        kept.len()
    )
}

/// Probe (added for swift-anydoc): build a grid from a rect cluster.
/// Line 1: `strict skip0,skip1,...`. Then `R x y w h` rects and
/// `I x y w size text` items.
pub fn probe_grid_build(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    let mut lines = input.lines();
    let header: Vec<&str> = lines.next().unwrap_or("").split_whitespace().collect();
    let strict = header.first().map_or(false, |t| *t == "1");
    let skip_spec: Vec<bool> = header
        .get(1)
        .map(|s| s.split(',').map(|t| t == "1").collect())
        .unwrap_or_default();

    let mut rects: Vec<(f32, f32, f32, f32)> = Vec::new();
    let mut items: Vec<TextItem> = Vec::new();
    for line in lines {
        let p: Vec<&str> = line.splitn(6, ' ').collect();
        if p.len() >= 5 && p[0] == "R" {
            rects.push((
                p[1].parse().unwrap_or(0.0), p[2].parse().unwrap_or(0.0),
                p[3].parse().unwrap_or(0.0), p[4].parse().unwrap_or(0.0),
            ));
        } else if p.len() >= 6 && p[0] == "I" {
            items.push(TextItem {
                text: p[5].to_string(),
                x: p[1].parse().unwrap_or(0.0), y: p[2].parse().unwrap_or(0.0),
                width: p[3].parse().unwrap_or(0.0), height: p[4].parse().unwrap_or(0.0),
                font: "F1".to_string(), font_size: p[4].parse().unwrap_or(0.0), page: 1,
                is_bold: false, is_italic: false, is_underline: false, is_strikeout: false,
                item_type: ItemType::Text, mcid: None,
            });
        }
    }
    let mut skip = vec![false; rects.len()];
    for (i, v) in skip_spec.iter().enumerate() {
        if i < skip.len() { skip[i] = *v }
    }

    match try_build_grid(&items, &rects, 1, &skip, strict) {
        GridResult::Failed => "failed\n".to_string(),
        GridResult::FewNonEmptyRows => "fewrows\n".to_string(),
        GridResult::Ok(t) => {
            let mut out = format!("ok {} {} {:?}\n", t.columns.len(), t.rows.len(), t.kind);
            for row in &t.cells {
                out.push_str(&format!("c\t{}\n", row.join("\t")));
            }
            out.push_str(&format!("idx {:?}\n", t.item_indices));
            out
        }
    }
}
RUSTEOF

mkdir -p "$crate/src/bin"
cat > "$crate/src/bin/graphicsprobe.rs" <<'RUSTEOF'
// Dumps the reference's path-extraction output for one PDF.
fn main() {
    let mut args = std::env::args().skip(1);
    let path = args.next().expect("usage: graphicsprobe [--underline] <file.pdf>");
    if path == "--format" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::format::probe_format(&input));
        return;
    }
    if path == "--recttables" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_rects::probe_rect_tables(&input));
        return;
    }
    if path == "--cellstripe" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_rects::probe_cell_stripe(&input));
        return;
    }
    if path == "--collapse" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_rects::probe_collapse(&input));
        return;
    }
    if path == "--cellrows" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_rects::probe_cell_rows(&input));
        return;
    }
    if path == "--prepare" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_rects::probe_prepare(&input));
        return;
    }
    if path == "--stripe" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_rects::probe_stripe(&input));
        return;
    }
    if path == "--classify" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_rects::probe_classify(&input));
        return;
    }
    if path == "--gridbuild" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_rects::probe_grid_build(&input));
        return;
    }
    if path == "--assign" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_rects::probe_assign(&input));
        return;
    }
    if path == "--rects" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_rects::probe_clusters(&input));
        return;
    }
    if path == "--hyp" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_lines::probe_hypotheses(&input));
        return;
    }
    if path == "--openedge" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_lines::probe_openedge(&input));
        return;
    }
    if path == "--anchors" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_lines::probe_anchors(&input));
        return;
    }
    if path == "--rules" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_lines::probe_rules(&input));
        return;
    }
    if path == "--detect" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::grid::probe_detect(&input));
        return;
    }
    if path == "--grid" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::grid::probe_grid(&input));
        return;
    }
    let (underline, path) = if path == "--underline" {
        (true, args.next().expect("usage: graphicsprobe --underline <file.pdf>"))
    } else {
        (false, path)
    };
    let bytes = std::fs::read(&path).expect("read");
    let dump = if underline {
        pdf_inspector::extractor::content_stream::probe_underline(&bytes)
    } else {
        pdf_inspector::extractor::content_stream::probe_graphics(&bytes)
    };
    print!("{dump}");
}
RUSTEOF

(cd "$crate" && cargo build --release --offline --bin graphicsprobe)
echo "graphics oracle: $crate/target/release/graphicsprobe"
