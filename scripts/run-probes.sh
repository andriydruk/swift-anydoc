#!/bin/sh
# Run *every* differential suite: build each oracle, generate each corpus,
# then run the tests with all the gates set.
#
# This exists because the gates are environment variables, and a suite whose
# variable is unset does not fail — it returns before comparing anything and
# reports as a pass. Six of the seven gates were unset for thirty-odd waves
# before wave 98 noticed, so `swift test` was reporting green while five
# corpora and a million-codepoint normalisation check sat idle.
#
#   scripts/run-probes.sh <work-dir>
#
# The work directory is reused between runs; the Rust oracles are the slow
# part and are rebuilt only when their sources change. Everything lands
# outside the repo, so nothing here is committed.
#
# **CI deliberately does not run this.** The oracles are built from a
# vendored copy of the reference crate, and fetching that in CI was rejected
# in favour of keeping the published repository free of any dependency on
# upstream. The differential checks are a local gate, run by whoever is
# porting; CI proves the package builds and the non-differential tests pass,
# and nothing more. Do not read a green CI badge as a differential result.
set -eu

if [ $# -lt 1 ]; then
    echo "usage: $0 <work-dir>" >&2
    exit 2
fi
work=$1
shift  # anything further is forwarded to `swift test` (e.g. --filter Pdf)
mkdir -p "$work"

probe=$work/o/pdfinspector/target/release/graphicsprobe

echo "==> building the vendored oracle"
./scripts/gen-graphics-oracle.sh "$work/o" >/dev/null

echo "==> grid, format and stream probes"
python3 scripts/gen-grid-probe.py --oracle "$work/o" "$work/grid" >/dev/null

echo "==> adversarial PDF corpus (object graph, graphics, underline)"
python3 scripts/gen-pdf-corpus.py "$work/corpus" >/dev/null
./scripts/gen-pdf-oracles.sh "$work/corpus" "$work/o"

echo "==> font, marked-content and structure-tree corpora"
python3 scripts/gen-font-corpus.py "$work/font" --probe "$probe" >/dev/null
python3 scripts/gen-mcid-corpus.py "$work/mcid" --probe "$probe" >/dev/null
python3 scripts/gen-structtree-corpus.py "$work/struct" --probe "$probe" >/dev/null

echo "==> line classifiers"
python3 scripts/gen-classify-probe.py "$work/classify" >/dev/null

if [ ! -f "$work/nfkc/nfkc-dump.txt" ]; then
    echo "==> NFKC dump (slow; cached after the first run)"
    ./scripts/gen-nfkc-tables.sh "$work/nfkc" >/dev/null
fi

echo "==> running every suite with all gates set"
ANYDOC_GRID_PROBE="$work/grid" \
ANYDOC_PDF_CORPUS="$work/corpus" \
ANYDOC_FONT_CORPUS="$work/font" \
ANYDOC_MCID_CORPUS="$work/mcid" \
ANYDOC_STRUCT_CORPUS="$work/struct" \
ANYDOC_CLASSIFY_PROBE="$work/classify" \
ANYDOC_NFKC_DUMP="$work/nfkc/nfkc-dump.txt" \
    swift test "$@" 2>&1 | grep -Ev "^􀟈|^􀄵 *Test|started\.$" || exit 1
