# swift-anydoc

Pure-Swift, zero-dependency port of [firecrawl/anydoc](https://github.com/firecrawl/anydoc):
convert documents (Word, PowerPoint, Excel, OpenDocument, RTF, EPUB, CSV, PDF) to
GitHub-Flavored Markdown. One library target, no dependencies, no Foundation, no Apple
closed-source frameworks — the Swift standard library and nothing else.

The Rust implementation is treated as an **executable specification**. Correctness is not
"the tests pass" but "the output matches the reference, byte for byte" — checked with
fixture snapshots, generated adversarial corpora, deterministic mutation sweeps, and
differential probes that run the reference's own code as an oracle. Where the reference
has a bug, this port reproduces it deliberately and says so at the call site.

See [PLAN.md](PLAN.md) for the feasibility analysis, the phase plan, and the exact
remaining-work inventory.

## Status

**13 of 14 formats are complete.** PDF is in progress.

| Phase | Formats | Status |
| --- | --- | --- |
| 0 — harness & spine | document model, GFM renderer, snapshot + differential harness | ✅ |
| 1 | csv | ✅ |
| 2 | docx (+ ZIP, inflate, XML, OPC) | ✅ |
| 3 | odt / ods / odp, pptx, epub, xlsx | ✅ |
| 4 | rtf | ✅ |
| 5 | doc, ppt, xls (+ CFB, CJK codepages) | ✅ |
| 6 | pdf | 🚧 in progress |

Extensions handled: `csv` `doc` `docm` `docx` `epub` `odp` `ods` `odt` `pdf` `pot` `pps`
`ppsm` `ppsx` `ppt` `pptm` `pptx` `rtf` `xls` `xlsb` `xlsm` `xlsx`.

### PDF progress

The pipeline runs end to end — bytes → objects → cross-reference → filters → content
streams → ToUnicode-decoded text → glyph widths and positions → fragment merging → lines,
words and paragraphs → captions, headings, lists and code → emphasis and geometric
underlines → tables → Markdown, then a cleanup pass.

Complete: the object layer (classic and stream cross-references, object streams,
incremental updates), Flate/LZW/ASCII85 filters with PNG predictors, content-stream
interpretation, CID and simple font metrics, layout and reading order, graphics-path
extraction, link annotations and AcroForm fields, geometric underline and strikeout
detection, and the heuristic (borderless) table strategy.

Not yet ported: the ruled-table strategies (`detect_rects`, most of `detect_lines`),
structure-tree tables, base14/TrueType/glyph-name encodings for fonts without a
`ToUnicode` CMap, multi-column layout, scanned-vs-text classification, and encryption.
PLAN.md carries a per-file inventory.

## Usage

```swift
import AnyDoc

let markdown = try AnyDoc.markdown(contentsOf: "report.docx")
```

## Building and testing

```bash
swift build
swift test
```

The suite runs offline and needs nothing else. The differential probes are opt-in — they
build the Rust reference locally as an oracle and are gated behind environment variables,
so a plain `swift test` skips them:

```bash
scripts/gen-graphics-oracle.sh /tmp/oracle          # vendors the reference, builds probes
scripts/gen-pdf-corpus.py      /tmp/corpus          # 30 adversarial PDFs, generated
scripts/gen-pdf-oracles.sh     /tmp/corpus /tmp/oracle
scripts/gen-classify-probe.py  /tmp/probe
scripts/gen-grid-probe.py      /tmp/grid --oracle /tmp/oracle

ANYDOC_PDF_CORPUS=/tmp/corpus ANYDOC_CLASSIFY_PROBE=/tmp/probe \
  ANYDOC_GRID_PROBE=/tmp/grid swift test
```

These require `cargo` and the crates in the local registry. Nothing they generate is
committed — the corpora and oracle dumps are build products.

## Zero dependencies, enforced

`Package.swift` declares no dependencies. `import Foundation` and Apple's closed-source
frameworks are banned inside `Sources/AnyDoc` and the ban is checked by
`scripts/lint-purity.sh` in CI; tests may use Foundation. CI builds on Linux, where those
frameworks do not exist, so the constraint holds structurally rather than by convention.

Everything is written in-repo: inflate (RFC 1951), ZIP, MS-CFB, a namespace-aware XML
pull parser, legacy codepage tables generated from the WHATWG Encoding Standard, and the
PDF stack.

## Licence

MIT — see [LICENSE](LICENSE). This is a reimplementation of firecrawl/anydoc and
firecrawl/pdf-inspector, both MIT licensed; their notice and the attribution are in
[NOTICE](NOTICE). No upstream source is redistributed.
