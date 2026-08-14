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

# `structure_tree` is private as well.
perl -pi -e "s/^pub\\(crate\\) mod detect_struct;/pub mod detect_struct;/; s/^mod detect_struct;/pub mod detect_struct;/" \
    "$crate/src/tables/mod.rs"
perl -pi -e "s/^fn (infer_column_positions|align_positions_to_columns|align_struct_rows|left_align_struct_rows|recover_unclaimed_header_row|legacy_column_positions)/pub fn \$1/" \
    "$crate/src/tables/detect_struct.rs"
perl -pi -e "s/^fn (collect_tables|collect_rows|collect_mcids_recursive|flatten_recursive)/pub fn \$1/; s/^    fn from_name/    pub fn from_name/" \
    "$crate/src/structure_tree.rs"
perl -pi -e "s/^mod structure_tree;/pub mod structure_tree;/; s/^pub\\(crate\\) mod structure_tree;/pub mod structure_tree;/" \
    "$crate/src/lib.rs"

# `text_utils` is private too.
perl -pi -e "s/^pub\\(crate\\) fn expand_ligatures/pub fn expand_ligatures/" \
    "$crate/src/text_utils.rs"
perl -pi -e "s/^mod text_utils;/pub mod text_utils;/; s/^pub\\(crate\\) mod text_utils;/pub mod text_utils;/" \
    "$crate/src/lib.rs"

# `text_quality` is private, and the probe below reads CipherGarbleStats.
perl -pi -e "s/^mod text_quality;/pub mod text_quality;/; s/^pub\\(crate\\) mod text_quality;/pub mod text_quality;/" \
    "$crate/src/lib.rs"

# `detector` is already a public module and the probe below lives inside it,
# so its private helpers and `PageAnalysis` need no widening at all.

# `fonts` is a private submodule of `extractor`, and the probe below reaches
# `parse_encoding_dictionary` and `EncodingResult`.
perl -pi -e "s/^pub\\(crate\\) mod fonts;/pub mod fonts;/; s/^mod fonts;/pub mod fonts;/" \
    "$crate/src/extractor/mod.rs"
perl -pi -e "s/^pub\\(crate\\) fn parse_encoding_dictionary/pub fn parse_encoding_dictionary/; s/^pub\\(crate\\) struct EncodingResult/pub struct EncodingResult/; s/^struct EncodingResult/pub struct EncodingResult/" \
    "$crate/src/extractor/fonts.rs"

# `layout` is a private submodule of `extractor`; the probe below lives inside
# it, so only the module itself needs widening.
perl -pi -e "s/^pub\\(crate\\) mod layout;/pub mod layout;/; s/^mod layout;/pub mod layout;/" \
    "$crate/src/extractor/mod.rs"

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
perl -pi -e "s/^pub\\(crate\\) fn detect_vector_grid_tables_from_lines/pub fn detect_vector_grid_tables_from_lines/" \
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
/// Probe (added for swift-anydoc): the marked-content id in effect for each
/// extracted text item.
pub fn probe_mcid(bytes: &[u8]) -> String {
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
            Ok(((items, _, _), _, _)) => {
                out.push_str(&format!("#PAGE {n}\n"));
                for item in &items {
                    out.push_str(&format!(
                        "m {} {:.3} {:.3} {:.3} {:.3} {}\n",
                        item.mcid.map(|v| v.to_string()).unwrap_or_else(|| "-".to_string()),
                        item.x,
                        item.y,
                        item.width,
                        item.font_size,
                        item.text.replace(' ', "~")
                    ));
                }
            }
            Err(e) => out.push_str(&format!("#PAGE {n} error={e:?}\n")),
        }
    }
    out
}

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

cat >> "$crate/src/tables/detect_struct.rs" <<'RUSTEOF'

/// Probe (added for swift-anydoc): the struct-tree table orchestrator. A
/// case is `T` to open a table, `R` to open a row, `D header mcid:page,...`
/// cells, and `I x y mcid text` items.
pub fn probe_structtables(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    use crate::structure_tree::{StructTable, StructTableCell, StructTableRow};
    let mut tables: Vec<StructTable> = Vec::new();
    let mut items: Vec<TextItem> = Vec::new();

    for line in input.lines() {
        let (tag, rest) = line.split_at(line.find(' ').map(|i| i + 1).unwrap_or(line.len()));
        let rest = rest.trim();
        match tag.trim() {
            "T" => tables.push(StructTable { rows: Vec::new() }),
            "R" => {
                if let Some(t) = tables.last_mut() {
                    t.rows.push(StructTableRow { cells: Vec::new() });
                }
            }
            "D" => {
                let f: Vec<&str> = rest.splitn(2, ' ').collect();
                let is_header = f[0] == "1";
                let mut mcids = Vec::new();
                if f.len() > 1 && f[1] != "-" {
                    for entry in f[1].split(',') {
                        let bits: Vec<&str> = entry.split(':').collect();
                        if bits.len() == 2 {
                            mcids.push((
                                bits[0].parse().unwrap_or(0),
                                bits[1].parse().unwrap_or(0),
                            ));
                        }
                    }
                }
                if let Some(t) = tables.last_mut() {
                    if let Some(r) = t.rows.last_mut() {
                        r.cells.push(StructTableCell { is_header, mcids });
                    }
                }
            }
            "I" => {
                let f: Vec<&str> = rest.splitn(4, ' ').collect();
                if f.len() >= 4 {
                    let mcid: i64 = f[2].parse().unwrap_or(-1);
                    items.push(TextItem {
                        text: f[3].replace('~', " "),
                        x: f[0].parse().unwrap_or(0.0),
                        y: f[1].parse().unwrap_or(0.0),
                        width: 20.0,
                        height: 10.0,
                        font: "F1".to_string(),
                        font_size: 10.0,
                        page: 1,
                        is_bold: false, is_italic: false, is_underline: false,
                        is_strikeout: false, item_type: ItemType::Text,
                        mcid: if mcid < 0 { None } else { Some(mcid) },
                    });
                }
            }
            _ => {}
        }
    }

    let built = detect_tables_from_struct_tree(&items, &tables, 1);
    let mut out = format!("tables {}\n", built.len());
    for table in &built {
        out.push_str(&format!("t {} {}\nk", table.columns.len(), table.rows.len()));
        for value in &table.columns { out.push_str(&format!(" {value:.3}")); }
        out.push_str("\ny");
        for value in &table.rows { out.push_str(&format!(" {value:.3}")); }
        out.push('\n');
        for row in &table.cells {
            out.push('c');
            for cell in row { out.push('\t'); out.push_str(cell); }
            out.push('\n');
        }
        out.push('x');
        for value in &table.item_indices { out.push_str(&format!(" {value}")); }
        out.push('\n');
    }
    out
}

/// Probe (added for swift-anydoc): unclaimed-header recovery. A case is
/// `G ragged`, `C cols`, `Y rows`, `X claimed`, `E cells...` rows, then
/// `I x y text` items.
pub fn probe_structheader(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    let mut ragged = false;
    let mut columns: Vec<f32> = Vec::new();
    let mut rows: Vec<f32> = Vec::new();
    let mut claimed: Vec<usize> = Vec::new();
    let mut cells: Vec<Vec<String>> = Vec::new();
    let mut items: Vec<TextItem> = Vec::new();

    for line in input.lines() {
        let (tag, rest) = line.split_at(line.find(' ').map(|i| i + 1).unwrap_or(line.len()));
        let rest = rest.trim();
        match tag.trim() {
            "G" => ragged = rest == "1",
            "C" => columns = rest.split(',').filter_map(|v| v.parse().ok()).collect(),
            "Y" => rows = rest.split(',').filter_map(|v| v.parse().ok()).collect(),
            "X" => claimed = rest.split(',').filter_map(|v| v.parse().ok()).collect(),
            "E" => cells.push(
                if rest.is_empty() { Vec::new() }
                else { rest.split('\t').map(|c| c.replace('~', " ")).collect() }
            ),
            "I" => {
                let f: Vec<&str> = rest.splitn(3, ' ').collect();
                if f.len() >= 3 {
                    items.push(TextItem {
                        text: f[2].replace('~', " "),
                        x: f[0].parse().unwrap_or(0.0),
                        y: f[1].parse().unwrap_or(0.0),
                        width: 20.0,
                        height: 10.0,
                        font: "F1".to_string(),
                        font_size: 10.0,
                        page: 1,
                        is_bold: false, is_italic: false, is_underline: false,
                        is_strikeout: false, item_type: ItemType::Text, mcid: None,
                    });
                }
            }
            _ => {}
        }
    }

    let mut table = Table::new(columns, rows, cells, claimed);
    recover_unclaimed_header_row(&mut table, &items, ragged);

    let mut out = format!("h {} {}\ny", table.rows.len(), table.cells.len());
    for value in &table.rows { out.push_str(&format!(" {value:.3}")); }
    out.push('\n');
    for row in &table.cells {
        out.push('c');
        for cell in row { out.push('\t'); out.push_str(cell); }
        out.push('\n');
    }
    out.push('x');
    for value in &table.item_indices { out.push_str(&format!(" {value}")); }
    out.push('\n');
    out
}

/// Probe (added for swift-anydoc): the two row-alignment strategies. A case
/// is `C x,x` column positions, `N count`, then `R` rows of
/// `text:items:x:y` cells (`-` for absent).
pub fn probe_structrows(input: &str) -> String {
    let mut columns: Vec<f32> = Vec::new();
    let mut num_cols = 0usize;
    let mut rows: Vec<Vec<MatchedCell>> = Vec::new();

    for line in input.lines() {
        let (tag, rest) = line.split_at(line.find(' ').map(|i| i + 1).unwrap_or(line.len()));
        match tag.trim() {
            "C" => {
                columns = rest.trim().split(',').filter_map(|v| v.parse().ok()).collect()
            }
            "N" => num_cols = rest.trim().parse().unwrap_or(0),
            "R" => {
                let mut row = Vec::new();
                if !rest.trim().is_empty() {
                    for spec in rest.trim().split(' ') {
                        let f: Vec<&str> = spec.split(':').collect();
                        if f.len() < 4 { continue; }
                        row.push(MatchedCell {
                            text: if f[0] == "-" { String::new() } else { f[0].replace('~', " ") },
                            item_indices: if f[1] == "-" {
                                Vec::new()
                            } else {
                                f[1].split('.').filter_map(|v| v.parse().ok()).collect()
                            },
                            x: if f[2] == "-" { None } else { f[2].parse().ok() },
                            y: if f[3] == "-" { None } else { f[3].parse().ok() },
                        });
                    }
                }
                rows.push(row);
            }
            _ => {}
        }
    }

    fn dump(out: &mut String, tag: &str,
            result: (Vec<Vec<String>>, Vec<f32>, Vec<usize>)) {
        let (cells, positions, indices) = result;
        out.push_str(&format!("{tag} {}\n", cells.len()));
        for row in &cells {
            out.push('c');
            for cell in row { out.push('\t'); out.push_str(cell); }
            out.push('\n');
        }
        out.push('y');
        for value in &positions { out.push_str(&format!(" {value:.3}")); }
        out.push_str("\nx");
        for value in &indices { out.push_str(&format!(" {value}")); }
        out.push('\n');
    }

    let mut out = String::new();
    dump(&mut out, "aligned", align_struct_rows(&rows, &columns));
    dump(&mut out, "left", left_align_struct_rows(&rows, num_cols));
    out
}

/// Probe (added for swift-anydoc): column inference and the DP alignment.
/// A case is `R x,x,-,x` rows, then `F x,x` fallback, `N count`, and
/// `A x,x | c,c` alignment pairs.
pub fn probe_structcols(input: &str) -> String {
    let mut rows: Vec<Vec<MatchedCell>> = Vec::new();
    let mut fallback: Vec<f32> = Vec::new();
    let mut num_cols = 0usize;
    let mut out = String::new();

    fn parse_list(text: &str) -> Vec<Option<f32>> {
        if text.is_empty() { return Vec::new(); }
        text.split(',')
            .map(|v| if v == "-" { None } else { v.parse().ok() })
            .collect()
    }

    for line in input.lines() {
        let (tag, rest) = line.split_at(line.find(' ').map(|i| i + 1).unwrap_or(line.len()));
        match tag.trim() {
            "R" => rows.push(
                parse_list(rest.trim())
                    .into_iter()
                    .map(|x| MatchedCell {
                        text: String::new(),
                        item_indices: Vec::new(),
                        x,
                        y: None,
                    })
                    .collect(),
            ),
            "F" => fallback = parse_list(rest.trim()).into_iter().flatten().collect(),
            "N" => num_cols = rest.trim().parse().unwrap_or(0),
            "A" => {
                let halves: Vec<&str> = rest.trim().split('|').collect();
                if halves.len() == 2 {
                    let cells: Vec<f32> =
                        parse_list(halves[0].trim()).into_iter().flatten().collect();
                    let cols: Vec<f32> =
                        parse_list(halves[1].trim()).into_iter().flatten().collect();
                    let assigned = align_positions_to_columns(&cells, &cols);
                    out.push_str("a");
                    for value in &assigned { out.push_str(&format!(" {value}")); }
                    out.push('\n');
                }
            }
            _ => {}
        }
    }

    let inferred = infer_column_positions(&rows, &fallback, num_cols);
    out.push_str("i");
    for value in &inferred { out.push_str(&format!(" {value:.3}")); }
    out.push('\n');
    out
}
RUSTEOF

cat >> "$crate/src/structure_tree.rs" <<'RUSTEOF'

/// Probe (added for swift-anydoc): the parsed structure tree of a document,
/// flattened so nesting, roles, pages and content refs can all be compared.
pub fn probe_structparse(bytes: &[u8]) -> String {
    let doc = match lopdf::Document::load_mem(bytes) {
        Ok(d) => d,
        Err(e) => return format!("#ERROR {e:?}\n"),
    };
    let Some(tree) = StructTree::from_doc(&doc) else {
        return "#NONE\n".to_string();
    };
    let mut flat = Vec::new();
    flatten_recursive(&tree.children, &mut flat, 0);
    let mut out = format!("#TREE {}\n", flat.len());
    for element in &flat {
        out.push_str(&format!(
            "e {} {:?} {} {}",
            element.depth,
            element.role,
            element.child_count,
            element.alt_text.as_deref().unwrap_or("-")
        ));
        for reference in &element.content_refs {
            out.push_str(&format!(
                " {}:{}",
                reference.mcid,
                reference.page_id.map(|id| id.0.to_string()).unwrap_or_else(|| "-".into())
            ));
        }
        out.push('\n');
    }
    out
}

/// Probe (added for swift-anydoc): the pure tree walks. A case is a list of
/// `depth role mcid:page,...` lines describing the tree in document order.
pub fn probe_structtree(input: &str) -> String {
    fn build(lines: &[(usize, StructElement)], index: &mut usize, depth: usize)
        -> Vec<StructElement>
    {
        let mut out = Vec::new();
        while *index < lines.len() && lines[*index].0 == depth {
            let mut element = lines[*index].1.clone();
            *index += 1;
            element.children = build(lines, index, depth + 1);
            out.push(element);
        }
        out
    }

    let mut flat: Vec<(usize, StructElement)> = Vec::new();
    let mut obj_to_page: std::collections::HashMap<ObjectId, u32> =
        std::collections::HashMap::new();
    for line in input.lines() {
        let parts: Vec<&str> = line.split(' ').collect();
        if parts.len() < 2 { continue; }
        let depth: usize = parts[0].parse().unwrap_or(0);
        let mut element = StructElement {
            role: StructRole::from_name(parts[1]),
            alt_text: if parts.len() > 3 && parts[3] != "-" {
                Some(parts[3].to_string())
            } else { None },
            actual_text: None,
            lang: None,
            content_refs: Vec::new(),
            children: Vec::new(),
        };
        if parts.len() > 2 && parts[2] != "-" {
            for entry in parts[2].split(',') {
                let bits: Vec<&str> = entry.split(':').collect();
                if bits.len() != 2 { continue; }
                let mcid: i64 = bits[0].parse().unwrap_or(0);
                let page: u32 = bits[1].parse().unwrap_or(0);
                let id = (page as u32, 0u16);
                if page > 0 {
                    obj_to_page.insert(id, page);
                    element.content_refs.push(MarkedContentRef { mcid, page_id: Some(id) });
                } else {
                    element.content_refs.push(MarkedContentRef { mcid, page_id: None });
                }
            }
        }
        flat.push((depth, element));
    }

    let mut index = 0usize;
    let tree = build(&flat, &mut index, 0);

    let mut out = String::new();
    let mut tables = Vec::new();
    collect_tables(&tree, &obj_to_page, &mut tables);
    out.push_str(&format!("tables {}\n", tables.len()));
    for table in &tables {
        out.push_str(&format!("t {}\n", table.rows.len()));
        for row in &table.rows {
            out.push_str(&format!("r {}", row.cells.len()));
            for cell in &row.cells {
                out.push_str(&format!(" {}", cell.is_header as u8));
                for (mcid, page) in &cell.mcids {
                    out.push_str(&format!(":{mcid}/{page}"));
                }
            }
            out.push('\n');
        }
    }
    let mut flattened = Vec::new();
    flatten_recursive(&tree, &mut flattened, 0);
    out.push_str(&format!("flat {}\n", flattened.len()));
    for element in &flattened {
        out.push_str(&format!(
            "e {} {:?} {} {}\n",
            element.depth,
            element.role,
            element.child_count,
            element.alt_text.as_deref().unwrap_or("-")
        ));
    }
    out.push_str(&format!(
        "nonheading {}\n",
        tree.iter().filter(|e| e.role.is_non_heading_content()).count()
    ));
    out
}

/// Probe (added for swift-anydoc): the bare-struct-name repair. One
/// hex-encoded buffer per line; the answer is the repaired buffer, also hex.
pub fn probe_structnames(input: &str) -> String {
    let mut out = String::new();
    for line in input.lines() {
        let hex = line.trim();
        let bytes: Vec<u8> = (0..hex.len() / 2)
            .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap_or(0))
            .collect();
        let fixed = fix_bare_struct_names(&bytes);
        let mut encoded = String::with_capacity(fixed.len() * 2);
        for b in fixed.iter() {
            encoded.push_str(&format!("{b:02x}"));
        }
        out.push_str(&format!("n {} {}\n", matches!(fixed, Cow::Owned(_)) as u8, encoded));
    }
    out
}
RUSTEOF

cat >> "$crate/src/extractor/fonts.rs" <<'RUSTEOF'

/// Probe (added for swift-anydoc): the single-byte decoding fallbacks. Each
/// line is `TAG arg...`, arguments hex-encoded where they are text.
pub fn probe_singlebyte(input: &str) -> String {
    fn unhex(hex: &str) -> Vec<u8> {
        (0..hex.len() / 2)
            .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap_or(0))
            .collect()
    }
    fn hex(bytes: &[u8]) -> String {
        let mut out = String::with_capacity(bytes.len() * 2);
        for b in bytes {
            out.push_str(&format!("{b:02x}"));
        }
        out
    }

    let mut out = String::new();
    for line in input.lines() {
        let parts: Vec<&str> = line.split(' ').collect();
        match parts[0] {
            "B" if parts.len() >= 3 => {
                let bytes = unhex(parts[1]);
                let cp = parts[2] == "1";
                out.push_str(&format!(
                    "b {}\n",
                    hex(decode_single_byte_fallback(&bytes, cp).as_bytes())
                ));
            }
            "N" if parts.len() >= 3 => {
                let text = String::from_utf8_lossy(&unhex(parts[1])).to_string();
                let cp = parts[2] == "1";
                out.push_str(&format!(
                    "n {}\n",
                    hex(normalize_cp1252_controls(text, cp).as_bytes())
                ));
            }
            "U" if parts.len() >= 3 => {
                let name = if parts[1] == "-" {
                    None
                } else {
                    Some(String::from_utf8_lossy(&unhex(parts[1])).to_string())
                };
                let cid = parts[2] == "1";
                out.push_str(&format!(
                    "u {}\n",
                    should_use_cp1252_single_byte_fallback(name.as_deref(), cid) as u8
                ));
            }
            "P" if parts.len() >= 2 => {
                let text = String::from_utf8_lossy(&unhex(parts[1])).to_string();
                out.push_str(&format!("p {}\n", hex(clean_symbol_pua(text).as_bytes())));
            }
            "S" if parts.len() >= 3 => {
                let bytes = unhex(parts[1]);
                let name = if parts[2] == "-" {
                    None
                } else {
                    Some(String::from_utf8_lossy(&unhex(parts[2])).to_string())
                };
                match decode_symbol_fallback(&bytes, name.as_deref()) {
                    None => out.push_str("s -\n"),
                    Some(text) => out.push_str(&format!("s {}\n", hex(text.as_bytes()))),
                }
            }
            "T" if parts.len() >= 2 => {
                let text = String::from_utf8_lossy(&unhex(parts[1])).to_string();
                out.push_str(&format!("t {}\n", score_text(&text)));
            }
            "C" if parts.len() >= 3 => {
                let a = String::from_utf8_lossy(&unhex(parts[1])).to_string();
                let b = String::from_utf8_lossy(&unhex(parts[2])).to_string();
                out.push_str(&format!(
                    "c {}\n",
                    hex(choose_best_cmap_decode(a, b).as_bytes())
                ));
            }
            _ => {}
        }
    }
    out
}

/// Probe (added for swift-anydoc): the `/Differences` array. A case is one
/// line: an optional `@base-font` then space-separated `NNN` numbers and
/// `/Name` entries.
pub fn probe_differences(input: &str) -> String {
    use lopdf::{Document, Object};
    let mut out = String::new();
    let doc = Document::new();
    for line in input.lines() {
        let mut base_font: Option<String> = None;
        let mut items: Vec<Object> = Vec::new();
        for token in line.split(' ') {
            if token.is_empty() {
                continue;
            }
            if let Some(name) = token.strip_prefix('@') {
                base_font = Some(name.to_string());
            } else if let Some(name) = token.strip_prefix('/') {
                items.push(Object::Name(name.as_bytes().to_vec()));
            } else if let Ok(value) = token.parse::<i64>() {
                items.push(Object::Integer(value));
            } else {
                items.push(Object::Null);
            }
        }
        let mut dict = lopdf::Dictionary::new();
        dict.set("Differences", Object::Array(items));
        match parse_encoding_dictionary(&doc, &dict, base_font.as_deref()) {
            None => out.push_str("d none\n"),
            Some(result) => {
                let mut codes: Vec<u8> = result.map.keys().copied().collect();
                codes.sort();
                out.push_str("d");
                for code in codes {
                    out.push_str(&format!(" {}:{:X}", code, result.map[&code] as u32));
                }
                out.push_str("\ng");
                for code in &result.gid_codes {
                    out.push_str(&format!(" {code}"));
                }
                out.push('\n');
            }
        }
    }
    out
}
RUSTEOF

cat >> "$crate/src/extractor/fonts.rs" <<'RUSTEOF'

/// Probe (added for swift-anydoc): the CFF Name INDEX reader. One
/// hex-encoded font program per line; the answer is the name, hex-encoded,
/// or `-` when there is none.
pub fn probe_cffname(input: &str) -> String {
    let mut out = String::new();
    for line in input.lines() {
        let hex = line.trim();
        let bytes: Vec<u8> = (0..hex.len() / 2)
            .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap_or(0))
            .collect();
        match cff_font_name(&bytes) {
            None => out.push_str("c -\n"),
            Some(name) => {
                let mut encoded = String::new();
                for b in name.as_bytes() {
                    encoded.push_str(&format!("{b:02x}"));
                }
                out.push_str(&format!("c {encoded}\n"));
            }
        }
    }
    out
}

/// Probe (added for swift-anydoc): descriptor style flags and the CMap
/// lookup key, over a whole PDF. Every font dictionary reachable from every
/// page's `/Resources /Font` is reported, keyed by its resource name.
pub fn probe_fontstyle(bytes: &[u8]) -> String {
    use lopdf::Document;
    let mut out = String::new();
    let Ok(doc) = Document::load_mem(bytes) else {
        out.push_str("error\n");
        return out;
    };
    let mut pages: Vec<_> = doc.get_pages().into_iter().collect();
    pages.sort_by_key(|(number, _)| *number);
    for (number, page_id) in pages {
        let Ok(page) = doc.get_dictionary(page_id) else { continue };
        let Some(resources) = page
            .get(b"Resources")
            .ok()
            .and_then(|o| resolve_dict(&doc, o))
        else {
            continue;
        };
        let Some(fonts) = resources
            .get(b"Font")
            .ok()
            .and_then(|o| resolve_dict(&doc, o))
        else {
            continue;
        };
        let mut names: Vec<Vec<u8>> = fonts.iter().map(|(k, _)| k.to_vec()).collect();
        names.sort();
        for name in names {
            let Some(font_dict) = fonts
                .get(&name)
                .ok()
                .and_then(|o| resolve_dict(&doc, o))
            else {
                out.push_str(&format!(
                    "f {} {} missing\n",
                    number,
                    String::from_utf8_lossy(&name)
                ));
                continue;
            };
            let (italic, bold) =
                descriptor_style_flags(&doc, font_dict, &mut FontStyleCache::new());
            let key = get_font_file2_obj_num(&doc, font_dict);
            out.push_str(&format!(
                "f {} {} {} {} {}\n",
                number,
                String::from_utf8_lossy(&name),
                italic as u8,
                bold as u8,
                key.map(|k| k.to_string()).unwrap_or_else(|| "-".to_string())
            ));
        }
    }
    out
}
RUSTEOF

cat >> "$crate/src/extractor/layout.rs" <<'RUSTEOF'

/// Probe (added for swift-anydoc): the leaf tests of column detection. Each
/// line is `TAG arg...`; tildes stand in for spaces inside text.
pub fn probe_valleys(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    fn item(x: f32, y: f32, width: f32, font_size: f32, text: &str) -> TextItem {
        TextItem {
            text: text.replace('~', " "),
            x,
            y,
            width,
            height: font_size,
            font: "F1".to_string(),
            font_size,
            page: 1,
            is_bold: false,
            is_italic: false,
            is_underline: false,
            is_strikeout: false,
            item_type: ItemType::Text,
            mcid: None,
        }
    }

    let mut out = String::new();
    for line in input.lines() {
        let parts: Vec<&str> = line.split(' ').filter(|p| !p.is_empty()).collect();
        if parts.is_empty() {
            continue;
        }
        match parts[0] {
            // V bin_width page_width margin | h0 h1 h2 ...
            "V" => {
                let bar = match parts.iter().position(|p| *p == "|") {
                    Some(index) => index,
                    None => continue,
                };
                let bin_width: f32 = parts[1].parse().unwrap_or(1.0);
                let page_width: f32 = parts[2].parse().unwrap_or(612.0);
                let margin: f32 = parts[3].parse().unwrap_or(0.0);
                let histogram: Vec<u32> =
                    parts[bar + 1..].iter().map(|p| p.parse().unwrap_or(0)).collect();
                let n = histogram.len();
                let valleys =
                    find_relative_valleys(&histogram, n, 0.0, bin_width, page_width, margin);
                out.push_str(&format!("v {}", valleys.len()));
                for (lo, hi) in valleys {
                    out.push_str(&format!(" {lo}:{hi}"));
                }
                out.push('\n');
            }
            // L text... (a bare `-` is an empty list)
            "L" => {
                let texts: Vec<&str> = if parts.len() > 1 && parts[1] == "-" {
                    vec![]
                } else {
                    parts[1..].to_vec()
                };
                let items: Vec<TextItem> =
                    texts.iter().map(|t| item(0.0, 0.0, 0.0, 12.0, t)).collect();
                let refs: Vec<&TextItem> = items.iter().collect();
                let refrefs: Vec<&&TextItem> = refs.iter().collect();
                out.push_str(&format!("l {}\n", is_list_marker_column(&refrefs) as u8));
            }
            // S x width font_size text | xmin xmax xmin xmax ...
            "S" => {
                let bar = match parts.iter().position(|p| *p == "|") {
                    Some(index) => index,
                    None => continue,
                };
                let it = item(
                    parts[1].parse().unwrap_or(0.0),
                    700.0,
                    parts[2].parse().unwrap_or(0.0),
                    parts[3].parse().unwrap_or(12.0),
                    parts[4],
                );
                let nums: Vec<f32> =
                    parts[bar + 1..].iter().map(|p| p.parse().unwrap_or(0.0)).collect();
                let columns: Vec<ColumnRegion> = nums
                    .chunks_exact(2)
                    .map(|c| ColumnRegion { x_min: c[0], x_max: c[1] })
                    .collect();
                out.push_str(&format!("s {}\n", spans_multiple_columns(&it, &columns) as u8));
            }
            // C center_assign min_items min_span x_min bin_width x_max
            //   | v_lo:v_hi ... ; x,y,w,text ...
            "C" => {
                let bar = match parts.iter().position(|p| *p == "|") {
                    Some(index) => index,
                    None => continue,
                };
                let semi = match parts.iter().position(|p| *p == ";") {
                    Some(index) => index,
                    None => continue,
                };
                let center = parts[1] == "1";
                let min_items: usize = parts[2].parse().unwrap_or(0);
                let min_span: f32 = parts[3].parse().unwrap_or(0.0);
                let x_min: f32 = parts[4].parse().unwrap_or(0.0);
                let bin_width: f32 = parts[5].parse().unwrap_or(1.0);
                let x_max: f32 = parts[6].parse().unwrap_or(612.0);
                let valleys: Vec<(usize, usize)> = parts[bar + 1..semi]
                    .iter()
                    .filter_map(|p| {
                        let (a, b) = p.split_once(':')?;
                        Some((a.parse().ok()?, b.parse().ok()?))
                    })
                    .collect();
                let items: Vec<TextItem> = parts[semi + 1..]
                    .iter()
                    .filter_map(|p| {
                        let f: Vec<&str> = p.split(',').collect();
                        if f.len() < 4 {
                            return None;
                        }
                        Some(item(
                            f[0].parse().ok()?,
                            f[1].parse().ok()?,
                            f[2].parse().ok()?,
                            12.0,
                            f[3],
                        ))
                    })
                    .collect();
                let refs: Vec<&TextItem> = items.iter().collect();
                let columns = validate_and_build_columns(
                    &valleys, &refs, x_min, bin_width, x_max, min_items, min_span, 1, center,
                );
                out.push_str(&format!("c {}", columns.len()));
                for col in &columns {
                    out.push_str(&format!(" {:.2}:{:.2}", col.x_min, col.x_max));
                }
                out.push('\n');
            }
            // R | xmin,xmax ... ; x,y,w,text ...
            "R" => {
                let bar = match parts.iter().position(|p| *p == "|") {
                    Some(index) => index,
                    None => continue,
                };
                let semi = match parts.iter().position(|p| *p == ";") {
                    Some(index) => index,
                    None => continue,
                };
                let columns: Vec<ColumnRegion> = parts[bar + 1..semi]
                    .iter()
                    .filter_map(|p| {
                        let (a, b) = p.split_once(',')?;
                        Some(ColumnRegion { x_min: a.parse().ok()?, x_max: b.parse().ok()? })
                    })
                    .collect();
                let items: Vec<TextItem> = parts[semi + 1..]
                    .iter()
                    .filter_map(|p| {
                        let f: Vec<&str> = p.split(',').collect();
                        if f.len() < 4 {
                            return None;
                        }
                        Some(item(
                            f[0].parse().ok()?,
                            f[1].parse().ok()?,
                            f[2].parse().ok()?,
                            12.0,
                            f[3],
                        ))
                    })
                    .collect();
                let refs: Vec<&TextItem> = items.iter().collect();
                out.push_str(&format!("r {}\n", columns_have_prose(&columns, &refs) as u8));
            }
            // M | xmin,xmax ... ; x,y,w,text ...
            "M" => {
                let bar = match parts.iter().position(|p| *p == "|") {
                    Some(index) => index,
                    None => continue,
                };
                let semi = match parts.iter().position(|p| *p == ";") {
                    Some(index) => index,
                    None => continue,
                };
                let columns: Vec<ColumnRegion> = parts[bar + 1..semi]
                    .iter()
                    .filter_map(|p| {
                        let (a, b) = p.split_once(',')?;
                        Some(ColumnRegion { x_min: a.parse().ok()?, x_max: b.parse().ok()? })
                    })
                    .collect();
                let items: Vec<TextItem> = parts[semi + 1..]
                    .iter()
                    .filter_map(|p| {
                        let f: Vec<&str> = p.split(',').collect();
                        if f.len() < 4 {
                            return None;
                        }
                        Some(item(
                            f[0].parse().ok()?,
                            f[1].parse().ok()?,
                            f[2].parse().ok()?,
                            12.0,
                            f[3],
                        ))
                    })
                    .collect();
                let mask = identify_spanning_lines(&items, &columns);
                out.push_str("m ");
                for flag in &mask {
                    out.push(if *flag { '1' } else { '0' });
                }
                out.push('\n');
            }
            // G y,itemcount ...  (one line per entry, y descending as given)
            "G" => {
                use crate::types::TextLine;
                let lines_in: Vec<TextLine> = parts[1..]
                    .iter()
                    .filter_map(|p| {
                        let f: Vec<&str> = p.split(',').collect();
                        if f.len() < 2 {
                            return None;
                        }
                        let y: f32 = f[0].parse().ok()?;
                        let count: usize = f[1].parse().ok()?;
                        Some(TextLine {
                            items: (0..count).map(|i| item(i as f32 * 10.0, y, 8.0, 12.0, "w")).collect(),
                            y,
                            page: 1,
                            adaptive_threshold: 0.10,
                        })
                    })
                    .collect();
                let (core, stragglers) = split_column_stragglers(lines_in);
                out.push_str(&format!("g {} {}", core.len(), stragglers.len()));
                for line in &core {
                    out.push_str(&format!(" {:.1}", line.y));
                }
                out.push_str(" /");
                for line in &stragglers {
                    out.push_str(&format!(" {:.1}", line.y));
                }
                out.push('\n');
            }
            // X x_min x_max ; x,y,w,text ...
            "X" => {
                let semi = match parts.iter().position(|p| *p == ";") {
                    Some(index) => index,
                    None => continue,
                };
                let x_min: f32 = parts[1].parse().unwrap_or(0.0);
                let x_max: f32 = parts[2].parse().unwrap_or(612.0);
                let items: Vec<TextItem> = parts[semi + 1..]
                    .iter()
                    .filter_map(|p| {
                        let f: Vec<&str> = p.split(',').collect();
                        if f.len() < 4 {
                            return None;
                        }
                        Some(item(
                            f[0].parse().ok()?,
                            f[1].parse().ok()?,
                            f[2].parse().ok()?,
                            12.0,
                            f[3],
                        ))
                    })
                    .collect();
                let refs: Vec<&TextItem> = items.iter().collect();
                match try_xy_cut_split(&refs, x_min, x_max, 1) {
                    None => out.push_str("x -\n"),
                    Some(cols) => {
                        out.push_str("x");
                        for col in &cols {
                            out.push_str(&format!(" {:.2}:{:.2}", col.x_min, col.x_max));
                        }
                        out.push('\n');
                    }
                }
            }
            // N | xmin,xmax ... ; y y y / y y y / ...   (one group per column)
            "N" => {
                use crate::types::TextLine;
                let bar = match parts.iter().position(|p| *p == "|") {
                    Some(index) => index,
                    None => continue,
                };
                let semi = match parts.iter().position(|p| *p == ";") {
                    Some(index) => index,
                    None => continue,
                };
                let columns: Vec<ColumnRegion> = parts[bar + 1..semi]
                    .iter()
                    .filter_map(|p| {
                        let (a, b) = p.split_once(',')?;
                        Some(ColumnRegion { x_min: a.parse().ok()?, x_max: b.parse().ok()? })
                    })
                    .collect();
                let mut per_column: Vec<Vec<TextLine>> = vec![Vec::new()];
                for token in &parts[semi + 1..] {
                    if *token == "/" {
                        per_column.push(Vec::new());
                        continue;
                    }
                    if let Ok(y) = token.parse::<f32>() {
                        let last = per_column.len() - 1;
                        per_column[last].push(TextLine {
                            items: vec![item(0.0, y, 8.0, 12.0, "w")],
                            y,
                            page: 1,
                            adaptive_threshold: 0.10,
                        });
                    }
                }
                out.push_str(&format!(
                    "n {}\n",
                    is_newspaper_layout(&per_column, &columns) as u8
                ));
            }
            // D has_table ; x,y,w,text ...
            "D" => {
                let semi = match parts.iter().position(|p| *p == ";") {
                    Some(index) => index,
                    None => continue,
                };
                let has_table = parts[1] == "1";
                let items: Vec<TextItem> = parts[semi + 1..]
                    .iter()
                    .filter_map(|p| {
                        let f: Vec<&str> = p.split(',').collect();
                        if f.len() < 4 {
                            return None;
                        }
                        Some(item(
                            f[0].parse().ok()?,
                            f[1].parse().ok()?,
                            f[2].parse().ok()?,
                            12.0,
                            f[3],
                        ))
                    })
                    .collect();
                let cols = detect_columns(&items, 1, has_table);
                out.push_str(&format!("d {}", cols.len()));
                for col in &cols {
                    out.push_str(&format!(" {:.2}:{:.2}", col.x_min, col.x_max));
                }
                out.push('\n');
            }
            // S1 ; x,y,w,bold,text ...   (single-column grouping)
            "S1" => {
                let semi = match parts.iter().position(|p| *p == ";") {
                    Some(index) => index,
                    None => continue,
                };
                let items: Vec<TextItem> = parts[semi + 1..]
                    .iter()
                    .filter_map(|p| {
                        let f: Vec<&str> = p.split(',').collect();
                        if f.len() < 6 {
                            return None;
                        }
                        let mut it = item(
                            f[0].parse().ok()?,
                            f[1].parse().ok()?,
                            f[2].parse().ok()?,
                            f[4].parse().unwrap_or(12.0),
                            f[5],
                        );
                        it.is_bold = f[3] == "1";
                        Some(it)
                    })
                    .collect();
                let ysort = should_use_y_sorting(&items) as u8;
                let lines_out = group_single_column(items, 0.10);
                out.push_str(&format!("s1 {} {}", ysort, lines_out.len()));
                for line in &lines_out {
                    // Structure only: how many runs on the line, its
                    // baseline, and the x each run ended up at. Comparing
                    // the joined text would drag in word joining, which is
                    // a different function's business.
                    out.push_str(&format!(" {}@{:.1}", line.items.len(), line.y));
                    for it in &line.items {
                        out.push_str(&format!(",{:.1}", it.x));
                    }
                }
                out.push('\n');
            }
            // P y text
            "P" => {
                let it = item(0.0, parts[1].parse().unwrap_or(0.0), 0.0, 12.0, parts[2]);
                out.push_str(&format!("p {}\n", is_page_number(&it) as u8));
            }
            _ => {}
        }
    }
    out
}
RUSTEOF

cat >> "$crate/src/glyph_names.rs" <<'RUSTEOF'

/// Probe (added for swift-anydoc): glyph-name resolution. One name per line.
pub fn probe_glyphnames(input: &str) -> String {
    let mut out = String::new();
    for line in input.lines() {
        let name = line.trim_end_matches('\n');
        match glyph_to_char(name) {
            Some(c) => out.push_str(&format!("g {:X}\n", c as u32)),
            None => out.push_str("g -\n"),
        }
    }
    out
}
RUSTEOF

cat >> "$crate/src/text_utils.rs" <<'RUSTEOF'

/// Probe (added for swift-anydoc): the join decision. Each case is one line
/// of `threshold | prev-fields | curr-fields`, fields separated by spaces and
/// tildes standing in for spaces inside the texts.
pub fn probe_join(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    let mut out = String::new();
    for line in input.lines() {
        let p: Vec<&str> = line.split(' ').collect();
        if p.len() < 11 { continue; }
        let make = |base: usize| TextItem {
            text: p[base + 4].replace('~', " "),
            x: p[base].parse().unwrap_or(0.0),
            y: 700.0,
            width: p[base + 1].parse().unwrap_or(0.0),
            height: p[base + 2].parse().unwrap_or(0.0),
            font: p[base + 3].to_string(),
            font_size: p[base + 2].parse().unwrap_or(0.0),
            page: 1,
            is_bold: false, is_italic: false, is_underline: false, is_strikeout: false,
            item_type: ItemType::Text, mcid: None,
        };
        let threshold: f32 = p[0].parse().unwrap_or(0.10);
        let prev = make(1);
        let curr = make(6);
        out.push_str(&format!("j {}\n", should_join_items(&prev, &curr, threshold) as u8));
    }
    out
}

/// Probe (added for swift-anydoc): letter-spacing repair. Each case is a
/// block of `x y width font_size text` item lines.
pub fn probe_letterspacing(input: &str) -> String {
    use crate::types::{ItemType, TextItem};
    let mut items: Vec<TextItem> = Vec::new();
    for line in input.lines() {
        let parts: Vec<&str> = line.split(' ').collect();
        if parts.len() < 5 { continue; }
        items.push(TextItem {
            text: parts[4..].join(" ").replace('~', " "),
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
    let ratios = collect_gap_ratios(&items);
    let mut out = format!("r {}", ratios.len());
    for value in &ratios { out.push_str(&format!(" {value:.6}")); }
    out.push_str(&format!("\nc {:.6}\n", compute_canva_join_threshold(&items)));
    let threshold = fix_letterspaced_items(&mut items);
    out.push_str(&format!("f {threshold:.6}\n"));
    for item in &items {
        out.push_str(&format!("i {}\n", item.text.replace(' ', "~")));
    }
    out
}

/// Probe (added for swift-anydoc): ligature expansion. One hex-encoded UTF-8
/// string per line; the answer is the expanded string, also hex.
pub fn probe_ligatures(input: &str) -> String {
    let mut out = String::new();
    for line in input.lines() {
        let hex = line.trim();
        let bytes: Vec<u8> = (0..hex.len() / 2)
            .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap_or(0))
            .collect();
        let text = String::from_utf8_lossy(&bytes).to_string();
        let expanded = expand_ligatures(&text);
        let mut encoded = String::with_capacity(expanded.len() * 2);
        for b in expanded.as_bytes() {
            encoded.push_str(&format!("{b:02x}"));
        }
        out.push_str(&format!("l {encoded}\n"));
    }
    out
}

/// Probe (added for swift-anydoc): script classification, RTL detection and
/// visual-order reversal. One hex-encoded UTF-8 string per line.
pub fn probe_bidi(input: &str) -> String {
    let mut out = String::new();
    for line in input.lines() {
        let hex = line.trim();
        let bytes: Vec<u8> = (0..hex.len() / 2)
            .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap_or(0))
            .collect();
        let text = String::from_utf8_lossy(&bytes).to_string();
        let cjk = text.chars().filter(|c| is_cjk_char(*c)).count();
        let rtl = text.chars().filter(|c| is_rtl_char(*c)).count();
        let forms = text.chars().filter(|c| is_arabic_presentation_form(*c)).count();
        let reversed = reverse_visual_arabic(&text);
        out.push_str(&format!(
            "t {} {} {} {} {} {}\n",
            cjk,
            rtl,
            forms,
            is_rtl_text(std::iter::once(&text)) as u8,
            is_cid_font(&text) as u8,
            hex::encode(reversed.as_bytes()),
        ));
        out.push_str(&format!(
            "d {}\n",
            hex::encode(decode_text_string(&bytes).as_bytes())
        ));
    }
    out
}

mod hex {
    pub fn encode(bytes: &[u8]) -> String {
        let mut out = String::with_capacity(bytes.len() * 2);
        for b in bytes {
            out.push_str(&format!("{b:02x}"));
        }
        out
    }
}
RUSTEOF

cat >> "$crate/src/text_quality.rs" <<'RUSTEOF'

/// Probe (added for swift-anydoc): the markdown-level quality detectors and
/// the cipher-garble statistics they rest on. Input is one hex-encoded UTF-8
/// string per line, so arbitrary bytes survive the round trip.
pub fn probe_textquality(input: &str) -> String {
    let mut out = String::new();
    for line in input.lines() {
        let hex = line.trim();
        let bytes: Vec<u8> = (0..hex.len() / 2)
            .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap_or(0))
            .collect();
        let text = String::from_utf8_lossy(&bytes).to_string();
        let mut stats = CipherGarbleStats::default();
        stats.add_text(&text);
        out.push_str(&format!(
            "q {} {} {} {} {} {} {} {} {:.9} {:.9} {}\n",
            detect_encoding_issues(&text) as u8,
            has_dollar_as_space_pattern(&text) as u8,
            stats.ascii_letters,
            stats.ascii_vowels,
            stats.latin_ext_letters,
            stats.non_latin_letters,
            stats.letter_bigrams,
            stats.case_shift_bigrams,
            stats.english_cosine(),
            stats.english_shape_cosine(),
            stats.looks_garbled() as u8,
        ));
        let (repl, longest) = replacement_text_stats(&text);
        out.push_str(&format!(
            "s {} {} {} {} {} {} {} {} {} {}\n",
            match text_span_decoding_issue_kind(&text) {
                None => "none",
                Some(TextSpanIssueKind::Replacement) => "replacement",
                Some(TextSpanIssueKind::Strong) => "strong",
            },
            text_span_has_decoding_issue(&text) as u8,
            repl,
            longest,
            has_replacement_text_run(&text) as u8,
            has_private_use_text_run(&text) as u8,
            has_cid_control_token(&text) as u8,
            is_garbage_text(&text) as u8,
            is_cid_garbage(&text) as u8,
            {
                let evidence = PageTextQualityEvidence {
                    chars: text.chars().count(),
                    replacement_chars: repl,
                    replacement_spans: if repl > 0 { 3 } else { 0 },
                    longest_replacement_run: longest,
                    ..Default::default()
                };
                page_replacement_evidence_needs_ocr(&evidence) as u8
            },
        ));
    }
    out
}
RUSTEOF

cat >> "$crate/src/detector.rs" <<'RUSTEOF'
/// Probe (added for swift-anydoc): the standalone detector helpers. Each
/// case is three lines — `D count total`, `A <seven analysis flags>`, and
/// `B <hex bytes>`.
pub fn probe_detector(input: &str) -> String {
    let mut out = String::new();
    for line in input.lines() {
        let parts: Vec<&str> = line.split(' ').collect();
        match parts[0] {
            "D" if parts.len() >= 3 => {
                let n: u32 = parts[1].parse().unwrap_or(0);
                let total: u32 = parts[2].parse().unwrap_or(0);
                out.push_str("d");
                for index in distribute_pages(n, total) {
                    out.push_str(&format!(" {index}"));
                }
                out.push('\n');
            }
            "A" if parts.len() >= 8 => {
                let flag = |i: usize| parts[i] == "1";
                let analysis = PageAnalysis {
                    text_operator_count: parts[1].parse().unwrap_or(0),
                    has_images: flag(2),
                    has_template_image: flag(3),
                    unique_text_chars: parts[4].parse().unwrap_or(0),
                    has_vector_text: flag(5),
                    has_identity_h_no_tounicode: flag(6),
                    has_only_type3_fonts: flag(7),
                    ..Default::default()
                };
                out.push_str("a");
                for reason in page_ocr_reasons(&analysis) {
                    out.push_str(&format!(" {reason}"));
                }
                out.push('\n');
            }
            "B" => {
                let hex = parts.get(1).copied().unwrap_or("");
                let bytes: Vec<u8> = (0..hex.len() / 2)
                    .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap_or(0))
                    .collect();
                out.push_str(&format!("b {}\n", estimate_page_count_from_bytes(&bytes)));
            }
            _ => {}
        }
    }
    out
}
RUSTEOF

cat >> "$crate/src/tables/detect_lines.rs" <<'RUSTEOF'

/// Probe (added for swift-anydoc): report what the rule primitives make of a
/// set of horizontal segments. Input lines are `y x_min x_max`, then a blank
/// line, then optional text items as `x y width font_size text`.
/// Probe (added for swift-anydoc): the line-table orchestrator. Its own case
/// format — `L x1 y1 x2 y2` strokes, a blank line, then items — because this
/// entry point takes raw lines rather than classified rules.
pub fn probe_linetables(input: &str) -> String {
    use crate::types::{ItemType, PdfLine, TextItem};
    let mut lines: Vec<PdfLine> = Vec::new();
    let mut items: Vec<TextItem> = Vec::new();
    let mut in_items = false;
    for line in input.lines() {
        if line.trim().is_empty() {
            in_items = true;
            continue;
        }
        let parts: Vec<&str> = line.split(' ').collect();
        if !in_items {
            if parts.len() >= 5 && parts[0] == "L" {
                lines.push(PdfLine {
                    x1: parts[1].parse().unwrap_or(0.0),
                    y1: parts[2].parse().unwrap_or(0.0),
                    x2: parts[3].parse().unwrap_or(0.0),
                    y2: parts[4].parse().unwrap_or(0.0),
                    page: 1,
                });
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

    fn emit2(out: &mut String, tag: &str, t: &Table) {
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

    let (horizontals, verticals) = {
        let mut h: Vec<(f32, f32, f32)> = Vec::new();
        let mut v: Vec<(f32, f32, f32)> = Vec::new();
        let tol = 2.0_f32.to_radians().tan();
        for line in &lines {
            let dx = (line.x2 - line.x1).abs();
            let dy = (line.y2 - line.y1).abs();
            if (dx * dx + dy * dy).sqrt() < 20.0 { continue; }
            if dx > 0.01 && dy / dx <= tol {
                h.push(((line.y1 + line.y2) / 2.0, line.x1.min(line.x2), line.x1.max(line.x2)));
            } else if dy > 0.01 && dx / dy <= tol {
                v.push(((line.x1 + line.x2) / 2.0, line.y1.min(line.y2), line.y1.max(line.y2)));
            }
        }
        (h, v)
    };
    let mut out = format!("class {} {}\n", horizontals.len(), verticals.len());

    let full = detect_tables_from_lines(&items, &lines, 1);
    out.push_str(&format!("full {}\n", full.len()));
    for t in &full { emit2(&mut out, "f", t); }
    let vector = detect_vector_grid_tables_from_lines(&items, &lines, 1);
    out.push_str(&format!("vector {}\n", vector.len()));
    for t in &vector { emit2(&mut out, "v", t); }
    out
}

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
    if path == "--mcid" {
        let file = std::env::args().nth(2).expect("usage: --mcid <file.pdf>");
        let bytes = std::fs::read(&file).expect("read");
        print!("{}", pdf_inspector::extractor::content_stream::probe_mcid(&bytes));
        return;
    }
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
    if path == "--structtables" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_struct::probe_structtables(&input));
        return;
    }
    if path == "--structheader" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_struct::probe_structheader(&input));
        return;
    }
    if path == "--structrows" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_struct::probe_structrows(&input));
        return;
    }
    if path == "--structcols" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_struct::probe_structcols(&input));
        return;
    }
    if path == "--structparse" {
        let file = std::env::args().nth(2).expect("usage: --structparse <file.pdf>");
        let bytes = std::fs::read(&file).expect("read");
        print!("{}", pdf_inspector::structure_tree::probe_structparse(&bytes));
        return;
    }
    if path == "--structtree" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::structure_tree::probe_structtree(&input));
        return;
    }
    if path == "--structnames" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::structure_tree::probe_structnames(&input));
        return;
    }
    if path == "--join" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::text_utils::probe_join(&input));
        return;
    }
    if path == "--letterspacing" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::text_utils::probe_letterspacing(&input));
        return;
    }
    if path == "--singlebyte" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::extractor::fonts::probe_singlebyte(&input));
        return;
    }
    if path == "--valleys" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::extractor::layout::probe_valleys(&input));
        return;
    }
    if path == "--cffname" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::extractor::fonts::probe_cffname(&input));
        return;
    }
    if path == "--fontstyle" {
        let file = std::env::args().nth(2).expect("usage: --fontstyle <file.pdf>");
        let bytes = std::fs::read(&file).expect("read");
        print!("{}", pdf_inspector::extractor::fonts::probe_fontstyle(&bytes));
        return;
    }
    if path == "--differences" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::extractor::fonts::probe_differences(&input));
        return;
    }
    if path == "--glyphnames" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::glyph_names::probe_glyphnames(&input));
        return;
    }
    if path == "--ligatures" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::text_utils::probe_ligatures(&input));
        return;
    }
    if path == "--bidi" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::text_utils::probe_bidi(&input));
        return;
    }
    if path == "--textquality" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::text_quality::probe_textquality(&input));
        return;
    }
    if path == "--detector" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::detector::probe_detector(&input));
        return;
    }
    if path == "--linetables" {
        use std::io::Read;
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).expect("stdin");
        print!("{}", pdf_inspector::tables::detect_lines::probe_linetables(&input));
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
