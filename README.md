# swift-anydoc

Swift port of [firecrawl/anydoc](https://github.com/firecrawl/anydoc): convert documents
(Word, PowerPoint, Excel, OpenDocument, RTF, EPUB, CSV, PDF) to GitHub-Flavored Markdown.
One library target, no fetched dependencies, no Foundation, no Apple closed-source
frameworks — the Swift standard library, the platform libc, and the system zlib.

The Rust implementation is treated as an **executable specification**. Correctness is not
"the tests pass" but "the output matches the reference, byte for byte" — checked with
fixture snapshots, generated adversarial corpora, deterministic mutation sweeps, and
differential probes that run the reference's own code as an oracle. Where the reference
has a bug, this port reproduces it deliberately and says so at the call site.

See [PLAN.md](PLAN.md) for the feasibility analysis, the phase plan, the wave-by-wave
record, and every decision taken with its evidence.

## Status

**All 14 formats are ported.** `.xlsb` is deliberately unsupported — see below.

| Phase | Formats | Status |
| --- | --- | --- |
| 0 — harness & spine | document model, GFM renderer, snapshot + differential harness | ✅ |
| 1 | csv | ✅ |
| 2 | docx (+ ZIP, inflate, XML, OPC) | ✅ |
| 3 | odt / ods / odp, pptx, epub, xlsx | ✅ |
| 4 | rtf | ✅ |
| 5 | doc, ppt, xls (+ CFB, CJK codepages) | ✅ |
| 6 | pdf | ✅ |
| 7 | performance, docs, release | 🚧 in progress |

Extensions handled: `csv` `doc` `docm` `docx` `epub` `odp` `ods` `odt` `pdf` `pot` `pps`
`ppsm` `ppsx` `ppt` `pptm` `pptx` `rtf` `xls` `xlsm` `xlsx`.

### What "done" means here

- **57 of 58** reference fixtures convert byte-identically; the one exclusion is the PDF
  fixture, which has its own harness below.
- **168** generated adversarial PDFs, byte-identical against the reference binary.
- **1,384** corruption mutants: no crashes, no hangs.
- **265** hand-built adversarial documents across the other formats, plus corruption
  sweeps totalling over 6,000 mutants.
- 1,793 tests.

### `.xlsb` is deliberately unsupported

`Format.excel` covers `.xlsx`, `.xlsm` and binary `.xls`. The fourth member, `.xlsb`, is a
different record stream and is not implemented: the reference reaches it through the
`calamine` crate rather than its own code, **no fixture or snapshot exercises it on either
side**, and a port would therefore be written from the specification with nothing to check
it against. An `.xlsb` file currently fails as a malformed document rather than converting.
Given a fixture and a reference conversion, the rest is ordinary work — the CFB reader and
the shared spreadsheet model are already here.

## Usage

```swift
import AnyDoc

let markdown = try AnyDoc.markdown(contentsOf: "report.docx")
```

## Performance

Median in-process conversion over the fixture corpus, Apple silicon, release build:

| | median | peak RSS |
| --- | --- | --- |
| all formats | 0.23 ms | — |
| pdf | 6.5 – 7.3 ms | 5.8 MB |
| everything else | 0.03 – 4.9 ms | 2.9 – 4.4 MB |

The PDF figure is a range because it is one: repeated runs of the same benchmark on the
same machine land anywhere in it. Quoting the fastest run as *the* number is how a
benchmark becomes a claim it cannot support, so both ends are here.

PDF conversion runs at about **1.5×** the Rust reference on the same file and machine
(median of five interleaved trials; the spread across trials is 1.4–1.7×, so read it as
"about 1.5×" rather than a fixed number). `scripts/bench.py <fixture-dir>` reproduces the
table;
`anydoc-cli <file> --bench <runs>` times one file in-process, which is the only way to
measure formats whose conversion is faster than process startup.

## Building and testing

```bash
swift build
swift test
```

The suite runs offline and needs nothing else. The differential probes are opt-in — they
build the Rust reference locally as an oracle and are gated behind environment variables,
so a plain `swift test` skips them. One script sets all eight gates:

```bash
scripts/run-probes.sh /tmp/work
```

It vendors and builds the reference, generates every corpus (adversarial PDFs, corruption
mutants, font, marked-content, structure-tree, classifier and NFKC), and runs the suite
with each gate set. Use it rather than assembling the variables by hand: a gate pointed at
the wrong directory makes its suite compare nothing and report green, which is how three
suites once ran idle for eleven waves without anyone noticing. Nothing it generates is
committed — the corpora and oracle dumps are build products, and it needs `cargo`.

## Dependencies, enforced

`Package.swift` fetches nothing. A package may be added when it is pure Swift and supports
every platform this targets — macOS, iOS and Linux — and each must be named in
`scripts/lint-purity.sh`; the list is empty today. A *system* library may be linked when it
is already present on all three: `CZlib` is the one such link, for `zlib`, which replaced
the in-repo inflater on the hot path after profiling put a third of PDF conversion there.
The in-repo decoder remains as the fallback and is differentially tested against zlib.

`import Foundation` and Apple's closed-source frameworks are banned inside `Sources/AnyDoc`
and the ban is checked in CI; tests and tooling may use Foundation. CI builds on Linux,
where those frameworks do not exist, so the constraint holds structurally rather than by
convention.

Everything else is written in-repo: ZIP, MS-CFB, a namespace-aware XML pull parser
(matching the recovery behaviour of the reference's `quick-xml`, which is what the
malformed-document fixtures depend on), legacy codepage tables generated from the WHATWG
Encoding Standard, and the whole PDF stack.

**CI proves the package builds and the non-differential tests pass — nothing more.** The
differential suite is a local gate by deliberate choice, so that the published repository
carries no dependency on upstream. A green badge is not a differential result.

## Licence

MIT — see [LICENSE](LICENSE). This is a reimplementation of firecrawl/anydoc and
firecrawl/pdf-inspector, both MIT licensed; their notice and the attribution are in
[NOTICE](NOTICE). No upstream source is redistributed.
