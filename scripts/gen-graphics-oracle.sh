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
perl -pi -e 's/^fn (table_evidence_score|select_non_overlapping_hypotheses|tables_share_items|overlaps_multiple_tables|select_table_hypothesis)\(/pub fn $1(/' \
    "$crate/src/tables/detect_lines.rs"
perl -pi -e 's/^pub\(crate\) mod detect_rects;/pub mod detect_rects;/; s/^mod detect_rects;/pub mod detect_rects;/' \
    "$crate/src/tables/mod.rs"
perl -pi -e 's/^pub\(crate\) fn (rects_overlap|cluster_rects)\(/pub fn $1(/; s/^fn split_wide_cluster\(/pub fn split_wide_cluster(/' \
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
