#!/usr/bin/env bash
# Build the DocC catalog and fail on anything that would rot it.
#
# Two checks, because they catch different failures and one of them is not
# docc's idea of a problem:
#
#   1. --warnings-as-errors: broken symbol links. A curation entry naming a
#      symbol that does not exist, or a doc comment linking to a renamed one.
#
#   2. Auto-generated topic sections must be empty. docc files any public
#      symbol the catalog does not curate into a generic "Structures" /
#      "Functions" / "Enumerations" bucket and exits 0 — it considers this
#      fine. It is how a catalog that covers half its API still looks like it
#      works, which is exactly what happened in phase 7 wave 6: 12 symbols
#      curated, 14 silently bucketed. Check 1 does not catch this; it was
#      measured, not assumed.
#
# Needs Xcode's docc. No SPM dependency: swift-docc-plugin would trip the
# purity gate and make the build fetch.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcrun --find docc >/dev/null 2>&1; then
  echo "docs lint: SKIP (no xcrun docc — needs Xcode)"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
graphs="$work/symbol-graphs"
out="$work/docs"
mkdir -p "$graphs"

swift build \
  -Xswiftc -emit-symbol-graph \
  -Xswiftc -emit-symbol-graph-dir -Xswiftc "$graphs" >/dev/null

xcrun docc convert Sources/AnyDoc/AnyDoc.docc \
  --fallback-display-name AnyDoc \
  --fallback-bundle-identifier org.swift.anydoc \
  --additional-symbol-graph-dir "$graphs" \
  --output-path "$out" \
  --warnings-as-errors

python3 - "$out" <<'PY'
import json, pathlib, sys

landing = pathlib.Path(sys.argv[1]) / "data" / "documentation" / "anydoc.json"
if not landing.exists():
    sys.exit("docs lint: FAIL — docc produced no landing page")

sections = json.load(landing.open()).get("topicSections", [])
generic = {"Structures", "Classes", "Enumerations", "Protocols",
           "Functions", "Variables", "Type Aliases", "Macros"}

stray = [(s["title"], s["identifiers"]) for s in sections if s["title"] in generic]
if stray:
    print("docs lint: FAIL — public symbols are not curated in AnyDoc.docc/AnyDoc.md")
    print("docc filed these into auto-generated sections and still exited 0:")
    for title, ids in stray:
        for i in ids:
            print(f"    {title:<14} {i.split('/documentation/')[-1]}")
    print("\nAdd each to a '### ...' list under ## Topics.")
    sys.exit(1)

total = sum(len(s["identifiers"]) for s in sections)
print(f"docs lint: OK ({total} symbols curated across "
      f"{len(sections)} sections, no stray buckets)")
PY
