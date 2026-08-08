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

mkdir -p "$crate/src/bin"
cat > "$crate/src/bin/graphicsprobe.rs" <<'RUSTEOF'
// Dumps the reference's path-extraction output for one PDF.
fn main() {
    let mut args = std::env::args().skip(1);
    let path = args.next().expect("usage: graphicsprobe [--underline] <file.pdf>");
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
