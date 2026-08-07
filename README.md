# swift-anydoc

Pure-Swift, zero-dependency port of [firecrawl/anydoc](https://github.com/firecrawl/anydoc):
convert documents (Word, PowerPoint, Excel, OpenDocument, RTF, EPUB, CSV, PDF) to
GitHub-Flavored Markdown. One library target, no Foundation, no Apple closed-source
frameworks — stdlib plus the platform libc only.

The Rust crate is the executable specification: outputs are validated **byte-for-byte**
against it (fixture snapshots, a differential CLI harness, and deterministic mutation
testing). See [PLAN.md](PLAN.md) for the full feasibility analysis, phase plan, and
validation strategy.

## Status

| Phase | Formats | Status |
| --- | --- | --- |
| 0 — harness & spine | model, GFM renderer, snapshot + differential harness | ✅ done |
| 1 — first slice | csv | ✅ byte-identical vs Rust (fixtures, adversarial, 120 mutants) |
| 2 | docx (+ ZIP, XML, OPC) | ⬜ next |
| 3 | odt/ods/odp, pptx, epub, xlsx | ⬜ |
| 4 | rtf | ⬜ |
| 5 | doc, ppt, xls/xlsb (+ CFB) | ⬜ |
| 6 | pdf | ⬜ |

## Usage

```swift
import AnyDoc

let markdown = try AnyDoc.markdown(contentsOf: "data.csv")
let fromBytes = try AnyDoc.markdown(bytes, format: .csv)
let document = try AnyDoc.document(bytes, format: .csv)  // model + assets
```

## Development

```bash
swift test                                   # unit tests + snapshot corpus
harness/diff.sh <rust-convert-bin> <dir>     # differential vs the Rust reference
```

Fixtures and golden outputs under `Tests/` come from anydoc (MIT); see
[Tests/Fixtures/README.md](Tests/Fixtures/README.md).
