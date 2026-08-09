# swift-anydoc: Feasibility Analysis & Implementation Plan

Reimplementation of [firecrawl/anydoc](https://github.com/firecrawl/anydoc) (v0.1.7, MIT) as a
pure-Swift, cross-platform SwiftPM library — no Apple closed-source frameworks, no C
dependencies, no bindings to other languages.

**Verdict: feasible.** The library is deterministic byte/XML parsing with zero OS-service
dependencies — exactly the kind of code that ports cleanly from Rust to Swift. The one
outsized workstream is PDF: anydoc delegates all PDF handling to a sibling crate
([pdf-inspector](https://github.com/firecrawl/pdf-inspector), ~80k LOC) that alone outweighs
the rest of the project. Decision: build the core (13 of 14 formats) first; PDF is the final
phase, inside the same single library target.

---

## 1. What anydoc is

- ~17,100 LOC of Rust (core crate, excluding bindings/tests).
- Converts Word (`.doc/.docx/.docm`), PowerPoint (`.ppt/.pps/.pot/.pptx/.pptm/.ppsx/.ppsm`),
  Excel (`.xls/.xlsx/.xlsm/.xlsb`), OpenDocument (`.odt/.ods/.odp`), RTF, EPUB, CSV, and PDF
  to GitHub-Flavored Markdown.
- Architecture: content-based format detection → per-format parser → **shared document
  model** (`Block`/`Inline`/`Table`/`List`/assets/anchors/footnotes) → single GFM renderer.
  PDF is the exception: pdf-inspector emits Markdown directly, bypassing the model.
- Hard, non-configurable resource limits (decompression bombs, XML depth/node caps, repeat
  expansion caps) returning a typed `ResourceLimit` error.
- Error model: `Unsupported | Malformed | Encrypted | ResourceLimit | MissingPart | Io`.
- Recovery philosophy: degrade with a log, error only when no meaningful Markdown can be
  produced. Malformed-input behavior is *specified and snapshot-tested*.

### Rust module inventory (port targets, LOC as of v0.1.7)

| Module | LOC | Notes |
|---|---|---|
| `model/` | 879 | Enums + structs; maps 1:1 to Swift enums with associated values |
| `render/` (GFM) | 1,809 | Escaping, tables, anchors, inline styling |
| `shared/` | 2,860 | DrawingML, OfficeArt, field codes, grid builder, list/numbering, HTML-ish text |
| `package/` | 1,179 | ZIP/CFB abstraction, OPC relationships, XML DOM wrapper, limits |
| `formats/rtf` | 2,044 | Lexer + control-word tables + table model |
| `formats/doc` | 1,986 | Binary Word 97 (FIB, piece table, SPRMs, STSH, lists) over CFB |
| `formats/docx` | 1,862 | Content, styles, numbering |
| `formats/odf` | 1,452 | odt/ods/odp share one parser |
| `formats/ppt` | 867 | Legacy binary record stream over CFB |
| `formats/pptx` | 838 | Slide/layout/master style cascade |
| `formats/sheet` | 310 | Thin wrapper over **calamine** (real parsing lives in the dep) |
| `formats/epub` | 208 | OPF spine + XHTML via shared HTML mapper |
| `formats/csv` | 153 | Wrapper over **csv** crate + encoding sniff |
| detect + pdf + glue | ~430 | |

### Dependencies and what they hide

| Rust crate | Role | Swift replacement strategy |
|---|---|---|
| `zip` (deflate only) | OOXML/ODF/EPUB containers | Own minimal ZIP reader (central directory + local headers, stored/deflate) ≈ 600 LOC + inflate (RFC 1951) ≈ 700 LOC, or `SWCompression` (pure Swift, MIT) to start |
| `flate2` | Raw deflate for OfficeArt blobs | Same inflate as above |
| `quick-xml` | Namespace-aware XML | Own streaming pull parser ≈ 1.5–2k LOC. anydoc already wraps it in a 623-LOC DOM (`package/xml.rs`) with interned namespaces, depth/node caps, and deliberate tag repair — port that design |
| `cfb` | OLE2/Compound File (doc/ppt/xls containers) | Own MS-CFB reader (FAT, mini-FAT, directory) ≈ 800–1,000 LOC |
| `calamine` | xlsx/xlsm/xlsb/xls cell extraction | The only *large* hidden dep besides PDF. anydoc uses a narrow slice: sheet names, cell values (shared strings, number formats → date/time/duration), merged regions. Own focused readers: xlsx ≈ 1.2k, xls BIFF8 ≈ 2k, xlsb ≈ 1.2k LOC |
| `csv` | CSV parsing | Own RFC-4180 parser with delimiter sniffing ≈ 300 LOC |
| `encoding_rs` | Legacy codepages (RTF `\ansicpg`, .doc charsets, CSV sniffing) | Generated decode tables from the WHATWG Encoding Standard index files (same upstream data encoding_rs uses). Single-byte pages are 128-entry tables; CJK (cp932/936/949/950) are larger generated tables. ≈ 300 LOC logic + generated data |
| `log` | Recovery-event reporting | Tiny internal logger protocol (callback), keeps zero-dependency goal; `swift-log` optional adapter |
| `pdf-inspector` | All of PDF → Markdown | **The long pole.** See §4 |

pdf-inspector itself: ~80.7k LOC, of which ~21.7k are generated tables (Adobe-Korea1 CMap
data, AGL glyph names); ~59k LOC of real logic (detector, content-stream interpreter, font/
encoding handling incl. ToUnicode + CID CMaps + TrueType `cmap` parsing, layout/reading
order, four table-detection strategies, Markdown assembly) **plus** its own deps: `lopdf`
(full PDF object/xref/stream parser), `ttf-parser` (subset), `regex`, ICU-free unicode
normalization, and 1.6 MB of bundled binary CMaps.

---

## 2. Why pure Swift works (and what "pure" means here)

**Nothing in anydoc needs an OS service.** No rendering, no fonts-on-screen, no network, no
ML. Input `[UInt8]` → output `String`. Every format has an open specification: MS-CFB,
MS-DOC, MS-PPT, MS-XLS, MS-XLSB (Microsoft Open Specifications), ECMA-376 (OOXML), OASIS ODF
1.3, RTF 1.9.1, EPUB 2/3, RFC 4180, ISO 32000 (PDF).

**Language fit is excellent.** The Rust design is enums-with-payloads + pattern matching +
value semantics — Swift has all three natively. `Block`/`Inline` port almost token-for-token
to Swift enums with associated values. No lifetimes gymnastics: anydoc parses from owned
byte buffers.

**Dependency policy — DECIDED: zero dependencies.** Swift stdlib only; everything else
(inflate, ZIP, CFB, XML, encodings, and eventually the PDF stack) written in-repo. No
`FoundationEssentials`, no `SWCompression` — `Package.swift` declares no dependency at all.
This is a genuine selling point for a library meant to be embedded anywhere (server-side
Swift, iOS, Wasm eventually), and it makes the purity gate (§5.7) trivial to enforce.

**Explicitly banned** (closed-source or non-Swift): `Foundation`'s Objective-C runtime
surface on Apple platforms, `Compression.framework`, `PDFKit`, `CoreGraphics`, `AppKit`/
`UIKit`, `FoundationXML` (wraps libxml2), `NSRegularExpression`/ICU. Swift's native `Regex`
(stdlib, pure Swift) is fine if ever needed (PDF phase).

**Enforced structurally, not by promise:** primary CI runs on **Linux**, where Apple
closed-source frameworks do not exist — if it builds and passes there, the constraint holds.
Plus a lint step that greps for banned imports.

### Swift-specific porting gotchas (each becomes a checklist item)

1. **Float formatting.** `format!("{}", 1.0_f64)` → `"1"` in Rust; `"\(1.0)"` → `"1.0"` in
   Swift. Spreadsheet output would diverge everywhere. Write one `formatDouble()` matching
   Rust's shortest-round-trip + anydoc's 15-significant-digit rule, golden-tested against
   values harvested from the Rust implementation.
2. **No `catch_unwind`.** Rust wraps calamine in a panic barrier; a Swift `fatalError`/trap
   kills the process. All Swift parser code must be *total*: no force unwraps, no unchecked
   subscripts on input-derived indices, explicit overflow-checked/`&+`-style arithmetic
   choices in binary parsers (Swift traps on overflow by default, like Rust debug builds —
   fuzzing will find every violation, which is exactly what we want).
3. **Deterministic ordering.** Any `Dictionary` iteration that reaches output must be
   sorted (Swift's `Dictionary` order is nondeterministic *per process*, worse than Rust's
   per-build HashMap). Grep-able rule: no `for (k, v) in dict` in render paths.
4. **String/Unicode.** Keep parsing on `[UInt8]`, decode once at run boundaries (same as
   the Rust code). Avoid `String.Index` arithmetic in hot paths.
5. **Grapheme clusters vs. bytes.** *Swift `String` compares grapheme clusters; Rust `str`
   compares bytes.* `hasPrefix`, `contains`, `hasSuffix`, `first`, `count` and `for c in s`
   all silently disagree with their Rust spelling on any text carrying a combining mark:
   `"•" + U+0301` is **one** Swift `Character` and **two** Rust `char`s, so a bullet the
   reference strips is a bullet Swift does not see. This is invisible in ASCII fixtures and
   was only caught by a 22k-string differential probe (PDF wave 7 — three real bugs, plus
   the same bug in the probe's own harness). **Rule:** any prefix/suffix/substring test
   against a literal taken from the Rust must run on `unicodeScalars`; helpers
   `scalarsHavePrefix` / `scalarsContain` / `droppingScalars` exist for this. Likewise
   `to_lowercase()` is `rustLowercased()`, never `asciiLowercased()`.
6. **Error mapping.** Mirror `ConvertError` variant-for-variant including the stable
   `code` strings (`"unsupported"`, `"malformed"`, …) so error-class parity is testable.

---

## 3. Proposed architecture

```
swift-anydoc/
├── Package.swift                  # swift-tools 6.x, platforms: macOS 13+, iOS 16+, Linux
├── Sources/
│   ├── AnyDoc/                    # the library (single product)
│   │   ├── AnyDoc.swift           # public API
│   │   ├── Format.swift           # detection: bytes / extension / path
│   │   ├── ConvertError.swift
│   │   ├── Model/                 # Block, Inline, Table, List, Style, Asset, Anchor
│   │   ├── Render/                # GFM serializer: escape, tables, anchors, inline
│   │   ├── Package/               # Zip, Inflate, Cfb, Xml (pull parser + capped DOM),
│   │   │                          # Relationships, Limits, PathResolve
│   │   ├── Encoding/              # codepage tables (generated) + decoder
│   │   ├── Shared/                # grid builder, numbering, drawingml, officeart,
│   │   │                          # fields, html mapper, text cleanup, uri
│   │   ├── Formats/
│   │   │   ├── Csv/  Epub/  Sheet/   (xlsx, xls, xlsb)
│   │   │   ├── Docx/ Odf/  Pptx/ Rtf/
│   │   │   └── Doc/  Ppt/            (legacy binary, over Cfb)
│   │   └── Pdf/                   # Phase 6, same target: object layer, fonts/CMaps,
│   │                              # layout, tables, markdown (CMap data as resources)
│   └── anydoc-cli/                # tiny executable target: file in → markdown out
│                                  # (needed by the differential harness; also useful)
├── Tests/
│   ├── AnyDocTests/               # unit tests, ported per-module tests
│   ├── SnapshotTests/             # fixture corpus → golden .md files (ported .snap)
│   ├── RobustnessTests/           # deterministic mutation sweep (ported xorshift64*)
│   └── Fixtures/                  # copied from anydoc (MIT) + snapshots as golden files
├── Fuzz/                          # libFuzzer targets (swift build --sanitize=fuzzer)
├── harness/                       # differential runner: Rust anydoc vs swift-anydoc
└── PLAN.md
```

### Public API (Swift idiom, 1:1 with Rust surface)

```swift
public enum AnyDoc {
    /// Markdown from bytes; format detected from content unless named (CSV needs naming).
    public static func markdown(_ bytes: some Collection<UInt8>, format: Format? = nil) throws -> String
    public static func markdown(contentsOf path: String) throws -> String
    /// Stop at the document model (carries embedded assets). Unsupported for PDF.
    public static func document(_ bytes: some Collection<UInt8>, format: Format? = nil) throws -> Document
}

public enum Format: Sendable { case doc, docx, odt, pdf, ppt, pptx, rtf, epub, excel, ods, odp, csv
    public static func detect(from bytes: some Collection<UInt8>) -> Format?
    public init?(extension: String)
    public init?(path: String)
}

public enum ConvertError: Error, Sendable {
    case unsupported(String)
    case malformed(part: String?, detail: String)
    case encrypted
    case resourceLimit(limit: String, detail: String)
    case missingPart(String)
    case io(any Error)
    public var code: String { … }   // stable: "unsupported" | "malformed" | …
}
```

All model types are value types and `Sendable`; the API is stateless and thread-safe by
construction.

---

## 4. Phase plan

Ordering principle: stand up the *shared spine* (containers → XML → model → renderer) with
the easiest format proving it end-to-end, then add formats in order of (value ÷ risk),
finishing with the legacy binary formats and PDF. **The validation harness (Phase 0/1) comes
first, not last** — every later phase lands with its differential tests green.

### Phase 0 — Skeleton + validation harness (do this before any parser)
- SwiftPM package, CI matrix (Linux + macOS; ASan job; banned-import lint).
- Copy `tests/fixtures/` and `tests/snapshots/` from anydoc (MIT, keep attribution);
  write the converter that turns insta `.snap` files into plain golden `.md`/`.err` files.
- Snapshot test runner: convert fixture → compare to golden, byte-exact; malformed fixtures
  assert outcome encoded in the filename (`--recovers/--skips/--ignores/--errors`).
- Differential harness (`harness/`): runs the *Rust* anydoc CLI (the executable spec) and
  `anydoc-cli` (Swift) over a directory, reports byte-identical / normalized-equal /
  divergent / error-class-mismatch. This harness is the project's definition of "correct".
- `ConvertError`, `Limits` (same constants, same names), logger protocol.
- Exit criteria: harness runs end-to-end with a stub converter that fails everything.

### Phase 1 — Spine + CSV (first green format)
- `Encoding/` (UTF-8/16 + sniffing; codepage tables generated by a checked-in script).
- CSV parser (delimiter sniff, quoting) → model → **GFM renderer** (port `render/markdown/`
  fully: escaping, tables, anchors — it's shared by everything, get it right once).
- Model port (`model/`, 879 LOC) + `Shared/grid` + header-row resolution.
- Exit: all 4 CSV snapshots byte-identical to Rust.

### Phase 2 — ZIP + XML + first XML format: DOCX
- Inflate (RFC 1951) + ZIP reader with entry/total/count limits; CRC check.
- XML pull parser + the capped, namespace-interning DOM (port of `package/xml.rs` design,
  including deliberate tag-repair behavior and depth/node caps).
- OPC layer: `[Content_Types].xml`, relationships, part-path resolution.
- DOCX: content, styles, numbering (largest XML format, exercises everything: DrawingML,
  fields, footnotes, tables, lists, anchors, assets).
- Exit: all 10 docx snapshots identical; robustness sweep on docx fixtures clean.

### Phase 3 — The other ZIP/XML formats
- ODF (odt/ods/odp — one parser + styles/table/text submodules).
- PPTX (slide/layout/master cascade, speaker notes).
- EPUB (OPF spine + shared HTML mapper — port `shared/html.rs` here).
- XLSX (own reader replacing calamine: shared strings, number formats → the exact
  date/time/duration rendering rules in `formats/sheet`, merged regions).
- Exit: odt/ods/odp/pptx/epub/xlsx snapshots identical.

### Phase 4 — RTF
- Lexer, control-word tables, encoding switching (`\ansicpg`, `\u` fallbacks), tables.
  Self-contained; no container work.
- Exit: 5 rtf snapshots identical.

### Phase 5 — Legacy binary: CFB, DOC, PPT, XLS (+XLSB)
- CFB reader; format detection by OLE stream names completes `Format.detect`.
- DOC: FIB, piece table (the fun part: 16-bit/8-bit piece encoding), SPRM decoding, STSH
  styles, list tables.
- PPT: bounded record-stream walker (`MAX_RECORD_DEPTH`/`MAX_RECORDS`), StyleTextPropAtom.
- XLS: BIFF8 (SST, formats, MERGEDCELLS, RK/number decoding); XLSB record reader.
- Exit: doc/ppt/xls snapshots identical; full robustness sweep green across all formats.

**Milestone: core parity.** 13 of 14 formats, differential harness green on the fixture
corpus and a large external corpus (§5.3). This is a releasable 0.x.

### Phase 6 — PDF (inside the same `AnyDoc` target, under `Sources/AnyDoc/Pdf/`)
Honest sizing: this phase alone is comparable to Phases 0–5 combined.
- PDF object layer (lopdf subset): lexer, xref + xref streams, object streams, filters
  (FlateDecode, LZW, ASCIIHex/85, RunLength; DCT/JPX passthrough), encryption (RC4, AES-CBC
  — needed just to *read* many PDFs). Zero-dep policy: write RC4 (~50 LOC), MD5 (~150 LOC),
  and a decrypt-only AES-CBC (~400 LOC) in-repo — well-specified, test-vector-verified,
  used only for the standard PDF security handler, not general cryptography.
- Fonts & text mapping: base14 metrics/encodings, `ToUnicode` CMaps, predefined CJK CMaps
  (bundle the ~1.6 MB bcmaps as a SwiftPM resource), TrueType `cmap` subset parser, AGL
  glyph names (generated table).
- Content-stream interpreter → positioned text runs; layout/reading order; link annotations.
- Table detection (port all four strategies: structure tree, ruled lines, rects, heuristic).
- Markdown assembly (headings by size/weight clustering, lists, code, postprocess).
- Scanned-page classification (`pages_needing_ocr`) with the same "no text → Unsupported"
  contract.
- Validate with the same differential approach, against `pdf-inspector`'s own test corpus
  plus external PDF corpora.

### Phase 7 — Polish & release
- Performance pass (see §5.6 targets), allocation profiling on the bench corpus.
- API docs (DocC), README with the same format table, SemVer, CI release automation.

---

## 5. Validation strategy — "how exactly do we know it works"

The single organizing idea: **the Rust implementation is an executable specification.**
We never have to *decide* what correct output is — we diff against it. Every layer below
strengthens that.

### 5.1 Ported snapshot corpus (exactness, per commit)
- All 58 committed snapshots become golden files; CI requires **byte-identical** output.
  Any intentional divergence needs a checked-in, reviewed `DIVERGENCES.md` entry with a
  reason (target: zero entries).
- Malformed fixtures (10) assert the encoded outcome *and* the error class; abuse fixtures
  (8) assert `ResourceLimit` with bounded wall-time and peak memory (run under a watchdog:
  e.g. 10 s / 2 GB caps in CI).
- Port anydoc's *inline unit tests* alongside each module (e.g. the float-formatting,
  time-of-day, merged-region tests in `formats/sheet` — they encode a lot of specified
  behavior).

### 5.2 Deterministic mutation robustness (crash-freedom)
- Port `tests/robustness.rs` including its **xorshift64\* PRNG and seed verbatim** — the
  mutation stream is then byte-identical across both implementations, so this doubles as a
  differential test on ~25 mutants × corpus: Swift must never crash/hang, and where Rust
  returns a typed error class, compare classes (informational at first, ratcheted to
  asserted once stable).

### 5.3 Large-corpus differential run (breadth, scheduled)
- Corpus: [govdocs1](https://digitalcorpora.org/corpora/file-corpora/files/) (~1M real files
  incl. huge doc/xls/ppt/pdf populations), plus Common Crawl-harvested OOXML/ODF, plus any
  private docs we can use locally. Not committed to the repo; a `harness/fetch_corpus.sh`
  pins the subset by hash.
- Metrics per format, tracked over time in a dashboard file:
  - `identical`: byte-identical Markdown (primary target: ≥ 99.5% per format at core-parity
    milestone, 100% on the fixture corpus);
  - `equivalent`: identical after whitespace normalization (should trend to merge with
    `identical`);
  - `error-parity`: same `ConvertError` class on failing inputs;
  - `divergent`: everything else — each one triaged: Swift bug (fix), Rust bug (report
    upstream, document), or acceptable (documented).
- Nightly job; a PR gate runs a pinned 1k-file sample.

### 5.4 Differential + coverage-guided fuzzing (adversarial depth)
- Port the 9 per-format fuzz targets; run with Swift's built-in libFuzzer support
  (`swift build --sanitize=fuzzer` on the Linux CI runner), seeded from the fixture corpus.
  Property: no crash, no hang, no unbounded memory — same property the Rust targets assert.
  This is also what proves the "no `catch_unwind` in Swift" discipline (§2, gotcha 2).
- Differential fuzz mode: harness feeds each corpus/fuzz-generated input to both binaries;
  assert (a) same success/failure, (b) same error class, (c) identical output on success.
  Run continuously pre-1.0; findings become committed regression fixtures.
- ASan + overflow checks on in CI test builds (Swift's default overflow trapping stays ON —
  a trap under fuzz is a bug found, not an annoyance).

### 5.5 Quality benchmark (external validity)
- anydoc's `bench/` harness (LLM-judge vs LibreOffice-rendered ground truth) is in the
  repo. Add `swift-anydoc` as a judged tool and run the same 14-format comparison.
  Expected: statistically indistinguishable from Rust anydoc *by construction* (outputs are
  byte-identical); this run is the end-to-end proof, and any per-format score gap > noise
  flags a divergence class the byte-diff metrics missed (e.g. asset handling).

### 5.6 Performance & footprint
- Same bench corpus, same machine, warm conversions: report median/p95 per format.
  Targets: within **2× Rust median** at core-parity (Rust: 4.4 ms median), within 1.5×
  after the Phase 7 pass; peak RSS within 1.5×. Track in CI on a pinned runner with a
  regression tripwire (>15% regression fails the job).
- Library size: binary-size report per release (matters for iOS embedding).

### 5.7 Portability & purity gates (the "no Apple closed source" proof)
- **Linux is the primary CI target** — Apple closed frameworks cannot be linked there.
- macOS + iOS-simulator build jobs prove Apple-platform usability.
- Lint job: fail on `import Foundation`, `import FoundationEssentials`,
  `import FoundationXML`, `import Compression`, `import PDFKit`, `import CoreGraphics`, or
  any `@_silgen_name`/`dlopen` escape hatch inside `Sources/AnyDoc/`. `Package.swift`
  declares zero dependencies.
- Strict concurrency (`-strict-concurrency=complete`) and `Sendable` conformance checked.

### 5.8 Definition of done, per phase and overall
A format is "done" when: (1) its fixture snapshots are byte-identical; (2) its inline unit
tests are ported and green; (3) robustness sweep is clean; (4) its fuzz target has ≥ 72 h
CPU without findings; (5) the external-corpus differential for that format meets the §5.3
targets. The **library** is 1.0-ready when all formats are done, the quality bench matches
Rust, perf targets hold, and the purity gates are green on Linux.

---

## 6. Effort estimate (honest ranges)

| Workstream | Swift LOC (est.) | Relative effort |
|---|---|---|
| Phase 0–1: harness, spine, model, renderer, CSV | ~7k | ██ |
| Phase 2: inflate+ZIP, XML, OPC, DOCX | ~7k | ███ |
| Phase 3: ODF, PPTX, EPUB, XLSX | ~6k | ███ |
| Phase 4: RTF | ~2.5k | █ |
| Phase 5: CFB, DOC, PPT, XLS/XLSB | ~7k | ███ (spec-reading heavy) |
| **Core total (13/14 formats)** | **~30k** | |
| Phase 6: PDF (object layer, fonts/CMaps, layout, tables, markdown) | ~35–50k | ████████ (≈ everything above) |

Two calibration points: the Rust core is 17k LOC *plus* roughly comparable hidden LOC in
`calamine`/`zip`/`quick-xml`/`cfb` subsets; pdf-inspector is ~59k LOC of logic plus `lopdf`.
The estimates above assume aggressive reuse of the Rust code as a line-by-line porting
reference (which the MIT license permits, with attribution), not clean-room reimplementation.

## 7. Key risks

1. **PDF scope creep** — mitigated by phasing it behind core parity and shipping 13/14 first.
2. **Byte-exactness friction** (float printing, dictionary order, Unicode edge cases) —
   mitigated by the §2 gotcha checklist and the differential harness catching every one.
3. **Upstream drift** — anydoc is actively developed; pin the reference version (v0.1.7),
   and re-run the differential harness against new tags to plan catch-up work deliberately.
4. **Trap-vs-error discipline in Swift** — no panic barrier exists; only fuzzing + mutation
   testing enforce totality. Budget real fuzz time from Phase 2 onward, not at the end.
5. **Legacy encodings coverage** — generate tables from WHATWG index files with a committed
   generator script, and add RTF/doc fixtures in cp932/949/950/936 beyond the corpus's
   existing cyrillic/shift-jis cases.

## 8. Decisions taken

1. **Zero dependencies** — stdlib only, everything in-repo (including PDF-era crypto/CMaps).
2. **One library** — a single `AnyDoc` product/target contains all code; PDF lives under
   `Sources/AnyDoc/Pdf/` and ships when Phase 6 completes (no sibling package).

## 9. Status

- **Phase 0 — done.** Package skeleton (zero-dep `AnyDoc` library + `anydoc-cli` +
  tests), fixture corpus and 58 goldens imported (`scripts/import-goldens.py`),
  snapshot sweep with per-format gating, differential harness (`harness/diff.sh`).
- **Phase 1 — done.** CSV vertical slice: model + GridBuilder, header-row resolution,
  GFM renderer (escape/inline/table/anchors), encoding sniff (UTF-8/16/cp1252), CSV
  reader matching the Rust `csv` crate's lenient semantics. Validated byte-identical
  against the actual Rust binary: 4/4 fixtures, 9/9 adversarial cases, 120/120
  deterministic mutants (corrupt bytes + truncations).
- **Phase 2 — done.** Inflate (RFC 1951) + ZIP reader with entry/total/count limits and
  CRC checking, XML pull parser + capped namespace-interning DOM, OPC layer
  (content types, relationships, part-path resolution), MS-CFB reader, and the shared
  modules (DrawingML, OfficeArt, fields, list/numbering, HTML mapper, grid builder).
  DOCX landed on top: all 10 docx snapshots byte-identical.
- **Phase 3 — done.** ODF (odt/ods/odp), PPTX, EPUB, and XLSX. All 41 fixtures for the
  ported formats are byte-identical to the Rust binary; 10 malformed fixtures match on
  error class.
  - XLSX replaces `calamine` with an in-repo reader of the slice anydoc uses: shared
    strings (rich text, phonetic skipping, `xml:space`, `_x00HH_` escapes), the
    number-format table that decides which numbers are dates, the cell grid, and
    merged regions. Includes `rustFormatF64` — Rust's positional `f64` `Display` plus
    the exact-decimal 15-significant-digit rounding spreadsheets need (§2, gotcha 1).
  - Validated beyond the fixtures: 43 hand-built adversarial workbooks (float
    precision, all reserved and custom format codes, serial edge values incl. the 1900
    leap-year bug and the 1904 epoch, every cell type, merge geometry, implicit cell
    positions, malformed parts) byte-identical to the Rust binary; a 1050-mutant
    corruption sweep with zero crashes, zero hangs and zero output divergences (~6% of
    mutants still differ on error *class*, all of them corrupt-input-only).
- **Phase 4 — done.** RTF: position-explicit lexer (`\binN` consumes raw bytes, so binary
  payloads cannot corrupt group state), the font/style/list prelude tables, and a group-
  scoped state machine over them. Numbering comes from the list tables, never from label
  text. All 5 rtf snapshots plus the unbalanced-recovery fixture are byte-identical.
  - Added `Shared/Grid.swift` (edge-based table assembly from `\cellx` boundaries, shared
    with Phase 5's binary DOC) and `Encoding/Codepages.swift` — the single-byte Windows
    code pages, generated by `scripts/gen-encoding-tables.py` from the same WHATWG tables
    `encoding_rs` uses, so the port cannot drift from the reference by a code point.
  - Validated: 105 hand-built adversarial documents (lexer edge cases, `\uN`/`\ucN`
    fallbacks and surrogate pairs, five code pages, style inheritance incl. cycles, list
    tables and overrides, table merges and nesting, every destination) byte-identical to
    the Rust binary; 2,750 corruption mutants with zero crashes, zero hangs, zero
    error-class divergences and zero output divergences.
  - The sweep caught one real porting bug: the list-override flush must consume both its
    list id and its `\ls` even when only one is set, or a half-filled override leaks its
    id into the next one (`Option::take()` semantics). Regression-tested.
  - **Known gap:** the multi-byte CJK code pages (shift_jis, gbk, euc-kr, big5) are not
    ported. A document selecting one decodes as windows-1252 with a logged warning. They
    land in Phase 5, which needs the same decoders for binary `.doc`.
- **Phase 5 wave 1 — done.** XLS (BIFF8) over the existing CFB reader, replacing calamine's
  `xls.rs` slice: the record stream with `CONTINUE` folding, `BoundSheet8`/`SST`/`XF`/
  `Format` globals, and the `Number`/`RK`/`MulRk`/`Label`/`LabelSst`/`BoolErr`/`Formula`/
  `MergeCells` cell records. Formula *token* parsing is deliberately absent — anydoc only
  ever reads the cached values. `Format.excel` is now complete for `.xls` and `.xlsx`;
  `.xlsb` (a different record stream) remains unported and gated out.
  - Validated: `xls__sheet.xls` byte-identical, 26 hand-built adversarial workbooks
    byte-identical (built by writing the OLE container and BIFF records directly, since
    no converter is installed), and 650 corruption mutants confined to the BIFF stream
    with **zero divergences of any kind**.
  - Known container-layer divergence: mutating the *CFB* header/FAT/directory produces
    error-class divergences (~18% of whole-file mutants), because anydoc reaches `.xls`
    through calamine's own permissive compound-file reader while `Package`/`Cfb` here
    mirrors the stricter `cfb` crate anydoc uses for `.doc`/`.ppt`. Corrupt-container
    inputs only; whenever both implementations accept a file they agree byte-for-byte.
- **Phase 5 wave 2 — done.** PPT: the UserEditAtom chain resolved into the persist
  directory, slide/notes/master lists off the DocumentContainer, a bounded iterative
  record walk (`maxRecordDepth`/`maxRecords`), `TextHeaderAtom` +
  `TextCharsAtom`/`TextBytesAtom` text, and the `StyleTextPropAtom` /
  `TxMasterStyleAtom` cascade. Notes pair to slides by stored slide id rather than list
  position. Raw stream-order scanning stays the explicitly labelled recovery path.
  - Validated: all 3 ppt snapshots plus `brokenpersist--recovers.ppt` byte-identical,
    26 hand-built adversarial decks byte-identical (OLE container and PowerPoint records
    written directly, covering the persist chain, master cascade, mask layouts, notes
    pairing and the recovery path), and 725 corruption mutants with zero divergences of
    any kind.
- **Phase 5 wave 3a — done.** shift_jis, closing the largest part of the CJK gap Phase 4
  left open. `Sources/AnyDoc/Encoding/ShiftJis.swift` holds the WHATWG `index jis0208`
  table, recovered by asking `encoding_rs` itself what every valid byte pair means
  (`scripts/dump-cjk-tables/` + `scripts/gen-shiftjis-table.py`). Verified exhaustively:
  all 9,604 mapped byte pairs decode identically to the reference. RTF `\fcharset128`,
  `\ansicpg932` and the XLS code-page record now select it.
  - **Still open:** gbk, euc-kr and big5 remain unported and fall back to windows-1252
    with a logged warning. No fixture exercises them; the same dumper covers them when
    they are needed.
- **Phase 5 wave 3b — done.** DOC, the last unported format of the core 13: FIB, piece
  table with `Prm`/`Prm0` decoding, CHPX/PAPX runs out of the FKP pages applied over the
  STSH `istdBase` chains in specification order, the PlfLst/PlfLfo list tables with their
  restart and start-at rules, and tables through the shared `buildEdgeTable`.
  - Validated: all 4 doc snapshots plus `truncated--errors.doc` byte-identical, 39
    hand-built adversarial documents byte-identical (OLE container, FIB, piece table,
    FKP pages, style sheet and list tables all written directly), and 1,075 corruption
    mutants with zero divergences of any kind.

## Milestone: core parity

**All 13 non-PDF formats are ported.** The snapshot corpus compares 57 of 58 fixtures
byte-for-byte against the Rust binary (the remaining one is the PDF fixture); the
differential harness reports 53 identical / 0 divergent / 12 error-class matches.
265 hand-built adversarial documents across every format are byte-identical, and the
corruption sweeps total well over 6,000 mutants with no crashes, no hangs, and no
output divergences.

Known gaps, all documented above: `.xlsb` (a distinct record stream), the gbk / euc-kr /
big5 code pages (no fixture exercises them), and the `.xls` container-layer strictness
difference on corrupt compound files.

## CI (pulled forward from Phase 7)

`.github/workflows/ci.yml` runs nine jobs, all of them **offline** — the package
declares no dependencies, so nothing in CI ever needs the network:

| Job | What it is for |
|---|---|
| `purity` | The §5.7 gate, on its own so a stray dependency reports separately from a build failure |
| `linux` (Swift 6.0/6.1 × debug/release) | The portability gate: Apple's closed frameworks do not exist here, so green is structural proof |
| `macos` (debug/release) | Apple-platform usability |
| `ios` | `xcodebuild` against the iOS SDK, with an explicit check that an `iphonesimulator` module was really produced — `xcodebuild` exits 0 for a scheme that resolved to no platform |
| `sanitizers` | ASan on Linux. The port has no panic barrier, so this is what proves the byte-level readers stay in bounds; debug builds also keep Swift's overflow traps on |

The **differential harness is deliberately not a CI job.** It is the project's
definition of correct, but it needs a Rust toolchain and a build of the reference
(which pulls `pdf-inspector`), which would make CI slow, network-dependent and flaky.
It stays a local/manual gate — `harness/diff.sh <reference-binary> <path>` — run before
every format lands, exactly as it has been. §5.3's scheduled large-corpus run is still
future work and would carry the same requirement.

The abuse corpus is now asserted as a whole (`Tests/AnyDocTests/AbuseTests.swift`):
every fixture must fail with `ResourceLimit` *and* fail fast, so a limit that stops
bounding work fails the build rather than merely taking longer. The `Limits` constants
are pinned by a test so a change to one is deliberate.

## Phase 6 — PDF (in progress)

Measured scope, not the estimate in §6: `pdf-inspector` 0.1.7 is **75,119 LOC**
of Rust (of which ~21.7k are the generated `adobe_korea1` and `glyph_names`
tables), plus **`lopdf` 19,473 LOC** for the object layer, plus a `ttf-parser`
subset and **1.6 MB** of bundled binary CMaps. That is more than double
everything built in Phases 0-5 combined, so it is being taken in waves.

- **Wave 1 (started) — object layer.** `Sources/AnyDoc/Pdf/`:
  - `PdfObject.swift`: the object model. Reals are `Float`, matching `lopdf`'s
    `f32`, because the coordinates that reach layout inherit that precision —
    widening would move the boundaries the layout heuristics compare against.
    Dictionaries preserve insertion order (PLAN §2, gotcha 3).
  - `PdfLexer.swift`: the object syntax (§7.2-7.3) ported from `lopdf`'s
    parser — names with `#` escapes, literal strings with nesting/escapes/line
    continuations, hex strings, numbers, arrays, dictionaries, and the `N G R`
    reference form with backtracking. Bracket nesting is capped at 100 as in
    the reference, so a crafted file cannot recurse off the stack. Every entry
    point is total.
  - Verified on the real fixture as well as on spec examples: the trailer
    parses (`/Size 195`, `/Root 193 0 R`), and all **194** indirect object
    headers lex — 194 objects plus the free head is exactly the declared size.
  - `PdfFilters.swift`: the filter chain. FlateDecode reuses the existing
    inflate with zlib framing and the reference's raw-deflate fallback for
    streams whose checksum is wrong; LZW (with `EarlyChange`), ASCII85, and
    the PNG predictors. `ASCIIHexDecode` and `RunLengthDecode` are
    deliberately **absent**: `lopdf` returns "unimplemented" for them, so a
    stream using one is skipped rather than decoded differently from the
    reference.
  - `PdfDocument.swift`: the cross-reference layer — classic tables, PDF 1.5
    cross-reference streams, `/Prev` chains with loop detection, `/XRefStm`
    hybrids, object streams, and reference resolution with a depth cap.
    Streams whose `/Length` is indirect defer resolution until asked.
  - **Verified against `lopdf` itself.** `scratchpad/pdfprobe` is a small Rust
    program built against lopdf 0.41.0 that dumps a PDF's object graph; its
    output for the fixture is committed as
    `Tests/Golden/pdf__text.pdf.objects.golden`, and the Swift reader
    reproduces it exactly — all **194** objects with matching types and
    dictionary keys, and all **22** streams with matching raw and decoded
    byte counts (122,533 bytes decoded). The page tree resolves to the same
    two pages.
  - One upstream bug is **reproduced deliberately**: lopdf's PNG `Average`
    predictor decoder computes `left + above/2` where the specification (and
    lopdf's own encoder) use `(left + above)/2`. Byte parity is the contract,
    so the bug is reproduced and documented at the call site rather than
    corrected, which would silently change output for every stream using
    Predictor 13.
- **Wave 2 — content streams and text extraction.**
  - `PdfContentStream.swift`: the postfix tokenizer. Operands reuse the object
    lexer (content streams have no indirect references, so a bare number is
    always a number); `BI ... ID ... EI` inline images are skipped as binary
    so their payload cannot be lexed as operators; a malformed token is
    skipped and the stream resynchronizes rather than ending, because a
    viewer that stopped at the first bad token would lose the rest of the page.
  - `PdfToUnicode.swift`: `ToUnicode` CMaps — codespace ranges (which fix the
    code width), `bfchar`, and both `bfrange` forms, with surrogate pairs
    combined into one scalar.
  - `PdfTextExtractor.swift`: the text state machine — graphics stack,
    text/line matrices, and the showing operators (`Tj`, `TJ`, `'`, `"`) with
    `Tc`/`Tw`/`Tz`/`TL`/`Ts`/`Tr`. Emits positioned runs.
  - Verified end to end on the fixture: 238 code mappings parsed, **479 runs
    and 951 characters extracted**, containing every heading and phrase the
    committed Markdown golden expects, including the astral U+1D11E clef that
    exercises surrogate pairing.
- **Wave 3 — glyph metrics.** `PdfFontWidths.swift`: simple fonts
  (`/Widths` indexed from `/FirstChar`, with the Type 3 `/FontMatrix` grid
  and the space-width fallback) and composite fonts (the descendant
  CIDFont's `/W` runs over `/DW`). Wired into the extractor, so the text
  matrix now advances by the measured width — an invisible or undecodable
  string still advances, since skipping it would misplace everything after
  it in the text object.
  - Verified by prediction rather than by inspection: **472/472** runs on the
    fixture's first page are measured, and **417/429 (97%)** of forward
    advances land within 2pt of where the next run actually starts. A wrong
    width table would show systematic drift instead.
  - The measurement surfaced a fact layout has to handle: **content order is
    not visual order.** The fixture twice jumps backwards to place a glyph
    from another font (the U+1D11E clef, the family emoji) after later text
    on the same line. That is the problem `reading_order.rs` exists to solve.
- **Wave 4 — layout.** `PdfLayout.swift`: runs grouped into lines by baseline,
  ordered top-to-bottom then left-to-right, joined into text by the gap rules
  (punctuation, hyphens, colons, numeric continuity, sub/superscript, and the
  em-relative thresholds), and grouped into paragraphs by line pitch and
  indent steps.
  - Sorting rather than trusting content order is what places a writer's
    back-jumped glyph correctly, which the fixture requires.
  - Two corrections the fixture forced, both in the extractor:
    a **TJ array is one run, not one per string** — the displacement wide
    enough to be a space *is* the space, and emitting fragments separately
    lost every such boundary; and a displacement at **column scale splits the
    array**, so a run never spans a slot another glyph occupies (the fixture
    leaves exactly such a slot for its U+1D11E clef).
  - A third was in the joiner: runs are trimmed before joining, so an
    explicit trailing or leading space had to be *restored* as a boundary
    rather than read as "a space is already there".
  - Result on the fixture: 41 lines, 10 paragraphs, reading as the golden's
    prose — `Plain paragraph with bold, italic, and struck runs.`,
    `1.First numbered`, `a)Alpha sub one` — with the clef between `clef` and
    `appears`.
  - **Not ported:** multi-column detection, newspaper layout, XY-cut region
    splitting, per-producer letter-spacing calibration. A single-column page
    does not reach them.
- **Wave 5 — headings and Markdown.** `PdfMarkdown.swift`: the body size is
  the most common one weighted by text volume; the distinct sizes at least a
  fifth larger, clustered at half a point and ordered largest first, are the
  heading tiers; a line's size picks its level. Lines without letters cannot
  define a tier, so a large folio does not claim H1. Blocks render as
  Markdown.
  - **The pipeline now emits Markdown end to end.** Against
    `Tests/Golden/pdf__text.pdf.golden`, all **7 headings match at the right
    levels** (`# Fixture Document`, `## Lists`, `## Table`, `## Notes and
    special text`, `## Links and anchors`, `## Objects`, `## Quote and code`)
    and the prose matches.
  - **What still differs, and why** — each is an unported wave, not a defect:
    - **List items.** The golden keeps them on separate lines; paragraph
      grouping currently merges them, because list detection is not ported.
    - **Superscripts and links.** Footnote markers (`footnote¹`) and the
      `<u>…</u>` link markup need the note and annotation handling.
- **Wave 6 — emphasis.** `PdfFontStyle.swift`: PDF has no bold or italic
  attribute, so recovering emphasis means asking what the *font* is. Two
  sources, neither reliable alone: the `BaseFont` name (which subset
  generators reduce to opaque tags like `Tc1`) and the `FontDescriptor`
  (`ItalicAngle` past a few degrees, Flags bit 7 Italic, bit 19 ForceBold).
  Either is enough. Markers open and close as the style changes, with the
  separating space kept outside them, and headings stay unmarked.
  - The golden's first paragraph now matches exactly:
    `Plain paragraph with **bold**, *italic*, and struck runs.`

- **Wave 7 — lists, captions and code.** `PdfClassify.swift` ports
  `markdown/classify.rs` (captions, bullet markers, list items, list
  formatting, code, monospace font names) plus `has_dot_leaders` and
  `compute_paragraph_threshold` from `markdown/analysis.rs`. `pdfBuildBlocks`
  was rewritten from a two-pass gather into the reference's own streaming
  order — paragraph break, caption, heading, list item, list continuation,
  code, prose — and `PdfBlock` gained `.caption`, `.list` and `.code`.
  - Heading detection now carries the gates that make lists work: a line is
    not promoted when it is code, a wrapped list continuation, three bytes or
    fewer, over fifteen words, or starts with a bullet.
  - `pdfGroupIntoParagraphs` was **deleted**. It was a wave-4 approximation —
    median pitch plus an indent test — and the reference has no such
    function: it breaks inline on `y_gap.abs() > para_threshold`. Keeping
    both would have left two disagreeing paragraph rules.
  - Deliberately not ported yet: the struct-tree roles (`Caption`, `LI`,
    `BlockQuote`, `Code`) that can override the visual guess, band-split
    column detection, and the wrapped-bold-run paragraph logic.

### The classifier probe, and the grapheme trap

`scripts/gen-classify-probe.py` extracts `classify.rs`, `has_dot_leaders` and
`text_utils.rs`'s `is_bold_font`/`is_italic_font` **verbatim** into a Rust
binary, generates ~22k probe strings, and writes the oracle's answers.
`PdfClassifyProbeTests` compares all nine predicates when
`ANYDOC_CLASSIFY_PROBE` points at the output; it skips otherwise. Both the
corpus and the answers are deterministic across regeneration.

```bash
python3 scripts/gen-classify-probe.py /tmp/probe
ANYDOC_CLASSIFY_PROBE=/tmp/probe swift test --filter PdfClassifyProbe
```

Hand-written unit tests covering the reference's own assertions passed 17/17
on the first run. The probe then found **three real divergences**, all the
same root cause and none reachable from the fixture:

> **Swift `String` compares grapheme clusters where Rust `str` compares
> bytes.** `•` followed by U+0301 is one Swift `Character` and two Rust
> `char`s. So `hasPrefix`, `contains`, `first`, `hasSuffix` and iteration all
> silently disagree with the reference on any text carrying combining marks.

- `pdfFormatListItem` did not strip a bullet the reference strips.
- `pdfIsMonospaceFont` missed `courier` inside `Courier` + U+0308 — and used
  ASCII lowercasing where the reference uses full `to_lowercase`.
- `pdfHasDotLeaders` missed `....` when the fourth dot carried a mark.

Everything that matches a prefix, suffix or substring against a reference
literal now goes through `scalarsHavePrefix` / `scalarsContain` /
`droppingScalars`. The same fix was applied to `PdfFontStyle`'s name
heuristics, which had the identical defect, and those two predicates were
added to the probe. **This is a general hazard for the whole port, not a PDF
one** — see §2's gotcha list.

The probe's *harness* had the bug too: splitting rows on `Character` `|` and
unescaping on `Character` `\` mangled 600 rows, which read as "malformed"
rather than as failures. Worth remembering that a differential harness can
hide divergences as noise.

**Open, unverified:** three `asciiLowercased()` call sites outside PDF —
[OdfTable.swift:388](Sources/AnyDoc/Formats/Odf/OdfTable.swift:388),
[DocxStyles.swift:89](Sources/AnyDoc/Formats/Docx/DocxStyles.swift:89),
[BlockStyle.swift:16](Sources/AnyDoc/Shared/BlockStyle.swift:16) — may share
the defect if their reference sites use `to_lowercase()` rather than
`to_ascii_lowercase()`. The `anydoc` crate is not vendored locally, so this
needs a re-clone to settle. Not changed on speculation.

- **Wave 8 — links and cleanup.** Two things that had no home yet.
  - `PdfLinks.swift` ports `extractor/links.rs`: `/Link` annotations (rect +
    `/A` → `/URI`), and the AcroForm field tree (qualified names, inherited
    `/FT`, `Tx`/`Ch`/`Btn` values, `Off` and `Sig` skipped). Neither is in the
    content stream, so nothing else in the port could reach them. Also adds
    `pdfPageObjectIds`/`pdfPageNumbers`, the first page-tree walk in the
    library — the field extractor needs page *numbers*, and until now page
    enumeration only existed as a test helper.
    - A link's rectangle is passed through unnormalised (a reversed one gives
      negative extents); a field's **is** normalised. That asymmetry is the
      reference's and is now pinned by test.
  - `PdfPostprocess.swift` ports `markdown/postprocess.rs`: doubled-space
    collapse, spaces before `]` and before sentence punctuation, spaced-hyphen
    repair, standalone page-number removal, bare-URL linking, blank-line
    collapse, and the final trim. `pdfRenderMarkdown` now runs it, as the
    reference runs `clean_markdown` over the whole document.
    - The reference's three regexes are hand-written to keep the port
      dependency-free, each annotated with the pattern it stands in for.
  - Deliberately not ported: the compact profile's dot-leader collapse is
    implemented but off by default, matching the reference; named-destination
    resolution is absent there too.

### The cleanup probe

`scripts/gen-classify-probe.py` gained a second binary extracting
`postprocess.rs` verbatim, and `PdfPostprocessProbeTests` compares eight
passes over ~8.8k generated strings. It found **130 divergences on the first
run**, in five of the eight passes. Two causes:

- **The same grapheme trap as wave 7**, in `collapse_consecutive_spaces`,
  `remove_spaces_before_closing_brackets`,
  `remove_spaces_before_sentence_punctuation`, `collapse_dot_leaders` and
  `fix_hyphenation`. `"]" + U+0301` is one Swift `Character`, so `== "]"`
  failed; `".... " + U+0301` hid the fourth dot; two spaces followed by a
  combining mark collapsed to one in Rust and neither in Swift. All five now
  iterate `unicodeScalars`.
- **Two reference behaviours the port had guessed at.**
  `collapse_consecutive_spaces` guards its separator on `!result.is_empty()`
  rather than on the loop index, so **leading blank lines are silently
  dropped** — `"\nabc"` → `"abc"`, `"\n\n\n"` → `""` — while interior ones
  survive. And `format_urls` counts brackets in `text[..start]`, which
  includes brackets *inside* URLs matched earlier; counting emitted output
  instead gave different link decisions.

Both are now reproduced and pinned by test. The wave-7 lesson generalised:
every pass that walks a string against reference literals is a candidate,
and the probe is the only thing that finds them.

- **Wave 9 — graphics paths.** `PdfGraphics.swift` ports the path operators
  of `extractor/content_stream.rs`: `re`, `m`/`l`/`h`, the painting operators
  `S`/`s`/`B`/`B*`/`b`/`b*`/`f`/`F`/`f*`, the clip operators `W`/`W*`, the
  discard `n`, and `w`/`q`/`Q`/`cm` for stroke width and the transform.
  Nothing in the port had touched graphics before; a PDF draws rules, cell
  borders and underlines as paths, and both remaining big pieces — underline
  detection and table detection — read them.
  - Five outputs, kept separate because downstream wants different subsets:
    every `re`, the `re`s a painting operator confirmed, rectangles recovered
    from filled subpaths, rectangles used only as clip paths, and stroked
    line segments with their transformed widths. A `re W n` draws no ink and
    must never be read as a rule.
  - `pdfSelectedRectangles` reproduces the reference's choice of which list
    to publish — `re` outright, else fills when they outnumber clips
    threefold, else four-or-more clips, else whatever is left — together with
    `pdfDedupRectangles`, which sorts as it deduplicates, so the survivors
    come back in coordinate rather than document order.
  - Stroke width transforms through the path's *normal*, so an anisotropic
    CTM widens a horizontal rule and a vertical one differently.
  - Not ported: rotated-page correction (`correct_rotated_page`), curves
    (`c`/`v`/`y`), and the image-XObject rectangles.

### The graphics oracle

The path walker sits inside a 1,300-line crate-private function with no route
to it from the published API. `scripts/gen-graphics-oracle.sh` therefore
vendors pdf-inspector 0.1.7 from the cargo registry, adds **one** additive
`probe_graphics` function that only calls existing code, trims the manifest so
it resolves offline, and builds a dumping binary. Nothing in the reference's
own logic is edited. The script reproduces the build from scratch and its
output is byte-identical to the hand-built one.

```bash
scripts/gen-graphics-oracle.sh /tmp/oracle
```

The reference does not publish its four rectangle lists separately — it hands
out one `rects` whose provenance depends on what the page drew. The corpus
therefore carries three new files, one per branch: `graphics-rects` (explicit
`re`, painted and clip-only, plus strokes and a scaling `cm`),
`graphics-fills` (no `re`, so filled subpaths surface, including a
non-rectangular quadrilateral that must be rejected), and `graphics-clips`
(no `re` and no fills, so four clip rectangles surface). `lines` is compared
directly. `paintedRectangles` is not reachable through the oracle — the
reference keeps it for underline detection — so unit tests pin it instead,
and this is stated rather than glossed.

The probe was checked for teeth by mutating an oracle dump: it reported
exactly the one injected divergence.

**A reference quirk the corpus exposed:** `h` moves the closed subpath aside
and clears the pending list, so the `S` that follows drains nothing — **a
closed stroked subpath emits no lines at all**. Confirmed against the
reference and reproduced, with a test saying so.

- **Wave 10 — underlines and strikeouts.** `PdfUnderline.swift` ports
  `extractor/underline.rs`. PDF has no underline flag: an underline is a
  separate path drawn near a baseline, so it is recovered by correlating the
  page's graphics with its text.
  - Most of the file is not the correlation, which is simple, but telling an
    underline from a table ruling. Five overlapping heuristics, ported as
    written because the thresholds are empirical: repeated same-span rules
    down the page, snug ownership by one text line (which *rescues* documents
    that underline many full-width lines), segmented per-column row rules,
    flanking verticals and grid-evidence boxes, tabular rules spanning
    column-sized gaps, and maths fraction bars.
  - Reads only ink the page actually laid down — confirmed `re` rectangles
    plus filled subpaths, never clip-only rectangles. This closes wave 9's
    `paintedRectangles` coverage gap end to end.
  - `PdfLayoutItem` gains `isUnderline`/`isStrikeout`. Rendering them as
    `<u>` runs is *not* done yet: that belongs with the emphasis writer.

The oracle grew a `--underline` mode dumping the flags the reference marked,
and the corpus grew four files, one per branch: `underline-basic`,
`underline-table`, `underline-segmented`, `underline-fraction`.

### Three text-extraction divergences the underline probe surfaced

None is about underlines; all three predate this wave and were invisible
until an oracle compared item lists.

1. **Invisible text was being emitted — fixed.** The reference's Markdown path
   passes `include_invisible: false`, so text in rendering mode 3 is skipped
   while the text matrix still advances. This port emitted it, which would
   duplicate every word of a scanned page carrying an OCR layer.
   `pdfExtractTextRuns` now takes `includeInvisible` (default `false`).
2. **The `"` operator's text is dropped upstream — reproduced.** The
   reference's content-stream walker has arms for `Tj`, `TJ` and `'` but
   **none for `"`**, so `aw ac string "` applies both spacings and the line
   move and then silently discards the glyphs. An upstream bug; output has to
   match, so this port now drops the string too and says why at the call site.
3. **A `bfrange` with a multi-unit destination — settled in wave 11.**
   See below.

**Also noticed:** the reference has no `Tz` arm either. Settled in wave 11.

- **Wave 11 — inline decoration, and closing out the open divergences.**
  - `pdfLineTextWithEmphasis` was rewritten against the reference's
    `text_with_formatting`. Two changes of substance. Underline is
    **exclusive**: `<u>` content stays free of `**` and `*`, because
    consumers match tag content literally and mixed `<u>**x**</u>` nesting
    breaks that. And each style now opens and closes **independently** —
    the old code closed both markers whenever either changed, turning a bold
    run followed by a bold-italic run into `**a*****b***` instead of
    `**a*b***`. The fixture never exercised that transition, so nothing
    caught it until the reference was read line by line.
  - Bold and italic moved onto `PdfLayoutItem` alongside underline, since
    underline is not a font property and the writer has to weigh all three
    together. `pdfApplyFontStyles` stamps them from the font tables.
  - Strikeout is detected and, as in the reference, never rendered.

### The three divergences, all now settled by measurement

- **`bfrange` with a multi-scalar base — reproduced.** The reference converts
  the base of a `<lo> <hi> <base>` range with a scalar-only helper that
  returns nothing when the destination decodes to more than one character, so
  `<0004> <0004> <00660066>` drops **the whole range** rather than mapping to
  `ff`. A surrogate pair is still one scalar and survives. `cid-font.pdf` is
  no longer excluded from any probe.
- **`"` is entirely unimplemented — reproduced properly.** Wave 10 stopped
  showing the string but still applied the operator's two spacings and the
  line move. The reference has no arm for `"` at all, so *nothing* happens:
  measured, text after a `"` carries none of its spacings. `"` is now a
  complete no-op.
- **`Tz` is entirely unimplemented — reproduced.** Measured rather than
  assumed: under `50 Tz` the reference reports a nine-glyph run as 54pt, not
  27pt. Horizontal scaling now reaches no advance, and the dead
  `horizontalScale` state was removed rather than left as a variable that
  can only ever be 100.

Both operator findings are upstream bugs — the glyphs are on the page, and
condensed text really is narrower — reproduced because output has to match,
and marked as such at the call site. The probe's item dump now carries run
**width**, which is what turned the `Tz` and `"` questions from arguments
into measurements.

- **Wave 12 — fragment merging.** `PdfMergeItems.swift` ports
  `merge_text_items` and `merge_subscript_items` with their helpers. A PDF
  does not draw words: it draws a glyph at a time when the text is
  letterspaced, a fragment per kerning pair, a separate run at every style
  change. Reassembling that is its own pass, and it has to guess where the
  spaces were, because a space is usually not in the file — it is a gap.
  - Thresholds are the reference's: half an em ends a run, a fifth of the
    font size is the size band, and the space threshold is 0.08em, widened to
    0.13em for a lowercase pair (probably mid-word) and 0.25em before joining
    punctuation (never spaced). Style boundaries always break, since the
    merged fragment carries the first one's flags.
  - `pdfTrackedRunSpaceFloor` handles display tracking: a run of single
    all-caps glyphs gets its own gap floor, or `TRACK` comes back as five
    words. Lowercase singles deliberately keep their spaces — geometry alone
    cannot tell `x y z` from a tracked title-case word.
  - `pdfMergeSubscriptItems` absorbs numeric scripts into the word beside
    them, mapping them to Unicode raised/lowered digits so `H`+`2`+`O`
    becomes `H₂` and `O`, and `note`+`3` becomes `note³`. Direction comes
    from the baseline offset. Only digits are absorbed, and only into a
    parent ending in a letter.
  - **Not ported**, each stated in the source: right-to-left runs, which the
    reference sorts descending by x; and the marked-content overlay order for
    `ActualText` fragments, which cannot fire here at all because this port
    does not read MCIDs — the reference's own test returns false without them.

Two corpus files drive this: `merge-fragments` (a word split across four
`Tj`, a letterspaced all-caps run, a chemical subscript, a footnote
superscript, and a pair too far apart to join) and `merge-thresholds` (one
line per branch of the space decision). The reference's answers discriminate
every branch — `abcd` versus `AB cd`, `word.`, `near far` — and this port
agrees on all of them.

The underline probe now applies the reference's full order: extract, mark
decoration, merge fragments, absorb scripts. That makes it a check on the
whole text pipeline rather than on decoration alone.

- **Wave 13 — table grid geometry.** The first slice of table detection.
  `PdfTableGrid.swift` ports `tables/grid.rs`: column and row boundaries,
  cell assignment, and cell-fragment joining. All four detection strategies
  stand on these, so they come first.
  - Columns are the hard part, because the right clustering threshold depends
    on the table. The reference reads the *distribution* of consecutive gaps
    and takes one of three branches: the default average-gap threshold
    clamped to 25–50pt; a lowered threshold when a strong bimodal signal
    appears with few items; and edge-based rather than mean-based clustering
    for genuinely dense tables (500+ items), where clustering around the mean
    drifts and merges adjacent narrow columns. All three are ported.
  - `merge_numeric_adjacent_clusters` pulls a wrapped header back onto the
    numeric column beneath it. The body-font pass rejects a candidate where
    one column holds more than three fifths of the items — that is a
    paragraph, not a table.
  - `pdfJoinCellItems` binds hyphens, brackets and sub/superscripts to their
    token rather than spacing them.
  - **Not ported yet:** `recover_header_row`, which needs the `Table` type
    this wave does not introduce.

### The grid probe

`grid.rs` is crate-private too, so `scripts/gen-graphics-oracle.sh` gained a
`--grid` mode with a second additive `probe_grid` function, reading
`x y width font_size text` blocks and reporting the columns, rows, per-item
cell and joined text the reference derives.
`scripts/gen-grid-probe.py` generates cases aimed at each branch — a plain
table, columns tighter than the 25pt floor, a strong bimodal signal, a
wrapped header over a numeric column, prose at the left margin, a 576-item
dense table that trips the edge-clustering branch, and joining shapes — plus
a random tail.

```bash
scripts/gen-graphics-oracle.sh /tmp/oracle
python3 scripts/gen-grid-probe.py /tmp/probe --oracle /tmp/oracle
ANYDOC_GRID_PROBE=/tmp/probe swift test --filter PdfGridProbe
```

**2,509 cases agree.** Unlike the classifier and cleanup probes, this one
found nothing — the geometry is arithmetic over floats rather than string
walking, which is where this port's divergences have all lived.

- **Wave 14 — the table model and its rendering.** `PdfTable.swift` ports
  the `Table` type from `tables/mod.rs` and all of `tables/format.rs`.
  - Rendering a grid of strings is the easy half. The other half is that the
    grid does not arrive clean: `pdfCleanTableCells` merges rows that are a
    wrapped cell's overflow, lifts footnote rows out below the table, and
    drops empty rows. A row with an empty first column is *usually* overflow
    — but it is also how a spanned first column, a short sub-header and a
    hierarchical sub-entry look, and each has its own test to keep it intact.
  - A contents listing renders as flat lines with the page number on a tab,
    so it stays beside its title instead of drifting into a column. Page
    numbers include canonical roman numerals — canonical, so `iiii` is
    rejected where `iv` is accepted — and the dashed section-page forms
    (`5-21`, `A-1`, `TC-2`) technical manuals use.
  - The data form is deliberately compact, no padding, because the
    reference's primary consumer is a model rather than a reader.
  - `kind` was left as an input here and is **derived as of wave 15**.

The oracle gained a `--format` mode and `gen-grid-probe.py` a second case
set: continuation rows, each of the four shapes that look like one but must
not merge, the three footnote forms, and the contents shapes, plus a random
tail over the fragments those tests key on. **2,513 cases agree.**

- **Wave 15 — the contents classifier.** `PdfTableOfContents.swift` ports the
  classifier cluster from `tables/detect_heuristic.rs`, closing the gap wave
  14 stated: `PdfTable` now classifies itself on construction, as the
  reference's `Table::new` does.
  - Three independent signals, any one enough. An explicit **dot leader**,
    either as a dedicated dots-only cell or glued to the title — the latter
    needing a space and a word before the run, so `etc...` and a `1973 ... `
    data label do not qualify. A **dotted section number** with page numbers
    in the last column. Or, hardest, a **title column beside ascending page
    numbers** with no leader at all.
  - That last one has to be told from a two-column numeric data table, and
    the reference's tells are worth naming: contents have no header row, so
    the *first* row's last cell is already a page number; the first column is
    mostly prose; the numbers mostly ascend; and — strongest — real page
    numbers **span** the document, because entries skip. A perfectly dense
    consecutive run is a rank column, accepted only when the titles average
    at least 1.8 words, which separates contents from a leaderboard.
  - A wide index whose cells each hold a whole `label ... page` fragment is
    flagged separately: it renders badly as a table *and* as a list, so the
    reference lets it fall back to the page's ordinary text flow.

**A coverage hole the probe nearly hid.** The first run compared 2,513 cases
green — but the verdict distribution was only two values, all-false and
dot-leader. `is_page_number_toc` and `is_tabular_toc` never fired once, so
two of the four columns were being compared vacuously. The generator now
emits contents shapes that trip each branch, plus randomised listings around
the accept/reject edges; the distribution has five values and **3,145 cases
agree**. Checking *what a probe actually exercised* is now part of the drill,
not just whether it passed.

- **Wave 16 — heuristic table detection.** `PdfTableDetect.swift` ports
  `detect_table_in_region` and its validators. This is the strategy for a
  table with no ruling at all, where the only evidence is that the text lines
  up — weak evidence, so the reference spends far more code rejecting than
  accepting: eight validations, each a different way a page of prose can look
  like a table from a distance (a key-value list, a false grid with words
  hyphenated at the column boundary, letterspaced display text, long sentence
  fragments, inconsistent fill, an inline-leader index).

**Two things the probe caught that reading alone had not.**

1. **`find_first_table_row` is not optional.** It was deferred as
   "form-header trimming", and the first probe run diverged on hundreds of
   cases with a systematic signature: every row count one too high, every
   cell shifted down one. It fires on most regions, not just forms — spanning
   super-headers whose cells repeat, and sparse preamble, are trimmed by it
   too. Now ported.
2. **The trim reads differently-joined cells than the output does.** The
   reference calls `find_first_table_row` *before* it sorts each cell's items
   by x, so the trim decision sees cells joined in arrival order and the
   final table sees them joined left to right. Passing the sorted cells to
   both trimmed a different row. Two cases in 1,512 diverged on this, which
   is exactly the sort of thing no amount of re-reading finds.

The oracle gained a `--detect` mode. The detector runs over the grid probe's
positional cases — they already cover the clustering branches — plus a
key-value list, hyphen-broken prose and letterspaced text that must be
rejected. Both accept and reject verdicts fire in both modes, and **2,512
cases agree**.

- **Wave 17 — the table path's fragment merger.** `pdfMergeAdjacentItems`
  ports `merge_adjacent_items`, the pre-pass `detect_tables` runs before it
  looks for regions. It is a near-cousin of wave 12's `pdfMergeTextItems` and
  deliberately *not* the same function: raw widths rather than the
  word-spacing-capped ones, one fixed space threshold instead of the
  punctuation and lowercase-pair cases, no tracked-run floor, and — the
  telling difference — **no break at style boundaries**, because a cell's
  styling is nothing to the grid. It also returns an index map, so a detected
  table can still say which original items it consumed.

Folded into the detector probe: 3,295 genuine multi-item merges across the
2,512 cases, all agreeing. (Counting the multi-source merges rather than just
reading "2,512 passed" is the wave-15 lesson applied.)

## Phase 6 status

Working end to end: bytes → objects → xref → filters → content operations →
ToUnicode-decoded text → exact positions and widths → lines, words,
paragraphs → captions, headings, lists and code → Markdown. The document's
structure, prose, emphasis, underlines, lists and cleanup come out right,
and links and form fields are recovered; its *tables* are not.

Graphics paths are now extracted, which unblocks the two largest remaining
pieces. Remaining, roughly by size: the four table *detection* strategies (14.4k LOC
of the 16.3k, now that the grid and the formatter are in — `detect_rects`
4.7k, `detect_lines` 2.8k, the rest of `detect_heuristic` (region finding
and the `detect_tables` orchestrator), `detect_struct` 1.2k), the
base14/TrueType/glyph-name encodings for fonts without a
`ToUnicode` CMap, multi-column layout, and encryption. Link items are
extracted but not yet *merged into the text* they sit over — that needs the
layout to consume positioned annotations alongside text runs.

The one PDF fixture is a classic-xref PDF 1.7 using only FlateDecode, with 7
embedded TrueType fonts carrying `ToUnicode` CMaps and a `StructTreeRoot` —
a narrow slice, which is why the generated corpus below exists.

### Generated adversarial corpus

`scripts/gen-pdf-corpus.py` writes 30 PDFs byte by byte, each aimed at a path
the fixture cannot reach. It is deterministic: regenerating produces
identical bytes, so the oracle dumps stay valid.

| Group | Files |
| --- | --- |
| Cross-reference | `classic-xref`, `xref-stream`, `xref-stream-predictor`, `xref-stream-narrow-w`, `object-stream`, `incremental-update` |
| Filters | `filter-lzw`, `filter-ascii85`, `filter-chained`, `filter-none` |
| Streams | `indirect-length`, `lying-length` |
| Fonts and content | `cid-font`, `content-shapes`, `content-array`, `two-column` |
| Malformed | `bad-xref-offsets`, `truncated`, `no-startxref`, `garbage-header` |
| Annotations | `annotations` (links, reversed rect, AcroForm field tree) |
| Graphics | `graphics-rects`, `graphics-fills`, `graphics-clips` |
| Underlines | `underline-basic`, `underline-table`, `underline-segmented`, `underline-fraction` |
| Merging | `merge-fragments`, `merge-thresholds` |

`Tests/AnyDocTests/PdfCorpusTests.swift` runs against it when
`ANYDOC_PDF_CORPUS` points at the generated directory, and skips otherwise —
the corpus is a build product, not a committed artifact. Two assertions: the
object graph must match a dump from the `pdfprobe` lopdf oracle, and every
file must reach the end of the pipeline without crashing or hanging. Current
result: **27 graphs compared identical, 3 rejections agreed** (lopdf and this
port reject the same three malformed files), **26 rendered to Markdown**.

The corpus found one real divergence, now fixed. A stream whose direct
`/Length` overruns the file was being recovered by scanning forward for
`endstream`; lopdf's `take(length)` simply fails there and yields the
dictionary alone, so scanning resurrected content the reference drops.
Recovery by scanning is now reserved for a stream with *no* `/Length` at all
(`PdfDocument.swift`, `readIndirectObject`).

One apparent divergence is an oracle artifact rather than a reader bug: lopdf
decompresses an object stream *in place* while loading it, so the probe
reports its raw length as the decoded one. The decoded lengths agree;
`normalizeOracleArtifacts` compares such streams on the decoded length alone.

**The real-document corpus gap remains.** Generated files exercise the code
paths but not the malformations real producers emit, and encryption is
neither generated nor implemented. Phase 6 still cannot claim parity without
§5.3's external corpus, and the differential harness is a local/manual step.
