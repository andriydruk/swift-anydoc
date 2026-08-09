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
