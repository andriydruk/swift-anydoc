#!/bin/sh
# Build the PDF corpus and *all three* per-file oracle dumps beside it.
#
# This exists because the corpus suites need more than the PDFs. Each file
# needs three dumps alongside it, and without them the suites do not fail —
# they silently compare nothing, which is worse:
#
#   <name>.pdf.expected   object graph, from lopdf (the library the reference
#                         itself is built on)
#   <name>.pdf.graphics   path extraction, from the vendored reference
#   <name>.pdf.underline  decoration flags and run widths, likewise
#
# `pdfprobe` is built here rather than kept in a scratch directory, so the
# object-graph oracle is reproducible from the repo alone.
#
#   scripts/gen-graphics-oracle.sh <work-dir>     # once, builds graphicsprobe
#   scripts/gen-pdf-oracles.sh <corpus-dir> <work-dir>
#   ANYDOC_PDF_CORPUS=<corpus-dir> swift test
set -eu

if [ $# -lt 2 ]; then
    echo "usage: $0 <corpus-dir> <work-dir-from-gen-graphics-oracle>" >&2
    exit 2
fi
corpus=$1
work=$2

graphicsprobe=$work/pdfinspector/target/release/graphicsprobe
if [ ! -x "$graphicsprobe" ]; then
    echo "graphicsprobe not found at $graphicsprobe" >&2
    echo "run scripts/gen-graphics-oracle.sh $work first" >&2
    exit 1
fi

# --- the lopdf object-graph oracle -------------------------------------
crate=$work/pdfprobe
mkdir -p "$crate/src"
cat > "$crate/Cargo.toml" <<'EOF'
[package]
name = "pdfprobe"
version = "0.1.0"
edition = "2021"

[dependencies]
lopdf = "0.41.0"
EOF
cat > "$crate/src/main.rs" <<'EOF'
// Dump the object graph of a PDF using lopdf — the library the reference's
// PDF stack is built on — so the Swift reader can be diffed against it.
use lopdf::{Document, Object};
use std::env;

fn kind(o: &Object) -> &'static str {
    match o {
        Object::Null => "null",
        Object::Boolean(_) => "bool",
        Object::Integer(_) => "int",
        Object::Real(_) => "real",
        Object::Name(_) => "name",
        Object::String(..) => "string",
        Object::Array(_) => "array",
        Object::Dictionary(_) => "dict",
        Object::Stream(_) => "stream",
        Object::Reference(_) => "ref",
    }
}

fn main() {
    let path = env::args().nth(1).expect("usage: pdfprobe <file.pdf>");
    let doc = Document::load(&path).expect("load");
    let mut ids: Vec<_> = doc.objects.keys().copied().collect();
    ids.sort();
    println!("#OBJECTS {}", ids.len());
    for id in ids {
        let obj = &doc.objects[&id];
        let mut line = format!("{} {} {}", id.0, id.1, kind(obj));
        if let Object::Stream(s) = obj {
            let decoded = s.decompressed_content().map(|d| d.len()).unwrap_or(usize::MAX);
            line.push_str(&format!(" raw={} decoded={}", s.content.len(), decoded));
        }
        if let Ok(d) = obj.as_dict() {
            let mut keys: Vec<String> =
                d.iter().map(|(k, _)| String::from_utf8_lossy(k).to_string()).collect();
            keys.sort();
            line.push_str(&format!(" keys=[{}]", keys.join(",")));
        }
        println!("{}", line);
    }
    let pages = doc.get_pages();
    println!("#PAGES {}", pages.len());
    for (n, id) in pages {
        println!("page {} -> {} {}", n, id.0, id.1);
    }
}
EOF
(cd "$crate" && cargo build --release --offline >/dev/null 2>&1) || {
    echo "pdfprobe failed to build (needs lopdf 0.41 in the local registry)" >&2
    exit 1
}
pdfprobe=$crate/target/release/pdfprobe

# --- the dumps ----------------------------------------------------------
# A file the oracle rejects gets no dump, which is the signal the suite
# reads as "the reference refuses this one too".
accepted=0
rejected=0
# `$corpus/detector/` holds documents only the detector probes read — the
# end-to-end pipeline cannot match them yet, so they are kept out of its way.
for f in "$corpus"/*.pdf "$corpus"/detector/*.pdf; do
    [ -e "$f" ] || continue
    if "$pdfprobe" "$f" > "$f.expected" 2>/dev/null; then
        accepted=$((accepted + 1))
    else
        rm -f "$f.expected"
        rejected=$((rejected + 1))
    fi
    "$graphicsprobe" "$f" > "$f.graphics" 2>/dev/null || rm -f "$f.graphics"
    "$graphicsprobe" --underline "$f" > "$f.underline" 2>/dev/null || rm -f "$f.underline"
    "$graphicsprobe" --pagefonts "$f" > "$f.pagefonts" 2>/dev/null || rm -f "$f.pagefonts"
    "$graphicsprobe" --pageanalysis "$f" > "$f.pageanalysis" 2>/dev/null || rm -f "$f.pageanalysis"
    "$graphicsprobe" --detectdoc "$f" > "$f.detectdoc" 2>/dev/null || rm -f "$f.detectdoc"
done

echo "oracle dumps written: $accepted accepted, $rejected rejected by lopdf"
