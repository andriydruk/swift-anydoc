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

**Clarified 2026-08-13 — what the rule is actually for.** The owner's requirement is
narrower than the lint: *no SPM dependencies, and the library builds on both macOS and
Linux*. `Foundation` and `Dispatch` are permitted if they earn their place. The lint stays
as written anyway, because measuring the cost showed the ban has bought more than it cost:

- Of ~35,600 library lines, Foundation could displace maybe 2,300 — `Xml.swift` (999), the
  legacy encodings (1,298) and `FileBytes.swift` (34). Everything else has no Foundation
  equivalent at all: inflate, ZIP, CFB, HTML, and the PDF stack.
- ~2,270 of those 2,300 are exactly where Foundation would *introduce* divergence. Its
  Unicode, encoding and collation surfaces are ICU-backed — system ICU on macOS (tied to the
  OS version), bundled ICU on corelibs — so the same input can produce different output on
  the two platforms. The correctness bar here is byte-identity with a Rust binary, so that
  turns a deterministic port into a platform- and OS-version-dependent one. Wave 55 is the
  worked example: the NFKC tables had to come from the reference's own crate at Unicode
  17.0.0 precisely because the local `unicodedata` was 13.0.0.
- `RustFloat.swift` and `RustCompat.swift` make the point from the other side. They exist
  *because* Foundation's and Swift's semantics differ from Rust's — `String(format:)` will
  not reproduce Rust's `Display for f64`, and Foundation's locale- and grapheme-aware string
  operations are wrong where the reference is byte-wise. Foundation makes those files
  harder, not unnecessary.
- The Apple-framework bans (`Compression`, `PDFKit`, `CoreGraphics`, `CryptoKit`, …) are
  load-bearing for the Linux half regardless of any Foundation decision. Concretely: PDF
  encryption needs MD5, RC4, AES-128 and SHA-256, and none of those are portably available,
  so they are hand-rolled either way (§ PDF phase).
- `Dispatch` is not wanted separately: Swift Concurrency is available on both platforms with
  no import, so `TaskGroup` covers per-page parallelism if it is ever needed.

**So the lint is a default, not a doctrine.** If a case appears where Foundation is clearly
the better answer *and* its behaviour is platform-independent, raise it and decide — do not
silently hand-roll around it, and do not silently import it either.

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

- **Wave 18 — table region finding.** Both finders from
  `detect_heuristic.rs`, and the pair is instructive because they answer the
  same question from opposite evidence.
  - `pdfFindTableRegions` is pure density: four or more small-font baselines
    with no gap over 30pt. That is enough because being *smaller than the
    body text* is already most of the signal.
  - `pdfFindTableRegionsStrict` gets body-sized candidates, which include all
    the page's prose, so proximity proves nothing. A row qualifies only if
    its x positions form two or more clusters, and a run of qualifying rows
    survives only if every pair of them agrees on where the columns are —
    which is exactly what separates a table from paragraph text, where word
    positions wander line to line.

Folded into the detector probe: 2,226 plain and 1,473 strict regions found
across the 2,512 cases, all agreeing.

**Still not ported, and needed before `detect_tables` can be assembled:**
`expand_consolidated_items`, `recover_header_row` (deferred since wave 13)
and `try_add_label_column`. Wave 16 showed what deferring a core-path helper
costs, so the orchestrator is deliberately left until all three are in rather
than wired up with gaps.

- **Wave 19 — consolidated financial rows.** `PdfTableFinancial.swift` ports
  `tables/financial.rs` and `expand_consolidated_items`, the second of the
  three helpers `detect_tables` still needed.
  - A financial statement often draws a whole row of figures as **one** text
    item, because the producer emitted it with one `Tj`. No amount of column
    clustering can recover a grid from that — there is only one x position —
    so a very wide item holding nothing but figures is split before detection
    runs, its values spread evenly across its own width. That spacing is a
    fiction, since the real figures are right-aligned, but it is a *consistent*
    fiction across a table's rows, which is all the clustering needs.
  - The guess is narrow on purpose: two consecutive letters anywhere
    disqualify the item, as does any token that is not a figure, a dash or a
    `$` bound to the figure after it. Under twenty ems wide, or fewer than
    three values, and it is left alone.

Folded into the detector probe, with financial rows added to the cases: 48
items actually split across 2,014 cases, all agreeing.

Both remaining helpers, and the orchestrator, landed in wave 20.

- **Wave 20 — the heuristic strategy, assembled.** The last two helpers and
  the orchestrator, so `pdfDetectTables` now runs end to end.
  - `pdfRecoverHeaderRow` (deferred since wave 13) fixes a real blind spot: a
    small-font table's header is usually set at the *body* size, which puts it
    outside the candidate set entirely, so the detector never saw it. Once a
    table is found, the band above it — up to twice its own row spacing,
    bounded 10–40pt — is searched for a row of larger text that maps onto the
    columns already established.
  - `pdfTryAddLabelColumn` covers the mirror case: a table of nothing but
    figures usually has names down its left edge, set differently enough that
    the clustering dropped them.
  - `pdfDetectTables` runs two passes in order. The first looks for text
    *smaller* than the body — the classic signal, needing only density to
    find regions. The second looks at body-sized text, where proximity proves
    nothing, so it demands structural evidence and only considers what the
    first pass left unclaimed. Indices are then mapped back through both
    pre-passes to the caller's own items.

The probe now runs the whole orchestrator at three base font sizes with the
body-font pass on and off — six configurations per case. **1,214 cases agree,
2,154 of them finding at least one table.**

Two harness bugs surfaced first and are worth naming, because both would have
read as port bugs: the Swift dump emitted its blocks in a different order than
the Rust one, and formatted the base size to three decimals where the
reference used one. Neither was in the port. When a probe lights up, the
harness is a candidate too.

- **Wave 21 — line-based table rule primitives.** `PdfTableRules.swift`
  ports the horizontal-rule layer of `tables/detect_lines.rs`, plus
  `snap_edges` from `detect_rects.rs`. Many forms and government PDFs draw
  their grids with `m`/`l`/`S` rather than `re`, so the table arrives as a
  scatter of stroked segments; all six table-building strategies in that file
  need those turned into rules first.
  - `pdfMergeHorizontalSegments` joins segments a form drew a cell at a time —
    without it, path endpoints become false column edges. Rows are formed
    against the group's *first* rule, so slowly drifting baselines do not
    chain.
  - `pdfSplitIndependentRuleRuns` separates consecutive booktabs tables that
    share x endpoints, using a numbered caption between them, or failing that
    a large *mostly empty* band. The same band filled with text must not
    split, and both sides must keep two rules.
  - `pdfDeriveColumnsFromHorizontalSegments` recovers columns from endpoints
    that recur down the table; a ragged edge touching under half the rows is
    not a column.

**Two coverage holes caught, not one.** The probe first reported 612 cases
green — with `rules_are_uniform_grid` returning true exactly **once**, and
columns derived in 22 cases. The random generator almost never produces an
evenly spaced run. Added deliberate generators for both, straddling the 2%
deviation bar and the 5pt clustering tolerance: **1,512 cases, 227 uniform
verdicts, 92 column derivations, all agreeing.**

A unit test also corrected the port's own documentation: `snap_edges`
compares each value against the last one **kept**, not its predecessor, so
`[100, 102, 104, 106, 108]` at 3pt keeps `[100, 104, 108]` rather than
collapsing to one edge. The comment claimed otherwise; both are fixed.

**Still unported in `detect_lines.rs`:** the six table-building strategies
(stacked-token, text-anchor, dense-row-anchor, open-edge-grid), the
evidence-scoring hypothesis selector, and vertical-rule handling.

- **Wave 22 — the table-hypothesis selector.** `PdfTableHypothesis.swift`
  ports the scoring and selection cluster from `tables/detect_lines.rs`.
  - A ruled page rarely yields one obvious table. The reference builds several
    readings over the same items and then picks — not by deciding which
    strategy is cleverer, but by scoring how much evidence each result
    accounts for, taking the best, then the best of what does not overlap it.
  - The weights state the priorities plainly: an item consumed is worth 100,
    a filled cell 25, an occupied column 60 and an occupied row 20, with
    empty cells penalised 4 apiece. Columns outweigh rows threefold because
    spanning columns is what distinguishes a table from a list; the empty-cell
    penalty is small enough not to reject a legitimately ragged table, and
    the score saturates at zero so a mostly-empty grid still sorts above a
    reading that found nothing.
  - `pdfSelectTableHypothesis` privileges neither side: with both present
    they are pooled and scored together, so an alternative that explains the
    page better displaces the grid reading outright.

708 cases agree. **The third harness bug of this phase**, and again it read
as a port bug at first: 23 divergences with a line-count offset, because the
cells field is empty whenever a one-cell grid holds the empty string — Rust's
`splitn` keeps that empty field and Swift's `split` drops it unless told
`omittingEmptySubsequences: false`. Worth adding to the drill: **Rust's
`splitn` and Swift's `split` disagree on empty fields by default.**

- **Wave 23 — rectangle clustering.** `PdfRectCluster.swift` ports the
  foundation of `tables/detect_rects.rs`: union-find, `rects_overlap`,
  `cluster_rects` and `split_wide_cluster`. Many PDFs draw a table by stroking
  one `re` per cell — a table page carries a hundred or more rectangles where
  a plain page carries under thirty — but they arrive unordered, so working
  out which belong to the same drawing is a connected-components problem.
  - The tolerance matters because abutting cell borders *touch* rather than
    overlap; both rectangles are grown before the test.
  - The 2,000-rectangle component cap is what keeps a chart-heavy page from
    taking minutes: a rectangle already in an oversized component stops being
    compared. The loop stays quadratic and becomes effectively linear on
    pathological pages.
  - `pdfSplitWideCluster` is the fallback when grid detection fails on a
    whole cluster — two tables side by side cluster together when their
    borders abut, so it cuts at the widest empty column band, but only if
    both halves are substantial.
  - **One deliberate deviation:** `find` is iterative here where the
    reference recurses. A pathological page could otherwise drive the stack
    as deep as the rectangle count, and this port has no `catch_unwind` (§2
    gotcha 2). Behaviour is identical; 708 probe cases confirm it.

708 cases agree, with 1,232 groups formed and 264 splits taken.

**`detect_rects.rs` is complete as of wave 34** — every strategy, the
orchestrator, the hint machinery and the chart regions. What remains of
rectangle tables is downstream: nothing yet *consumes* the hints, because the
heuristic detector they scope has not been wired to them.

- **Wave 24 — grid assignment.** `PdfGridAssign.swift` ports
  `assign_items_to_grid` and `remove_inner_delimiter_spaces`. Both ruled
  strategies end here: once cell borders have yielded column and row *edges*,
  every item is dropped into the cell it falls in and each cell's items joined.
  - Edges bound cells — `n` edges give `n - 1` cells — which is what
    distinguishes this from the heuristic path's `pdfFindColumnIndex`, where
    columns are positions and an item goes to the nearest. Two different
    models of the same idea, and mixing them up would be silent.
  - An item is placed by its horizontal *centre* but its vertical *baseline*,
    not its vertical centre: a cell's row is decided by where the text sits,
    so a tall glyph must not migrate into the row above.
  - `remove_inner_delimiter_spaces` closes a space that landed just inside a
    bracket — joining fragments puts one wherever the producer broke the run,
    and `( 12 )` reads wrong. Only the inner side: `a (b)` keeps its space.

707 cases agree, with 2,171 cells emitted and 589 cases placing at least one
item.

- **Wave 25 — grid building from rectangles.** `PdfRectGrid.swift` ports
  `try_build_grid` and `propagate_merged_cells`. Wave 23 worked out which
  rectangles belong together; this decides whether the cluster is really a
  *grid*. The rectangles' own edges become the boundaries, then a cumulative
  series of mostly-negative tests asks whether the result is a table or a
  form's scattered field boxes.
  - Three verdicts, and the distinction matters: `.failed` is structural and
    final, `.fewNonEmptyRows` means the grid was sound but the text thin —
    often because merged-cell propagation collapsed it upward — so the caller
    can retry. A unit test written expecting `.failed` for a drawn-but-empty
    grid was wrong, and the correction is the clearest statement of what
    separates them.
  - `skipRects` excludes page backgrounds from *column* edges only. They
    still count for rows and cell coverage; without the exclusion they
    contribute page-boundary edges and manufacture empty margin columns.
  - `strict` is the retry mode after backgrounds are dropped: half the rows
    must carry content instead of two, 40% of cells instead of 25%, and any
    cell over 200 bytes means a paragraph was swept in.
  - `propagate_merged_cells` demands **real overlap**, not tolerance slack. A
    rectangle whose top merely meets a row's bottom lies entirely below it,
    and a bounds-with-slack test would call that a span — cascading unrelated
    rows into one merged cell. Pinned by test.

711 cases agree, with all three verdicts firing: 262 ok, 439 failed, 10
`fewNonEmptyRows`.

- **Wave 26 — rect-cluster classifiers.** `PdfRectClassify.swift` ports
  `is_row_stripe_pattern`, `without_dominant_page_backgrounds` and
  `is_chart_bar_cluster` — the tests that say what a cluster *is* before any
  table is built from it.
  - **Row stripes.** Alternating shading gives rectangles that all share an x
    position and width, so grid detection sees two x-edges and concludes there
    is one column. Recognising the pattern is what lets the columns be
    recovered from the text instead. The bands must span more than 200pt and
    three quarters of them agree on width within a tenth.
  - **Page backgrounds** are dropped only when the producer stamps *many* —
    eight or more. One full-page backdrop is harmless; eight means one per
    element, and they would otherwise add page-boundary edges to every grid.
  - **Bar charts** are the subtle one: bars drawn as filled rectangles are
    indistinguishable from cell backgrounds by shape alone, and without this
    a chart's axis labels get gridded into a phantom table. The signature is a
    family of equal-*breadth* rectangles standing in separated columns —
    table cells touch, bars do not — whose *length* varies because it encodes
    data, containing only figures if anything. The whole test runs twice with
    the axes swapped, which is what catches a horizontal chart.
    - Its sharpest test: a table's cell rectangles have same-extent partners
      in other columns, because rows are uniform. Chart segments start where
      the previous datum ended, so they rarely pair up.

**Coverage was thin again and was fixed, not accepted.** The first run
compared 718 cases green with `chart` true 3 times and `stripe` true *once*.
Randomised stripe and bar generators now straddle the thresholds — the 200pt
width, the 10% tolerance, the half-breadth bar gap, the 1.3× length variation:
**1,184 cases, 40 chart and 85 stripe verdicts, all agreeing.**

- **Wave 27 — the row-stripe strategy.** `PdfRowStripeTable.swift` ports
  `detect_row_stripe_table`, `cluster_x_positions`, `has_dominant_prose_cell`
  and `row_stripe_is_sparse_prose_outline`. Alternating shading defeats grid
  detection outright — every stripe shares an x position and width, so the
  edges give one column — but the stripes carry perfectly good *row*
  boundaries. Rows come from the rectangles, columns from where the text
  starts.
  - That makes it the loosest rect strategy, since geometry supplies only half
    the grid, so most of the code is what follows: 40% content density (higher
    than grid building's 25%), a cell-length cap that scales with width, empty
    outer columns trimmed and empty interior columns fatal.
  - `cluster_x_positions` counts only where text *starts*, and skips a run
    that hugs the previous one — a style boundary, a script change, an
    underline split — because feeding its start position in fabricates a
    phantom column mid-cell. The negative bound matters too: text overhanging
    from the next cell overlaps far more than italic kerning ever does and
    must still open its own column.
  - Two prose guards, both worth reading as statements of intent. A single
    cell holding 60 words *and* a third of the table's total is a chart's
    rectangles having swallowed the page — with deliberately **no** small-table
    exemption, because the costs are asymmetric: rejecting a real table
    degrades it to readable prose, accepting a phantom scrambles the page into
    interleaved cells. And a sparse label column beside a dense column of
    sentences is a heading sidebar over body text, not a table.

1,184 cases agree, with 79 stripe tables accepted and 1,105 rejected.

- **Wave 28 — the stacked-box strategy.** `PdfStackedBoxTable.swift` ports
  `detect_stacked_box_table`. Some documents present a list as framed rows
  stacked down the page: no columns at all, so no grid strategy applies, but
  the boxes are real structure.
  - Roughly a fifth of the code finds the stack; the rest argues about whether
    it is a table, because a stack of boxes is also what callout panels,
    sidebar frames and striped backgrounds behind prose look like. Five
    separate ways of recognising prose in a table's geometry: function-word
    density with a 60-character mean, sentences wrapping across boxes (a row
    ending in a comma, or an unterminated row followed by a lowercase one),
    numbered list markers, two text runs on one baseline, and boxes flanked
    by anything at the same height.
  - The flanking test is the interesting one: a box with a sibling beside it
    is one column of something wider, and belongs to the grid strategies —
    collapsing it here would lose the other columns silently.

1,424 cases agree. **Coverage was thin and was improved, though it remains
asymmetric**: 2 accepts in the first run, 10 after adding randomised framed
stacks. That is a small positive sample, and worth stating plainly — the
function is dominated by its rejection paths, which are well covered, but the
accepting path rests on ten generated cases plus the unit tests.

**A fourth harness ordering bug**, same class as wave 20's: the Swift dump
emitted its blocks in a different order than the Rust probe. Caught in the
first run, fixed in the harness, not the port.

- **Wave 29 — the merged-cluster strategy.** `PdfMergedClusterTable.swift`
  ports `detect_merged_cluster_table`, the last resort: it runs once the
  clusters have been merged back together and none formed a grid on its own.
  Rows come from every rectangle's y-edges, columns from where the text
  starts — the same halves-from-different-places approach as the row-stripe
  path, but without requiring the stripe shape first.
  - Being the loosest strategy, it carries the strictest gates. The sharpest
    is that **an empty column anywhere is fatal**, where grid building merely
    trims empty *outer* columns. The reason is structural: nothing backs the
    column positions but the text clustering itself, so an empty column means
    the clustering was wrong rather than that the table has a blank margin.
  - Density must clear 40% against grid building's 25%, for the same reason.

1,424 cases agree on the first run, ordering included — with genuinely broad
coverage this time: **531 accepts spanning 2 to 6 columns, 893 rejects.**

- **Wave 30 — rect preprocessing and the direct chain.**
  `PdfRectPipeline.swift` ports the filtering inline at the top of
  `detect_tables_from_rects`, plus `detect_table_from_rect_group` and
  `detect_direct_rect_table`.
  - Preprocessing normalises flipped extents, drops decoration under 5pt,
    removes page-spanning fills, and deduplicates cell-internal shading.
    Each exists because leaving it in corrupts the grid: a fill adds spurious
    column edges, shading inside a cell splits one visual row into two.
  - The oversized filter keys on median **width**, not area, and the choice
    matters: a row-stripe table has every rectangle at full width, so its
    median *is* the table width and nothing is dropped. A unit test written
    expecting a 600pt fill to be dropped was wrong — nine 60pt cells give a
    threshold of exactly 600 and the comparison is `<=`, so it survives. The
    boundary is now pinned from both sides.
  - `pdfDetectTableFromRectGroup` is where `fewNonEmptyRows` earns its
    keep: a full-page background makes merged-cell propagation collapse every
    row's text into the first, and that verdict is what triggers the retry
    with those rectangles excluded from the column edges. Gated on twelve
    y-edges, because the stricter retry manufactures false positives on small
    grids.
  - `pdfDetectDirectRectTable` tries grid, then stripes, then stacked boxes —
    the order of decreasing geometric evidence.

1,428 cases agree on both new probes on the first run. Preprocessing coverage
was 31 cases in 1,228 and is now **160 in 1,428**, after adding randomised
flipped, tiny, oversized and nested shapes; the direct chain accepts 306 times
across 1 to 5 columns.

- **Wave 31 — the two row-shaping ends of the cell-rect strategy.**
  `PdfCellRectRows.swift` ports the row-edge derivation at the head of
  `detect_row_stripe_table_from_cell_rects` and
  `collapse_multiline_description_rows`, which reshapes its rows afterwards.

  The strategy itself is 473 lines and needs `collapse_…` to exist before it
  can be assembled at all, so it is being landed across two waves. These two
  stages bracket it, each is a pure function with a verifiable interface, and
  **nothing calls the strategy until the middle lands** — this is not the wave
  16 mistake, where a piece already on the core path was deferred silently.
  - Rows normally come straight from the rectangles' y-edges. When those snap
    down to fewer than four — variable-height cell backgrounds, decoration
    fills — the rows are read off the text instead, clustering baselines at
    four fifths of the median glyph height and turning each cluster *centre*
    into a one-glyph-tall band. The fallback scopes its region with y bounds
    taken from the snapped edges but x bounds taken from the rectangles;
    mixed sources, reproduced as written.
  - `collapse_…` repairs exports that emit one y band per wrapped *line*
    rather than per row. It acts only on a narrow shape — label column, one
    much wider description column, continuation bands populated in that
    column alone — so framed prose still reaches the strategy's prose guards
    instead of being tidied into a table.
  - Two upstream quirks reproduced: `max_by` keeps the *last* maximum, so a
    table of equal-width columns nominates its rightmost as the description;
    and the bail-out returns the *reshaped* cells with the *original* edges,
    which disagree in length when merging leaves fewer than two rows. Both
    are pinned by unit tests, the second harmlessly — the caller's own
    two-row gate rejects that table immediately after.

1,430 row-edge cases and 303 collapse cases agree on the first run. Collapse
coverage needed a purpose-built generator, since random grids never reach the
merging loop: 49 of the 303 cases now merge at least one row, and header
continuations fire distinctly from description ones (8 cases drop four rows
while only 5 report four *wrapped* rows).

- **Wave 32 — the cell-rect stripe strategy itself.**
  `PdfCellRectTable.swift` ports the middle of
  `detect_row_stripe_table_from_cell_rects`, closing the function wave 31
  opened. This is the last resort among the rectangle strategies and the one
  most exposed to false positives: it runs when a cluster has enough drawn
  cells to look like a table but too little regular geometry for the grid
  builder, so rows *and* columns may both have to be inferred. Most of its
  length is therefore gates.
  - Columns come from text-start clustering or from the rectangles' own
    x-edges, and the choice between them is four-armed. Rect edges win
    outright when every rect column holds two or more items — the case that
    matters is a centred header over left-aligned data, where text clustering
    drops the header-only cluster and silently loses a column. When the rect
    columns are *not* well populated the rectangles are decoration, and
    preferring them would split one logical column into several.
  - The prose test is the subtle part: a page frame full of wrapped text
    produces the same surface signal as a real label/value table. Once a fifth
    of the cells hold an English function word, three layered checks apply —
    mean cell length over 65 characters, a two-column scaffold inferred from
    text alone, and columns that are not well distributed. Only the first is
    excused by collapsed rows, since those explain the length honestly.
  - `len()` is bytes in the reference, so the 500-byte paragraph gate sits
    lower for non-ASCII text; ported as `utf8.count`, not character count.

1,476 cases agree on the first run, with 629 accepts. **Coverage was checked by
instrumenting each gate and counting**, not by reading the pass: the first pass
had `v00`-style filler text containing no English function words at all, so the
whole prose block — the largest and most delicate part of the function — never
executed. After adding prose cases the three prose branches fire 47, 40 and 4
times, and targeted shapes were needed again for the paragraph-length and
disproportionate-grid gates, which fire once each. Six gates remain unfired;
five are provably unreachable (the extent, text-edge, column-count and
edge-mismatch guards all follow from checks already made above them), and only
the empty-assignment gate is reachable but unexercised.

- **Wave 33 — the cluster loop, and a caller at last.** `PdfRectTables.swift`
  ports the table half of `detect_tables_from_rects`. Waves 23–32 built eight
  strategies with nothing calling them; this is what calls them.

  The loop clusters a page's rectangles, tries the strategies against each
  cluster in decreasing order of geometric evidence, and keeps three
  whole-page fallbacks behind them for shapes clustering cannot see:
  - **Merged-cluster**, for clip-path PDFs where every column is its own
    cluster. It also *replaces* tables that were found but are all narrow —
    the same failure seen from the other side.
  - **Cell-rect**, for tables drawn as cell backgrounds, where the rows are in
    the rectangles but the columns are only in the text.
  - **Row-stripe**, for banded tables whose stripes never overlap, so
    clustering yields nothing at all and the page must be tried whole.

  Origin-anchored page backgrounds are held out of the *adjacency graph* but
  not out of the clusters — they would bridge separate tables into one, yet
  grid detection still wants their edges. Chart clusters are dropped outright
  before any detector sees them, with one escape hatch: repeated page fills
  can make a real shaded-cell table look like a chart, so the cluster is
  re-tried without them and a hypothesis of eight rows or more can overturn
  the chart verdict.

  Also reproduced: three-to-five box stacks never reach the stacked-box
  detector, because both the page and the cluster must hold six rectangles.
  That is a deliberate precision gate upstream, not an oversight.

1,485 cases agree on the first run. **Branch coverage was again measured, not
assumed** — and again the first measurement was damning: every existing case
was a single cluster, so the loop only ever exercised `direct` and the
cell-rect fallback. Seven whole-page shapes were added (two separated grids,
three two-column groups, non-overlapping stripes above and below the
fifteen-rect bar, a bar chart bridged by its axis rule, clip-path columns), and
seven of the ten branches now fire. The three that do not:
  - the **split-wide retry** and its two outcomes. Its call site is
    unreachable through this loop by construction: a cluster wide enough to
    split needs a rectangle bridging the gutter, and any such rectangle fills
    the gutter the splitter is looking for. `pdfSplitWideCluster` itself is
    covered by its own wave-23 probe.
  - the **chart-normalisation** acceptance, which needs dominant page fills
    that survive preprocessing; the oversized-width filter and the sub-rect
    dedup jointly remove them in every synthetic shape tried.

- **Wave 34 — hint regions and chart regions.** `PdfRectHints.swift` plus the
  hint pass in `PdfRectTables.swift` finish `detect_rects.rs`.

  A hint is not a table — it is a boundary. A form drawn with only an outer
  border and a header divider has no column structure at all, but its bounding
  box keeps the heuristic detector from sweeping a graph legend into the table
  beside it. Three sources feed it, in order: large decorative clusters
  (calendars, forms), clusters that failed grid validation but hold six or
  more text items, and — only on a rect-sparse page — a small cluster of cell
  borders. A lone hint is then *discarded* unless it came from a failed
  cluster: one region on its own is more likely decoration, and scoping to it
  would hide the rest of the page.
  - The hint pass re-clusters over **all** the page's rectangles, including
    the origin-anchored backgrounds the table loop deliberately held out of
    its adjacency graph. Harmless here, where a bridged region only has to
    bound something, and fatal there, where it would have bridged two grids.
  - `merge_overlapping_hints` loops until a pass merges nothing, so a chain
    A–B–C folds into one region across two passes. The 400pt cap on the merged
    width is what stops that chain creeping across the page.
  - Chart regions are the mirror image: a bounding box around text no strategy
    may grid. Their rectangle filter is deliberately *not* the shared
    preprocessing — an origin-anchored background is dropped outright rather
    than merely kept out of clustering, because letting one bridge into a bar
    cluster would inflate the region to the whole page.
  - One deviation, in naming only: the reference's region tuple is
    `(min x, min y, max x, max y)`, so its last two fields are edges, not
    extents. Ported as `(left, bottom, right, top)` rather than reusing the
    rectangle tuple, whose `width`/`height` labels would quietly mean
    something else. A unit test written against the misleading reading was
    wrong before this was fixed.

1,487 cases agree on the first run. Branch coverage measured again: the first
run fired only the failed-cluster and sparse-page sources (67 and 299 times),
with the large-decorative-cluster source and the merge both dead. Two shapes
fixed that — paired textless calendar grids, and two column groups 20pt apart
whose merged width stays under the cap — and all five paths now fire.

- **Wave 35 — the anchor primitives of `detect_lines.rs`.**
  `PdfRuleAnchors.swift` ports `collect_anchored_rows`, `logical_row_anchors`,
  `nearest_anchor_column`, `matched_anchor_column_count` and
  `combine_non_overlapping_tables` — the layer every ruled-table strategy in
  that file is built on.

  A booktabs table draws two or three rules and no column borders at all, so
  its columns exist only in where the text starts. These functions read that:
  gather the text a run of rules encloses, group it into rows, and infer each
  row's anchors from the gaps between word spans.
  - **Rows form against the row's *first* baseline, not its last.** Text
    drifting 2pt a line against a 2.5pt tolerance therefore makes a new row
    every second line rather than chaining into one — which is what stops a
    slanted column of text collapsing into a single row. A unit test written
    the other way round was wrong.
  - **No rules selects nothing.** The bounds are folded from the rules, so an
    empty list leaves them inverted (bottom at +∞, top at -∞) and no item can
    satisfy both. Reads like an accident, behaves usefully.
  - `logical_row_anchors` *replaces* the running right edge when an anchor
    opens rather than extending it, and clamps negative widths to zero.
  - Overlap between competing strategies is settled by **item ownership**, not
    geometry: a table sharing even one item with an accepted one is dropped
    whole.
  - Two stability fixes: Rust's `sort_by` is stable and Swift's `sort` is not,
    so both the item sort and the table sort break exact ties on the original
    index — which is precisely what stability would have given.

1,018 cases agree on the first run. Coverage of the anchor sweep was thin at
first (544 rows with a single anchor, 6 with three) because the wave-21 rule
cases exist for rule *geometry* and carry almost no text; six text-bearing
bands were added for joined and separated columns, drifting baselines,
coincident points, out-of-band text and negative widths.

- **Wave 36 — the open-edge grid and stacked-token strategies.**
  `PdfOpenEdgeGrid.swift` ports `build_stacked_token_table`,
  `build_open_edge_grid_table_for_rules` and `build_open_edge_grid_tables`.

  An *open-edge* grid is the scientific-paper shape: horizontal rules above,
  below and under the header, verticals between the columns, and nothing
  closing the left and right sides. The horizontals give the rows, the
  verticals the interior column edges, and the outer edges come from how far
  the rules themselves run — which is why **every column must carry text**: an
  empty one means those inferred outer edges are wrong, not that a cell is
  blank.
  - Only verticals spanning 80% of the band count. One that stops short is a
    cell divider or decoration.
  - The header sits *above* the top rule, in a 30pt band synthesised as a pair
    of rules so the wave-35 row collector can be reused unchanged.
  - A header item whose centre falls outside every column rejects the **whole
    table**, not just that item — the reference's `?` on the column search.
  - A fully populated first header cell is the *less* distinctive case, so it
    is only accepted when every logical rule in the band agrees on the same
    span; mixed spans belong to the physical-grid detector.
  - The stacked-token table is a narrow shape that would otherwise be built as
    a one-column table of noise: exactly three rules, five or more rows, every
    row a single left-aligned item, and three quarters of the body lone tokens
    carrying an underscore or colon. A two-word row is not disqualifying — it
    simply fails the token test and the ratio must be carried by the rest. A
    unit test asserting otherwise was wrong.

  **A harness decision worth recording:** these cases need vertical rules, and
  adding `v x y_min y_max` lines to the wave-21 rule case file would have had
  Rust parse them as a horizontal rule at y=0 (`unwrap_or(0.0)`) while Swift
  skipped them (`Float?`) — a divergence manufactured by the harness rather
  than found in the port. They live in their own case file instead.

180 cases agree on the first run. Gate coverage measured as usual: the first
pass fired only 4 of 9 gates (interior edges, band size, accepted, missing
header). Seven targeted shapes brought the rest in — 25 hatching verticals,
rules that snap to two edges while still spanning 28pt, a single occupied body
row, an empty column, a header item centred left of the first edge, a header
gap, and a mixed-span logical rule inside the band.

- **Wave 37 — the text-anchor (booktabs) strategy.**
  `PdfTextAnchorTable.swift` ports `build_text_anchor_table`: two or three
  rules, no verticals anywhere, and columns that exist *only* in where the
  header's words begin. The header row is the column definition and everything
  below is assigned to the nearest anchor.

  That is a great deal inferred from very little, so the function is mostly
  refusals — and nearly all of them exist to separate a real table from
  multi-column prose bracketed by decorative rules, whose first baseline looks
  like a header and whose text starts look like anchors. The gates are loose in
  deliberately different directions, because a real ruled table wraps its
  labels:
  - **Two anchors are never enough on thin evidence.** Two text columns under a
    few rules are indistinguishable from a two-column prose layout, so only
    densely ruled forms — where rule and row counts corroborate each other —
    survive. Wider tables have stronger anchor evidence and are exempt.
  - **Two rules are trusted only for a response form**: header naming both
    columns, every prompt row short and in the leading column, response column
    deliberately blank.
  - **Four or more full-width rules describe rows, not a booktabs band**, and
    first-row anchors alone may start below the real header — so the case is
    handed to a detector that can also weigh rectangles or whitespace.
  - A *majority*-numeric header is refused, which is what a year-over-year
    header row looks like; a body item starting left of the first anchor
    proves the inferred grid dropped a column outright.
  - The two prose tests reject an *extreme* cell (240 characters) or a
    *concentration* of long ones, and sustained prose keyed on content rather
    than row count — a long table of short labels and values stays valid at any
    height.

194 cases agree on the first run. Gate coverage started at **6 of 18** and the
reason was instructive: every wave-36 case spaces its rules evenly, and
`rules_are_uniform_grid` rejects those before anything else runs, so the
strategy was starved by its own case file. Fourteen booktabs shapes fixed that
and all 18 reachable gates now fire. One case had to be rebuilt after it failed
to reach its target — a two-anchor prose case is caught by the earlier
two-anchor gate, so the sustained-prose test needs three.

Two gates are provably unreachable and left unfired: `occupied_rows < 2` and
`occupied_columns < 2`. Rows are built *from* items so none can be empty, and
anchors are derived from row 0's item starts, so each anchor owns an item at
distance zero and no column can be empty either.

- **Wave 38 — text-anchor band scoping.** `PdfTextAnchorBands.swift` ports
  `detect_text_anchor_rule_tables` and `line_overlaps_text_anchor_band`.

  Wave 37 built a table from a run of rules; this decides which runs may be
  asked at all, and the answer is essentially *only where the page is
  otherwise bare*. Text-anchor inference is the sparse-geometry fallback of
  last resort, so any sign that a better-informed detector could own the
  region disqualifies it:
  - **Two hundred path lines crossing the band** is a chart or a schematic.
    The count stops at the threshold rather than totalling — the reference's
    `.take(200).count() >= 200`.
  - **Three spanning verticals.** Two are allowed, because a borderless table
    can still be boxed and two coordinates prove nothing about columns; a
    third is an interior divider, which means a physical grid.
  - **Six strokes of any length inside the band.** No single one proves a cell
    exists, but together they are diagram evidence.

  The band bounds are carried alongside each table because later stages need
  the claimed area without re-deriving it.

203 cases agree on the first run, with 29 bands accepted. All four branches
fire: 29 accepted, 25 interior-divider (the wave-36 grid cases supply those
for free), and one each for dense line art and many short strokes. Nine
scoping shapes were added, each paired with its just-under-threshold twin —
199 path lines, five strokes, two spanning verticals — so the thresholds are
pinned from both sides rather than merely crossed.

- **Wave 39 — the dense-row anchor strategy.**
  `PdfDenseRowAnchorTable.swift` ports `build_dense_row_anchor_table`, the
  last strategy in `detect_lines.rs`.

  It exists because wave 37 reads the *first* row as the schema, and a
  multi-level booktabs header puts one or two spanning labels there while only
  a later row exposes every real column. So this one takes the **widest**
  schema any row exposes, and pays for that licence with corroboration:
  - Two rows must independently reproduce three quarters of the anchors. One
    busy line inside a chart or form is not evidence of a table.
  - The body must hold numbers — at least three, and in a quarter of its
    filled cells. Prose bracketed by rules passes every geometric test above
    it; what it lacks is data.
  - Four evenly spaced levels *anywhere* in the band is ruled paper, even when
    the band as a whole is uneven.
  - A gap far larger than the median means two stacked bands, not one table —
    a page of charts contributes one dense numeric row each, and they must not
    be merged into a synthetic page-wide table.

220 cases agree on the first run. All 15 gates fire, but four of the shapes
written for them initially reached a *different* gate, and each miss was worth
recording:
  - 40pt-wide items spaced 40pt apart touch within the 6pt join gap and
    collapse to one anchor, so the "anchors too narrow" case needs narrow
    items.
  - Rows at the default 20pt spacing fall below the bottom rule and are never
    collected, so the "too many rows" case needs tight spacing to stay inside
    the band.
  - A body row that reproduces the schema counts as dense alongside the
    header, so the "one dense row" case needs every body row to be a stub.
  - Three numeric cells clears the floor; to fail the *ratio* the body needs a
    fourth row of text.

**`detect_lines.rs` is complete as of wave 40** — all six strategies and the
orchestrator that runs them.

## Phase 6 remaining work — exact inventory

Measured against the vendored reference at wave 20. `Sources/AnyDoc/Pdf/` is
6,636 lines of Swift at this point.

| Reference file | LOC | State | Notes |
|---|---|---|---|
| `adobe_korea1.rs` | 17,073 | not started | Generated CMap table. Follow the `gen-shiftjis-table.py` precedent: generate, do not hand-write. |
| `tables/detect_rects.rs` | 4,671 | not started | Ruled tables from `re` rectangles. Consumes wave 9 graphics; oracle already has `--graphics`. |
| `glyph_names.rs` | 4,590 | not started | Generated AGL table. Same precedent as above. |
| `detector.rs` | 3,645 | not started | Scanned-vs-text classification. Independent of everything else; good parallel wave. |
| `tounicode.rs` | 3,162 | **partial** | Codespace/bfchar/bfrange done (waves 1, 11). CID CMaps and `usecmap` remain. |
| `tables/detect_lines.rs` | 2,759 | not started | Ruled tables from stroked lines. Consumes wave 9 graphics. |
| `tables/mod.rs` | 2,529 | **partial** | `Table` and the grid helpers done (waves 13–14). Orchestration across strategies remains. |
| `markdown/convert.rs` | 2,284 | **partial** | Block loop done (waves 7, 11). Heading rarity scoring, TOC suppression, band-split columns, wrapped-bold runs, image and page markers, header/footer stripping remain. |
| `extractor/layout.rs` | 2,153 | **partial** | Line/word grouping done (wave 4). Multi-column and band-split remain. |
| `extractor/fonts.rs` | 2,083 | **partial** | `/Widths` and `/W` done (wave 3). Base14 metrics, `/Differences`, TrueType `cmap` remain. |
| `structure_tree.rs` | 1,234 | not started | Prerequisite for `detect_struct` and for MCID-aware merging (see wave 12's stated gap). |
| `tables/detect_struct.rs` | 1,163 | not started | Needs `structure_tree.rs` first. |
| `markdown/heading.rs` | 1,012 | not started | The heading signals wave 5 explicitly did not port. |
| `tables/structured.rs` | 972 | not started | |
| `markdown/preprocess.rs` | 792 | not started | |
| `extractor/xobjects.rs` | 681 | not started | Form XObjects — content streams nested in resources. |
| `markdown/analysis.rs` | 629 | **partial** | `compute_paragraph_threshold` and `has_dot_leaders` done (wave 7). Font stats, isolated lines, wrapped-bold runs remain. |
| `extractor/reading_order.rs` | 591 | not started | |

Also outstanding, outside pdf-inspector: **encryption** (RC4/MD5/AES-CBC,
which lives in lopdf), and the three non-PDF `asciiLowercased()` sites flagged
in wave 7 that may share the grapheme defect — unverifiable without re-cloning
`anydoc`.

### How to continue

Everything needed is in the repo; no state lives outside it.

```bash
scripts/gen-graphics-oracle.sh /tmp/oracle      # vendored reference + probes
scripts/gen-pdf-corpus.py      /tmp/corpus      # 30 adversarial PDFs
scripts/gen-pdf-oracles.sh     /tmp/corpus /tmp/oracle   # the per-file dumps
scripts/gen-classify-probe.py  /tmp/probe       # classifier + cleanup oracles
scripts/gen-grid-probe.py      /tmp/grid --oracle /tmp/oracle
ANYDOC_PDF_CORPUS=/tmp/corpus ANYDOC_CLASSIFY_PROBE=/tmp/probe \
  ANYDOC_GRID_PROBE=/tmp/grid swift test
```

Expect **473 tests, 87 suites, all passing**, and these counts — if any reads
zero, an oracle is missing rather than the code being fine:

```
pdf corpus: 27 graphs compared, 3 rejections agreed
pdf graphics probe: 26 files compared     pdf underline probe: 26 files compared
pdf classify probe / cleanup probe / grid / table format / table detect: > 0
```

The third step is easy to forget and does **not** fail loudly: without the
per-file dumps the corpus suites compare *nothing* and still report a count.
That is how this recipe was wrong when first written.

The drill that has caught every divergence this phase, in order:

1. Read the reference function *completely* before writing. Every wave that
   skipped this paid for it.
2. Never defer a helper on the core path. Wave 16 deferred one and diverged
   on hundreds of cases; wave 18 held the orchestrator back until all three
   of its helpers were in, and it landed clean.
3. Add the function to the oracle probe, generate cases aimed at each
   *branch*, and **check the verdict distribution** — wave 15 passed 2,513
   cases with two of four classifier branches never firing.
4. When the probe lights up, suspect the harness too. **Three times** this
   phase the first "divergence" was in the comparison, not the port: block
   ordering, float formatting, and `split` dropping empty fields where Rust's
   `splitn` keeps them.
5. Swift `String` compares grapheme clusters where Rust `str` compares bytes.
   This is gotcha 5 in §2 and has caused more real bugs here than anything
   else.

## Phase 6 status

Working end to end: bytes → objects → xref → filters → content operations →
ToUnicode-decoded text → exact positions and widths → lines, words,
paragraphs → captions, headings, lists and code → Markdown. The document's
structure, prose, emphasis, underlines, lists and cleanup come out right,
and links and form fields are recovered; its *tables* are not.

Graphics paths are now extracted, which unblocks the two largest remaining
pieces. The heuristic table strategy is complete. Remaining, roughly by size: the
three other detection strategies (14.4k LOC
of the 16.3k, now that the grid and the formatter are in — `detect_rects`
4.7k, `detect_lines` 2.8k, `detect_struct` 1.2k), the
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

- **Wave 40 — the line-table orchestrator.** `PdfLineTables.swift` ports
  `detect_tables_from_lines_inner` and both its public entry points, finishing
  `detect_lines.rs`. Ported whole rather than split: the function recurses into
  itself, so half of it would not have run.

  It classifies the page's strokes — diagonals ignored, anything under 20pt
  decoration, the axis test a slope comparison within two degrees — offers the
  sparse strategies their chance, and otherwise snaps the rule coordinates
  into a grid and assigns the text.

  **The structure worth understanding is the middle.** When text-anchor tables
  are accepted, the orchestrator recurses on *the rest of the page*: the
  accepted bands' graphics are removed and sparse inference switched off, so a
  drawn grid elsewhere is still found without an inferred header reaching into
  a band already claimed. It takes two readings of that remainder —
  geometry-only and geometry-plus-alternatives — and keeps the geometry-only
  one as a fallback for exactly that reason. An alternative overlapping *two*
  independent sparse tables is dropped as a synthetic merge; one replacing a
  single band still competes.

  The two-degree tolerance is `2.0_f32.to_radians().tan()`, computed in f32.
  The Swift literal was checked to be bit-identical rather than assumed —
  `0x1.1e122ap-5` either way.

172 cases agree on the first run, and all 18 reachable gates fire. Four needed
shapes built specifically, and three of those failed on their first attempt for
the same underlying reason — an earlier gate caught them:
  - a bare page frame has only two verticals, so it dies on the column-edge
    count long before the frame test; it needs three sides to reach it.
  - a band under 20pt tall has verticals under 20pt long, which are discarded
    as decoration, so the *column source* gate fires instead; the verticals
    must overhang the band.

The one gate never fired is provably unreachable: three column edges force at
least two columns and three row edges at least two rows, so the final
`num_rows < 2 || num_cols < 2` cannot hold.

- **Wave 41 — the standalone detector helpers.** `PdfDetector.swift` starts
  `detector.rs`, which decides whether a PDF carries real text or is a scan
  needing OCR. This wave takes the parts that stand alone, with no lopdf
  dependency: the byte-level page-count fallback, the page sampling, and the
  rule turning one page's analysis into a reason.
  - `estimate_page_count_from_bytes` scans raw bytes for `/Type /Page` in
    files too broken to parse. The entire exclusion of the page-tree node
    `/Type /Pages` is the delimiter test after `Page` — `s` is not one — and a
    name running to the very end of the buffer counts, since no byte follows
    to disqualify it. PDF whitespace here is six bytes including NUL but *not*
    vertical tab.
  - `distribute_pages` always samples the first and last page and spaces the
    rest evenly. The spacing is integer division, so on a short document
    computed indices collide and the result is simply shorter than asked for —
    reproduced, not smoothed.
  - `page_ocr_reasons` puts undecodable fonts and vector-outlined text ahead
    of missing text, because those persist *even when a text layer exists*:
    extracting it yields garbage rather than nothing, which is the harder
    failure to notice. Both can apply at once, which is why it returns a list.

301 cases agree on the first run, covering all five reason outcomes including
the two-reason one, and page counts from 0 to 40.

**A harness lesson:** the first attempt widened `PageAnalysis`'s fields with a
blanket `perl` over field names, which also rewrote a *function parameter*
called `has_images` and broke the build. The probe lives inside `detector.rs`,
so it can construct the private struct directly and **no widening was needed at
all** — the fix was deleting three lines rather than narrowing the pattern.

- **Wave 42 — the cipher-garble discriminator.** `PdfTextQuality.swift` starts
  `text_quality.rs` with its markdown-level detectors and the statistics they
  rest on.

  The hard case this exists for is a ToUnicode CMap that shifts every
  character by a per-range constant, so `Certificate` extracts as
  `8VceZWZTReV`. That output is **100% printable ASCII with word-like token
  lengths** — no replacement characters, no symbol soup — so every other
  detector passes it and it needs a discriminator of its own.
  - The discriminator is two cosines against English letter frequencies: one
    *unsorted*, one with **both** histograms sorted descending. A substitution
    cipher is a bijection, so it preserves the frequency *shape* exactly while
    destroying the *positions* — high sorted cosine, low unsorted. That pair
    is what separates it from merely non-English ASCII: DNA and hex dumps have
    too steep a profile to match the shape, while protein sequences and base64
    are not unlike English enough in position.
  - Two guards come first and matter as much: at least 200 ASCII letters, and
    vowels no more than 30% of them. The reference's closest legitimate
    document sits at 0.264 against that 0.30 bar.
  - The bigram chain resets at every non-ASCII-letter character, so a word
    boundary is not a bigram — which is what keeps `camelCase` identifiers
    from reading as case-shift garble.

221 cases agree on the first run, **including the cosines to nine decimal
places**, which is the useful signal here: it means the f64 accumulation order
matches rather than merely the verdict. 37 cases are garbled, 38 flagged by the
cheaper heuristics without being garbled, and 146 clean.

- **Wave 43 — span-level text quality.** `PdfTextSpanQuality.swift` finishes
  the detector half of `text_quality.rs`: per-span damage classes, and the
  page-level rule that weighs accumulated replacement evidence.

  The design point is the split between *strong* and *weak* signals.
  Dollar-as-space, private-use runs, CID garbage and C1-control tokens condemn
  a span on sight — real text almost never contains them. Replacement
  characters do not, because a page of mathematics legitimately produces a
  few; they only accumulate as page evidence, judged on **density in basis
  points** rather than count, with a shortcut for a page that is nothing but a
  short broken text layer.
  - Private-use damage has two routes: three in a row, or a majority of a
    short span. Whitespace breaks the *run* but not the majority, so
    spaced-out damage is still caught — by the second rule, not the first.
  - `is_cid_garbage` increments its total for a middle dot and then `continue`s
    past both signature tests, so `·` dilutes the ratios rather than being
    ignored. Reproduced in that order.
  - Rust's `is_alphanumeric` is general-category based, so Roman numerals,
    vulgar fractions and Arabic-Indic digits all count.

244 cases agree on the first run, spanning all three verdicts (180 none, 31
replacement, 33 strong) and every combination of the underlying flags.

**A finding worth recording:** `is_garbage_text`'s doc comment cites
`----1-.-.-.___  --.-. .._ I_---.` as its motivating example, but hyphens are
on the Markdown-syntax skip list and underscore runs are decorative leaders —
so almost nothing in that string is counted and it now falls under the
fifty-character floor. The reference agrees it is *not* garbage. This is
upstream behaviour that has drifted from its own documentation, and a unit
test written from the comment rather than the code was wrong; it is now
pinned, with the reason, in both the source and the test.

- **Wave 44 — bidirectional text and script classification.**
  `PdfBidiText.swift` ports the script-block predicates, RTL detection,
  visual-order reversal and the small text-string helpers from
  `text_utils.rs`.

  A PDF stores glyphs in the order they are *drawn*, which for Arabic and
  Hebrew is left-to-right screen order rather than reading order.
  - Direction is a **strict majority** of RTL characters over LTR ones, with
    CJK excluded from both counts — so an Arabic line with a Japanese caption
    still reverses, while five Arabic letters against five Latin ones does
    *not*. A unit test asserting the tie went the other way was wrong.
  - Reversal cannot be a simple reversal once anything is mixed in: an
    embedded number or Latin word reads left to right *inside* a
    right-to-left line. The text splits into runs, the run order reverses, and
    only the non-LTR runs reverse internally — so `2024` survives as `2024`
    rather than becoming `4202`. Punctuation joins whichever run it touches,
    which is what keeps `3.5` and `A/B` intact while a bare `!` after Arabic
    moves with the Arabic.
  - `is_arabic_presentation_form` stops at U+FEFE rather than U+FEFF: the last
    codepoint of Presentation Forms-B is the byte-order mark, which is RTL by
    block but is not a glyph.

233 cases agree on the first run, 175 of them right-to-left.

**Deliberately not ported: `expand_ligatures`.** It applies NFKC normalisation
when Arabic presentation forms are present, and NFKC needs a Unicode
decomposition table this port does not have. Everything the function *calls*
is now in place, so the remaining work is the table — a generator wave, on the
`gen-shiftjis-table.py` precedent, not a hand-written one.

- **Wave 45 — Canva letter-spacing repair.** `PdfLetterSpacing.swift` ports
  `fix_letterspaced_items`, `compute_canva_join_threshold` and
  `collect_gap_ratios`.

  Canva renders text with CSS letter-spacing, which reaches the PDF as one
  glyph per positioning operation. The extractor's `TJ` handler then inserts a
  space at every gap, so a word arrives as `"a r i b"` — or, on the other
  variant, as one item per character with no spaces at all.
  - Both variants need the same second thing, and it is the less obvious half:
    a **raised join threshold**. Every gap on such a page is wide by ordinary
    standards, so the default 0.10 would refuse to join anything and the page
    would come out one letter per word. The per-character variant rewrites no
    text at all — the threshold *is* its entire output.
  - The threshold is computed **before** the spaces are stripped, since the
    gaps are what it measures.
  - Both the largest *and* smallest gap ratio must clear 0.40. One ordinary
    pair is enough to say the page is not uniformly letter-spaced, and raising
    the threshold there would glue real words together.
  - `len() < 3` on the substantial-item test is **bytes** in the reference, so
    a one-character CJK item counts as substantial where a one-character ASCII
    one does not.

182 cases agree on the first run. The first pass raised the threshold in only
3 cases of 167, so fourteen shapes were added across the gap range: eleven now
raise it, spanning 0.62 to the 2.0 upper clamp, which fires three times.

The **lower** clamp of 0.50 is provably unreachable: the smallest ratio must
be at least 0.40 to get that far, so the median is too, and 0.40 × 1.55 =
0.62 already exceeds it.

- **Wave 46 — the join decision.** `PdfJoinItems.swift` ports
  `should_join_items`, which answers the one question a PDF never does: is the
  space between two glyphs a *space*, or just the gap between letters?

  The order of the tests is the design. Cheap textual signals come first and
  override geometry outright — a leading `.` joins whatever the distance,
  because `www` and `.com` are one word however they were positioned.
  - **A CID font inverts the usual meaning of a zero gap.** Those fonts emit
    one word per text operator, so touching items are *separate words*. Unless
    the operator carried three or more words, in which case it was a whole
    phrase and a zero gap is mid-word again. CJK is exempt from all of it.
  - On a letter-spaced page the comparison switches from font size to
    **character width**, averaged over the previous item so a mix of wide and
    narrow glyphs normalises.
  - A lowercase-to-lowercase junction between two multi-character items gets a
    wider bar than any junction involving a capital: imprecise CID metrics
    split `enterta` + `inment`, while `LCOE` + `WITH` really is a boundary.
  - In the no-width fallback, lowercase→uppercase is a boundary *regardless of
    distance* — words do not change case mid-word.

349 cases agree on the first run, 241 joined against 108 not.

Two unit tests of mine were wrong in instructive ways. The first assumed the
CID phrase branch could return false; it cannot, because it is already guarded
on a gap under 1% of font size and then tests 15% — pinned as such, so a change
to either constant surfaces. The second passed a `gap` to a fallback-path case,
where the *estimated* width dominates and the parameter had no effect at all;
those cases now set the second item's x directly.

- **Wave 47 — bare struct names, and an upstream data-loss bug.**
  `PdfStructNames.swift` ports `fix_bare_struct_names` and `sort_line_items`.

  Some generators write `/S Code` where the grammar requires `/S /Code`. A
  bare token makes the whole dictionary unparseable, so the element is
  silently dropped and a tagged PDF quietly loses its tagging. The repair
  patches the bytes before parsing, and only for real structure types —
  patching any bare word would corrupt dictionaries where `S` means something
  else. `H` is listed before `H1`, which is safe only because the
  delimiter check rejects the `1`.

  **The finding:** the function *deletes the byte immediately after every name
  it repairs.*

      /S Code>          →  /S /Code            the `>` is gone
      /S Code\nNEXT     →  /S /CodeNEXT        the newline is gone
      /S Code /S Table  →  /S /Code/S /Table   the space is gone

  The cause is that the output buffer's length doubles as the input cursor,
  and each repair writes one byte more than it reads — the inserted `/` — so
  the cursor runs permanently one ahead. It normally goes unnoticed because
  the lost byte is the whitespace that terminated the bare name, which the
  lexer does not miss; but when the terminator is `>` or `/` it corrupts the
  very dictionary the function set out to save.

  This was **verified against the reference binary directly**, not inferred
  from reading. It is reproduced deliberately, per §1: silently fixing it
  would make the port disagree with the reference on exactly the malformed
  files the function exists for. Pinned in three unit tests and documented at
  the call site.

220 cases agree, 28 of them repaired. My own unit tests were written expecting
the *correct* behaviour and failed — which is how the bug surfaced at all.

- **Wave 48 — the structure tree and its walks.** `PdfStructTree.swift` ports
  `StructRole`, `StructElement`, the tagged-table types and the four pure
  operations over them: `collect_tables`, `collect_rows`,
  `collect_mcids_recursive` and `flatten_recursive`.

  A tagged PDF carries a parallel tree saying what its content *means* — this
  is a heading, that is a table cell — and where it exists it beats any
  geometric heuristic, because it is what the author declared rather than what
  the layout suggests.
  - A `Table` element **stops the descent**: a table nested inside a cell is
    not collected separately, because the outer table already owns it.
  - Rows are found through `THead`/`TBody`/`TFoot`, which carry none of their
    own but are where real documents put them.
  - An empty row is still appended, so it counts toward the two-row minimum
    even though the "any row has cells" test then decides the outcome.
  - A marked-content reference whose page will not resolve is dropped rather
    than kept with a guessed page — the id alone is meaningless without
    knowing which stream it indexes.
  - **`Figure` is deliberately absent from the non-heading set.** Cover pages
    routinely tag the document title inside a Figure next to a seal or logo,
    and that title is a real heading; `Formula` and `Form` stay, because a
    line tagged as an equation or a form field never is.

  Building a tree from a document is a separate concern — it needs the
  `/RoleMap`, kid resolution and object-reference chasing — and comes later.

165 cases agree on the first run, covering nested tables, grouping elements,
unresolvable pages and every role in and out of the non-heading set.

- **Wave 49 — column inference for tagged tables.** `PdfStructColumns.swift`
  ports `infer_column_positions` and `align_positions_to_columns` from
  `tables/detect_struct.rs`.

  The structure tree says which cells exist and how they group into rows, but
  nothing about where the columns *sit* — that has to come from where the
  cells were drawn, and rows disagree with each other.
  - The **widest** row supplies the anchors, being the one least likely to be
    missing a column. `max_by_key` keeps the last maximum, so the lowest row
    wins a tie.
  - `align_positions_to_columns` is a dynamic program: a short row's cells are
    placed under the columns they actually match rather than packed against
    the left edge, minimising total displacement while keeping order.

  Three unit tests of mine were wrong, each about an ordering detail:
  - The fallback is consulted **before** the "no anchors at all" exit, so a
    single fallback position becomes an anchor and is then padded like any
    other. The early return is reachable only with an empty fallback — or with
    `columnCount == 0`, where the fill loop breaks immediately.
  - Ties in the alignment bias **right**, not left: the cost table is filled
    left to right and the last equal cost wins, so a cell exactly between two
    columns lands in the right-hand one.
  - With every row one position wide, the *last* row supplies the anchor, not
    the first.

169 cases and 212 alignments agree on the first run.

- **Wave 50 — row alignment for tagged tables.** `PdfStructRows.swift` ports
  `align_struct_rows` and `left_align_struct_rows`.

  The structure tree gives rows of varying length; Markdown needs them
  rectangular. The two strategies differ in more than their name:
  - The positioned one trusts x **only when every present cell has one** — a
    partial set would misplace the rest — and a cell counts as present if it
    has text, items, *or* a position, so an empty but positioned cell still
    holds its column open.
  - Cells past the available columns are dropped **along with their item
    indices**, so those items stay unclaimed rather than being attributed to a
    cell that was never emitted. The left-aligned strategy does the opposite:
    it claims every index even past the truncation point.
  - Both take a row's baseline as the *highest* y any cell reported, since a
    row sits at the top of its tallest cell.

164 cases agree on the first run. Two more of my unit tests were wrong, and
the second found something:
  - Skipping a wholly absent cell does *not* shift the following cells left —
    position still decides where they go.
  - **The space-joining branch is unreachable.** Both assignment paths give
    strictly increasing column indices — the dynamic program by construction,
    the fallback because it is the identity — so no column is ever written
    twice. Ported anyway, with the reason recorded at the line.

- **Wave 51 — recovering an unclaimed table header.**
  `PdfStructHeader.swift` ports `recover_unclaimed_header_row`.

  Some generators tag a table's body but leave its header outside the tree
  entirely, as loose text above the first row. The tagged rows then come out
  *ragged*, and that raggedness is the signal something is missing — which is
  why the whole function is gated on it. On a clean table, text above it is a
  caption, and stealing it would be worse than leaving the header absent.
  - The search window is **asymmetric**: 25pt to the left of the first column,
    120pt to the right of the last, because a header label may overhang the
    final column far more than the first one.
  - Up to three lines are gathered, joined bottom-up and then reversed, so a
    two-line header reads top line first.
  - A line with more items than the table has columns **abandons the whole
    recovery**, not just that line — as does an alignment that comes back
    shorter than the line, since a partial header is not worth having.
  - A table of four columns or fewer must be fully labelled; a wider one is
    allowed a single unlabelled column, which is usually a row-header stub.

187 cases agree on the first run. The first pass recovered a header in only 6
of 167 cases, because the randomised cases almost never happen to line up with
the columns; twenty well-formed shapes across three to six columns and one to
three header lines brought that to 24.

- **Wave 52 — the struct-tree table orchestrator.** `PdfStructTables.swift`
  ports `detect_tables_from_struct_tree` and `legacy_column_positions`, tying
  waves 48–51 together. **`tables/detect_struct.rs` is now complete.**

  It matches the tree's cells to the page's text through marked-content ids,
  then builds *two* candidate tables and picks one.
  - A structure tree can outlive the content it describes, so under a third of
    cells resolving rejects it outright and leaves the page to the geometric
    detectors.
  - **The selection rule is the surprise:** the position-aligned candidate is
    used *only when a header was actually recovered*. Otherwise the plain
    left-aligned table wins, with the crude
    first-row-that-can-supply-one column positions. So all of wave 49's column
    inference and wave 50's positional alignment exist to serve the header
    recovery rather than the table's own layout — reproduced as written, and
    pinned by two unit tests that assert each branch.

  **One blocking gap, recorded honestly:** `PdfLayoutItem.mcid` was added for
  this wave but nothing sets it, because the extractor's `BDC`/`EMC` tracking
  is unported. The detector is complete and verified — 164 cases, 89 tables —
  but produces nothing on a real document until that lands. It is the single
  input the whole struct-tree path is waiting on.

164 cases agree on the first run, building 89 tables against 75 rejections.

- **Wave 53 — marked-content tracking.** The extractor now maintains a
  `BMC`/`BDC`/`EMC` stack and tags every run with the marked-content id in
  effect, which is the input waves 48–52 were waiting on. `PdfTextRun.mcid`
  and `PdfLayoutItem.mcid` are now populated rather than always `nil`.
  - The stack holds an *optional* id per level, and the lookup searches
    **outwards** rather than reading the top: a `BMC`, or a `BDC` whose
    dictionary has no `/MCID`, does not hide the enclosing element's id.
  - An unbalanced `EMC` must not underflow, and an unclosed `BDC` runs to the
    end of the stream. Both are pinned.
  - Properties given **by name** — `/Span /P1 BDC`, naming an entry in the
    page's `/Properties` — yield no id. The reference handles an inline
    dictionary and a direct object reference only, so a named lookup falls
    through. Reproduced and pinned, because it reads like an oversight and is
    not ours to correct.
  - `/ActualText` is **not** ported. It shares the same `BDC`/`EMC` machinery
    but is a separate feature — a text override for ligatures, with its own
    matrix and rise capture at the section boundaries — and is listed as
    remaining rather than half-done.

  **A new probe shape:** the reference's marked-content code is embedded in a
  thousand-line function that needs a `Document`, so it cannot be called
  directly the way earlier waves' helpers could. `scripts/gen-mcid-corpus.py`
  writes twelve small hand-built PDFs — nesting, siblings, unbalanced
  operators, named properties — runs the reference's real extractor over each,
  and saves both the content stream and the expected output. The Swift side is
  fed the same content stream, which is the only input the tracking depends
  on. 12 cases agree on the first run.

**Still not wired:** nothing in `Sources` calls `pdfExtractTextRuns` yet — the
document→markdown pipeline is assembled in a later phase — so the struct-tree
table path is complete end to end but not yet reachable from a file.

- **Wave 54 — reading the structure tree out of a document.**
  `PdfStructTreeParser.swift` ports `StructTree::from_doc`, `parse_role_map`,
  `parse_kids`, `parse_kid`, `parse_struct_element_dict` and their helpers.
  **`structure_tree.rs` is now complete**, and the struct-tree table path runs
  end to end: document → tree → tables.

  `/K` is the awkward part. It may be an integer, a dictionary, a stream or an
  array of any mixture — and an integer means *content of this element* while
  a dictionary means *a child element*, so one key carries two different
  relationships.
  - A bare integer directly under `/K` at the kid level becomes a **synthetic
    `Span`**: the reference wraps it rather than attaching it to the parent, so
    the tree gains a node the document never declared. Its own comment admits
    the wrapper is a workaround.
  - The lone-dictionary branch does **not** check for `/Type /OBJR`, unlike the
    array branch beside it. An object reference there is parsed as an element
    and then dropped for want of an `/S` — same outcome, different route.
  - `/Pg` must stay a *reference*: resolving it to the page dictionary would
    lose the identity the tables key on.
  - The role-map chain runs at most eight hops, and only for names that are
    not already standard — so a document cannot redefine `H1`.
  - A `/StructTreeRoot` with no children is reported as *absent*, since it
    tells a caller no more than having none.

  **A second corpus-based probe**, on the wave-53 pattern:
  `scripts/gen-structtree-corpus.py` writes twenty hand-built tagged PDFs —
  every `/K` shape, MCR and OBJR dictionaries, inherited pages, role-map
  chains and cycles, a self-referential element — and runs the reference's own
  `from_doc` over each. **20 documents agree on the first run**, including the
  64-level depth limit and the role-map cycle resolving to `Other("A")`.

**Deferred again: `/ActualText`.** It shares the `BDC`/`EMC` machinery wave 53
added, but its emission path calls `expand_ligatures`, which is still blocked
on an NFKC table. Porting it without that would be silently wrong on exactly
the Arabic text it exists for.

- **Wave 55 — NFKC, and the ligature expansion it was blocking.**
  `PdfNfkc.swift`, the generated `PdfNfkcTables.swift`, and `PdfLigatures.swift`
  — `expand_ligatures` at last, deferred through waves 44 and 54.

  This is the first wave ported from a *dependency* rather than a function:
  the reference calls `unicode-normalization`'s `nfkc()`, so the algorithm is
  reimplemented and the tables come from that same crate.
  - **The tables must come from the crate, not from Python.** The crate is on
    Unicode 17.0.0 and the local `unicodedata` is on 13.0.0; a table generated
    from the wrong version would diverge on anything added or changed between
    them. `scripts/gen-nfkc-tables.sh` builds a small program against the
    crate and dumps what it says.
  - Hangul is left out on purpose — its decomposition and composition are
    arithmetic, and tabulating 11,172 syllables would add nothing.
  - Flat integer arrays rather than dictionary literals: a Swift dictionary
    literal of six thousand entries takes minutes to type-check.

  **A real bug, caught by the probe.** The composition table was first built
  from the *full* NFD, which is wrong: U+01D5 decomposes fully to three
  scalars (U, diaeresis, macron) but composes from two (U+00DC, macron), so
  every multiply-accented letter was missing its pair. The fix derives the
  one-step form by recomposing everything but the final mark and checking the
  whole thing round-trips — which also filters the composition-exclusion list
  without ever needing it. Pairs went from 705 to 961.

  Verified against the crate over **every codepoint (1,112,064) and 4,000
  random sequences**. Single codepoints never exercise canonical ordering or
  composition blocking, so the sequences are the half that matters; they are
  built from starters and marks chosen to collide on combining class.

  `expand_ligatures` then follows directly. It normalises **only** when Arabic
  presentation forms are present — folding everything would turn a
  non-breaking space into an ordinary one, which the spacing logic depends on
  — and the presence check has to run *before* normalisation, since NFKC
  erases the evidence. 221 ligature cases agree on the first run.

**`/ActualText` is now unblocked** and is the natural next wave.

- **Wave 56 — `/ActualText`.** The extractor now honours a marked-content
  section's declared text, completing the `BDC`/`EMC` machinery wave 53
  started and using wave 55's ligature expansion.

  A section says what its text *really* is; the glyphs inside are whatever the
  font drew. So they are suppressed — not extracted at all — while still
  advancing the text matrix, because how far they moved it *is* the section's
  width.
  - The **first glyph's** position is preferred to the `BDC`'s. A `Td` between
    the two may have moved to the correct line, leaving the `BDC` position on
    the previous one, so the capture happens at the first `Tj`/`TJ` and after
    a `T*` line move rather than at the section's start.
  - The position state is a **single slot rather than one per level**, so a
    nested section resets it and the outer one reports wherever the glyphs
    after the inner section sat. Pinned as a test: it looks like a bug, and
    it is reproduced.

  **Two pre-existing divergences surfaced**, both invisible until an item
  could be emitted without a font:
  - `current_font_size` defaults to **12**, not zero. Nothing had emitted an
    item before a `Tf` until an `/ActualText` section with no glyphs did.
  - The `TJ` arm advances the text matrix **only when the font has metrics**.
    Without them the reference leaves every displacement unapplied, so
    following text overlaps — and an enclosing section measures zero width.
    The port advanced unconditionally.

  Both were found by extending the wave-53 probe to report position and size
  rather than just text and id, which is the half that actually exercises
  this wave. 21 corpus documents agree.

**A test-construction note worth keeping:** a PDF literal string is a *byte*
string. Writing `U+FB01` into a Swift source literal puts its UTF-8 bytes into
the content stream, where they decode as Latin-1 mojibake — the ligature has
to be given as UTF-16BE with a byte-order mark. Two attempts at that test were
wrong before the third was right.

- **Wave 57 — the Adobe Glyph List.** `PdfGlyphNames.swift` ports
  `glyph_to_char`, with its 4,532-entry table generated by
  `scripts/gen-glyph-names.py`. A font's `/Differences` array *names* its
  glyphs rather than numbering them, so this is what turns `/quotesingle` and
  `/uni2019` back into characters.

  **The table is parsed out of the reference's own `glyph_names.rs`, not
  fetched from Adobe.** The reference carries its own copy of the list, with
  its own additions and omissions; a freshly fetched AGL would differ, and
  every difference would be a divergence. Same principle as wave 55 taking
  NFKC from the crate rather than from Python.

  Three fallbacks handle names the table lacks, and they are not symmetrical:
  - A dot suffix names a variant — `zero.tf` is still a zero — and is
    stripped, but only helps if the *base* is in the table.
  - `uniXXXX` takes exactly four hex digits and **ignores anything after
    them**, so `uni0041FF` is `A`.
  - `uXXXX` takes the **whole remainder**, so `u0041.alt` fails where the
    `uni` form would have succeeded.
  - Windows Symbol fonts map their glyphs into the private-use area at F000,
    so `uniF041` is stripped back to `A`. One past the range, `uniF100`, is
    left alone.

  Verified over **every name in the table plus the fallback forms — 4,570
  cases, all agreeing on the first run**, 4,553 of them resolving. A unit test
  also asserts the generated table is sorted, since a binary search over an
  unsorted one would fail silently on some names and not others.

- **Wave 58 — the `/Differences` encoding array.**
  `PdfEncodingDifferences.swift` ports `parse_encoding_dictionary` and its
  helpers, which is what wave 57's glyph table exists for.

  The array is flat and mixes numbers with names: a number sets the next code,
  and each name takes the code after the last, so `[65 /A /B 200 /eacute]`
  assigns 65, 66 and 200.
  - A code is truncated to a byte with `n as u8`, so 256 becomes 0 rather than
    being rejected, and the code **wraps** after 255.
  - A name the glyph table cannot resolve is left out of the map but **still
    advances the code**, so the byte keeps whatever the base encoding gave it
    and the following names are not shifted onto it.
  - A value that is neither number nor name is ignored *without* advancing,
    so a stray entry does not displace the names after it.
  - `gidNNNNN` names are raw glyph indices into the embedded font's own
    tables. They are recorded rather than mapped, so a caller can tell the
    text is undecodable without a `/ToUnicode` map rather than being silently
    wrong.
  - One private mapping is carried, deliberately **font-scoped**: Aptos
    subsets out of Office expose the `ff` ligature as `/g431` with nothing to
    explain it. `/gNNN` names mean different things in different fonts, so the
    same name elsewhere resolves to nothing.

220 cases agree on the first run, mapping 471 codes.

- **Wave 59 — single-byte decoding fallbacks.**
  `PdfSingleByteDecode.swift` ports the eight functions that guess at bytes
  when a font declares no usable encoding.

  Windows-1252 is the right guess for most documents and exactly wrong for
  TeX and symbol fonts, which put glyphs in the same byte range — so the guess
  is made **per font, by name**. Getting it wrong is visible in the output:
  a TeX font read that way turns `deficiente` into `de…ciente`.
  - The five codepage slots with no Windows-1252 meaning (0x81, 0x8D, 0x8F,
    0x90, 0x9D) fall through to Latin-1 rather than being rejected.
  - The subset tag is stripped with `rsplit_once`, so the **last** `+`
    separates it and `A+B+CMR10` is still a TeX font.
  - Symbol and Wingdings map into the private-use area at F000. Most of the
    range is recovered by removing the offset; three codes are bullets in
    every such font and one is a checkmark, so those are named outright, and
    below 0x20 the codepoint is left alone since removing the offset would
    give a control character.
  - `score_text` counts known words for ten and penalises a long letter run
    that forms none — which is the shape of a wrong single-byte decoding,
    plausible letters in implausible arrangements. CJK and kana count as
    letters so a Japanese document is not scored as noise.
  - A remapped decoding must beat the primary by **more than three** to be
    taken: a near-tie is not evidence enough to overrule what the font said.

429 cases agree on the first run, including **every byte value under both
readings**.

- **Wave 60 — the font program's own opinion of its style.**
  `PdfFontFileStyle.swift` ports `descriptor_style_flags`,
  `get_font_file2_obj_num`, `cff_font_name` and the accessors they lean on.

  Wave 6 read emphasis off the `BaseFont` name, which fails on a subset font
  called `Tc1`. The `/FontDescriptor` is the second opinion — but descriptors
  lie too, writing `/ItalicAngle 0` for a genuinely italic face, so there is a
  third: the embedded font program itself. Any one of the three is enough.
  - `/ItalicAngle` and `/Flags` are read **unresolved**. An indirect value
    reads as absent, and `/Flags` must be an *integer* — `64.0` contributes
    nothing, because `as_i64` accepts only `Object::Integer`.
  - The descriptor is taken from the font dictionary **first**; only a font
    with none looks at `/DescendantFonts[0]`. A Type0 dictionary carrying
    both keeps its own, which is what the reference's `or_else` decides.
  - The slant bar is `>= 4.0`. This port had `>`, so it disagreed at exactly
    four degrees — **fixed here**, and the corpus pins the boundary from both
    sides.
  - CFF offsets are 1-based from the byte *before* the object data, so the
    object base is one less than the end of the offset array and a first
    offset of 0 is invalid rather than empty.
  - The CMap key falls back to the descendant font's own object number when
    no program is embedded — but that fallback sits *after* the descriptor
    has been required, so a descendant with no `/FontDescriptor` yields
    nothing at all.

  **Partial:** the reference tries a TrueType/OpenType parse before the CFF
  one — OS/2 `fsSelection`, the `post` table's angle — resting on
  `ttf_parser`'s whole-font validation, which is not ported. The deferral
  cannot give a *wrong* answer, only a missing one: an sfnt begins `00 01 00
  00` or `OTTO` and the CFF reader requires a leading `01`, so a well-formed
  sfnt falls through to no flags rather than being misread. What is lost is
  the rescue of a TrueType face whose descriptor lied.

  Two probes: **210 CFF programs** byte-level, and **12 hand-built PDFs**
  (`scripts/gen-font-corpus.py`) covering 13 styled fonts across every branch
  of both functions. All agreed on the first run.

- **Wave 61 — the leaf tests of column detection.**
  `PdfColumnValleys.swift` ports `find_relative_valleys`,
  `is_list_marker_column`, `spans_multiple_columns` and `is_page_number` from
  `extractor/layout.rs` — the first step toward the multi-column work
  `PdfLayout.swift` has been deferring since wave 4, and on the critical path
  to assembling the pipeline end to end.

  Column detection projects the page's text onto its x axis and looks for the
  gutter. On a ragged page the gutter is empty and trivial to find; on a
  *justified* two-column page the text reaches its edge on both sides and the
  histogram never touches zero. `find_relative_valleys` is the fallback for
  that page, and it is a stack of eight gates because a page has many dips
  that are not gutters.
  - A **completely empty** gutter is passed over — `val < 1.0` skips it. That
    reads like a bug and is not: an empty gutter belongs to the absolute
    detector, and finding it here too would have the two argue.
  - The flanking peaks are measured 25 bins either side, so a density change
    further out than that is invisible. A construction that varies the far
    margin does not test the balance gate at all — which cost two wrong unit
    tests before the reference was asked directly.
  - The balance bar is inclusive: a smaller peak at exactly 40% of the larger
    still passes.
  - A five-bin moving average runs first, so a one-bin dip is smoothed away
    however deep it is.
  - The result is always at most one valley, reported as a fixed five bins
    around the deepest point — a location, not a measured width. Ties keep
    the earlier gutter, since both selections compare with `<`.
  - `is_page_number` is `is_ascii_digit`, so a superscript or fullwidth digit
    is body text; and the top/bottom bands are absolute point values, so a
    much taller page puts its own footer outside them.

  489 probe cases agree with the reference on the first run. Gate
  instrumentation showed `spans_multiple_columns` returning true only 3 times
  and the single-valley return firing 8 times; targeted cases took those to
  28 and 27. 30 unit tests.

- **Wave 62 — the arbiters that turn a gutter into a column.**
  `PdfColumnBuild.swift` ports `columns_have_prose` and
  `validate_and_build_columns` from `extractor/layout.rs`, the layer above
  wave 61's valley finder.

  A dip in the histogram is only a *candidate*. A table's column separator,
  the gap beside a figure and the space after a list's bullets all look
  identical to it, so these two decide: one asks whether each proposed column
  reads like prose, the other whether both sides carry enough text over
  enough of the page's height.
  - Neither ever reports failure. `validate_and_build_columns` always returns
    at least one region, so a page that fails every test comes back as a
    single full-width column and the caller carries on unaware.
  - The page's vertical extent is measured from **narrow items only** — the
    same ones the histogram counted. A full-width title would otherwise
    stretch the range and sink the overlap ratio for two columns that
    legitimately sit below a figure. When *every* item is full-width the
    narrow set is empty, the folds leave the range negatively infinite, and
    the overlap test is skipped entirely.
  - Edge assignment is deliberately asymmetric: an item must *end* before the
    gutter to be left of it and *begin* after it to be right, so one lying
    across it is counted on neither side.
  - A sidebar is accepted on three items when the dominant side has the full
    count; below three it is not a column.
  - `columns_have_prose` is "all columns" rather than "most": the first
    failure ends the question. Its line count is checked twice — once as
    items and again after grouping — because twenty items sharing a baseline
    are one line, not twenty.
  - Both of the reference's sorts in the four-column truncation are stable,
    so equal scores keep discovery order; Swift needed an index tiebreak.

  626 probe cases agree on the first run. Gate instrumentation lifted the
  thinnest branches — narrow columns 2→14, marker sides 3→9, table-shaped
  columns 3→9. 18 unit tests, every boundary read off the reference rather
  than derived from the constants: the 45% line-fill bar lands at exactly
  126pt of a 280pt column and is inclusive, and 5 full lines out of 12 pass
  the 40% ratio where 4 do not.

- **Wave 63 — the lines that ignore the columns.**
  `PdfSpanningLines.swift` ports `identify_spanning_lines` and
  `split_column_stragglers`, the third layer of the column stack.

  Once the columns are known a real page breaks them: a title runs the full
  width, a section header crosses the gutter, a footer belongs to neither
  side. Those have to be lifted out before the columns are read in sequence,
  or the title arrives halfway down column one.
  - A spanning title and two columns of body text at the same height have
    identical x extents. What separates them is **where the gaps fall** — a
    real spanning line has no inter-item gap sitting at a gutter, because
    nothing interrupts it there. One gutter gap anywhere disqualifies the
    whole line, however far the others are from one.
  - A line needs **two items** to have a gap to judge, so a title written as
    a single wide run is skipped however wide it is. That starved the probe
    at first — 5 of 37 cases marked anything until multi-piece titles were
    added, then 22 of 60.
  - Gaps under 5pt are word spacing and are not examined, so a gutter inside
    one does not disqualify the line.
  - `split_column_stragglers` cuts a column at any gap over three times its
    **own** median line spacing, floored at 30pt. Uniformly wide spacing is
    therefore not a break at all — five lines 200pt apart have a 600pt bar
    and stay one cluster.
  - Rust's `max_by_key` returns the **last** maximum where Swift's `max(by:)`
    returns the first, so two equal-length clusters leave the *lower* one as
    the core. Reproduced with a `>=` comparison.

  715 probe cases agree on the first run. 17 unit tests; one of them had to
  be corrected after the reference showed that uniformly wide spacing does
  not split, which is a consequence of the threshold being relative.

- **Wave 64 — the XY cut, and telling a newspaper from a table.**
  `PdfXyCut.swift` ports `try_xy_cut_split` and `is_newspaper_layout`, the
  last two pieces before `detect_columns` itself becomes portable.

  `try_xy_cut_split` runs *before* the projection histogram and asks a
  simpler question: is there one clean vertical cut with everything on either
  side of it? A page with a wide sidebar answers yes where a histogram,
  dominated by the body column, often does not.
  - The sweep tracks the furthest right edge seen **so far**, not the
    previous item's. A full-width banner therefore *suppresses* the cut
    entirely rather than leaving a false gap behind it — the opposite of what
    the obvious implementation would do, and worth a test of its own.
  - The cut lands midway between the two blocks, so a cut reaching the page
    margin means the blocks sit close together near an edge, not far apart.
    Two unit tests were wrong on exactly this before the reference corrected
    them.
  - Overlapping items give a negative gap and the running best starts at
    zero, so they can never win.

  **A deliberate divergence, and the first crash found in the reference.**
  `try_xy_cut_split` indexes `0..len - 1`, which underflows on an empty item
  list. Running the reference binary on that case kills it outright —
  `index out of bounds: the len is 0 but the index is 0` at `layout.rs:272`.
  Its own caller returns early for any page under twenty items, so the case
  is unreachable through the real entry point; this port guards instead. The
  probe case is deliberately not generated, with a comment saying why.

  `is_newspaper_layout` decides whether the columns are independent flows.
  Three routes to yes: dense columns of similar length; a narrow sparse
  sidebar beside a dense body, behind six simultaneous guards; or, for
  unequal columns, the shortest one's lines mostly colliding with another's.
  Note `min_by_key` returns the **first** minimum where `max_by_key` returns
  the last — the opposite of wave 63's trap, and the reason both are spelled
  out explicitly.

  851 probe cases agree on the first run. 17 unit tests.

- **Wave 65 — `detect_columns`, the assembly.**
  `PdfDetectColumns.swift` ports the function waves 61–64 were built for. It
  projects the page's text onto its x axis and tries three routes in order of
  how much each assumes: absolute valleys the text genuinely avoids; relative
  valleys, for justified text that fills its own gutter; and the XY cut, for
  the sidebar a body-dominated histogram cannot see. Every route can decline,
  and the page then comes back as one full-width column.
  - Items over 60% of the page width are left out of the histogram. Without
    that a title bridges the gutter and hides it, which is what would stop a
    two-column abstract being found under a heading.
  - The noise threshold is 15% of the busiest bin, **truncated** — so a page
    whose busiest bin holds six items needs a genuinely empty gutter.
  - Stray items in a gutter do two different things depending on shape:
    enough of them *inside* it become their own narrow column, while enough
    *bridging* it close the gutter entirely. Both are now pinned.
  - The relative route needs 100 items and no detected table, and its result
    must additionally read as prose — a relative valley is weaker evidence
    than an absolute one and has to be corroborated.
  - The regions span the *text's* extent, not the page's, so the margins fall
    outside the first and last column.

  1,043 probe cases agree on the first run, 105 of them for `detect_columns`
  across all five outcomes (0–4 columns). Route instrumentation drove three
  rounds of case design: the relative route fired 0 times at first, then 17
  once the columns were made to touch with jagged edges; its prose rejection
  needed touching cells crossed by a minority of rows.

  **Two branches the probe does not reach, recorded rather than claimed.**
  The edge-based fallback cannot be triggered: edge assignment gives each
  side a subset of what centre assignment gives, so counts only shrink and
  extents only narrow — neither turns a refusal into an acceptance. The only
  gate that could flip is the list-marker check, and only for marker items
  wide enough to straddle a gutter, which no real page produces. The XY cut
  *inside* the relative branch looks outright unreachable: arriving there
  means no run of empty bins clears the margins, while the XY cut needs a
  15pt gap nothing spans — which would produce exactly such a run. Both are
  left in place, being the reference's, with the reasoning at the call site.

  `PdfLayout.swift` has dropped the multi-column caveat it carried since
  wave 4. What remains is wiring the regions into line grouping.

- **Wave 66 — one column's runs into lines.**
  `PdfSingleColumn.swift` ports `group_single_column` and
  `should_use_y_sorting`, the grouper the region pipeline calls per column.

  Wave 4's grouper sorted every run by baseline and trusted the result. This
  one does not: a PDF's stream order is usually already reading order, and
  sorting destroys information when two runs share a baseline. So stream
  order is kept unless it looks *chaotic* — more than two in five large
  vertical jumps going the wrong way — and the grouping then walks it in
  sequence, merging only ever into the line most recently opened.
  - That one-line lookback is why the merge tests are thorough. A run
    returning to an earlier baseline opens a new line rather than rejoining
    the old one.
  - The tolerance is measured against the line's **own** baseline, its first
    run's, which never moves. Drift therefore accumulates against a fixed
    point: a 1pt drift per run is fine for three runs and breaks at the
    fourth.
  - The subtlest test splits two columns whose gutter was too narrow for
    column detection. Same baseline, a void wider than three font sizes or
    30pt, and the incoming run starting with a letter — then **both sides
    must read as prose**, at three words and ten letters in, two words and
    eight already on the line. Word count alone is not enough: `abc def ghi`
    is three words and nine letters and stays joined.
  - An uppercase start additionally needs a style mismatch — a wholly bold
    line beside a regular run — or rows of same-styled labels would shatter.
    The *whole* line must be bold, so a bold-label-and-value row survives.
  - The void uses the **raw** width, not the estimate used elsewhere, so a
    run with no measured width is treated as a point and the void reads as
    wider.

  1,138 probe cases agree on the first run. Branch instrumentation lifted
  carriage returns 2→14 and style-mismatch splits 1→4. 17 unit tests, two of
  which the reference corrected: cumulative drift against a fixed baseline,
  and the ten-letter bar.

- **Wave 67 — the leaves of image-anchored reading order.**
  `PdfReadingOrder.swift` ports `page_x_bounds`, `group_rows`,
  `side_is_prose` and `aligned_row_split` from
  `extractor/reading_order.rs`.

  Column detection asks one question of the whole page, which fails where the
  flow changes partway down — two columns beside a figure, then full-width
  text below it. The whole-page projection sees both shapes at once and
  resolves neither. Reading order answers locally instead, by finding rows
  that *individually* look like two columns; these four are what that is
  built from.
  - `group_rows` keeps its baseline as a **running mean**, recomputed each
    time a run joins. The tolerance is therefore measured against a moving
    point, and the mean lags: eight runs rising half a point each span 3.5pt
    in total — past the 3pt tolerance — and still form one row. The line
    grouper of wave 66 measures against a *fixed* first baseline and would
    not allow that. The tolerance here is also inclusive where wave 66's is
    strict.
  - `side_is_prose` takes ten CJK characters as standing in for three words,
    since Japanese and Chinese are set without spaces and a whole sentence
    would otherwise count as one word.
  - `aligned_row_split` recomputes both sides from the **whole row** against
    each candidate split rather than taking the adjacent pair, so a row of
    four runs splitting two-and-two is judged on all four. The widest
    qualifying gap wins, and `max_by` keeps the last maximum — the same tie
    direction as wave 63.
  - `page_x_bounds` consults both corners of an image for each end, so a
    region written right to left measures the same as one written left to
    right; an empty page folds to infinities that the finite check rejects
    rather than propagating.

  126 probe cases agree on the first run, with both verdicts represented for
  all four functions. 19 unit tests, one corrected by the reference: the
  moving mean buys extra reach but not unlimited reach.

  **Remaining in `reading_order.rs`:** `local_flow_below_full_width_image`,
  `paired_column_images`, `infer_image_anchored_flow` and
  `build_region_graph` — about 450 lines, a wave of their own. After those,
  `group_into_lines_with_thresholds_and_regions_impl` closes the layout half
  of the pipeline.

- **Wave 68 — two columns beneath a hero image.**
  `pdfLocalFlowBelowFullWidthImage` joins `PdfReadingOrder.swift`, built
  entirely on wave 67's leaves.

  The shape it recognises is narrow on purpose. A local column flow below an
  image is unambiguous only for **one** nearly square figure: a wide report
  banner or full-page artwork frequently sits above unrelated page furniture
  whose aligned labels mimic prose columns perfectly well.
  - Exactly one image may qualify as full-width (0.65 of the page and 60pt
    tall). A second one disqualifies the page rather than being ignored — and
    so does an image between the 0.65 counting bar and the 0.85 anchor bar.
  - The anchor must be near-square: its height between 0.85× and 1.2× its
    width, measured against itself rather than the page.
  - Only the 220 points below the image are searched, four rows must agree on
    the split to within 20pt, the band must sit 60–120pt below the image, and
    it must be no more than 130pt tall.
  - The clustering places each row in the **first** cluster whose running
    mean is close enough, and that mean then moves — so the result depends on
    the order rows were found in. `max_by_key` keeps the last maximum, the
    same tie direction as waves 63 and 67.

  180 probe cases agree on the first run, 19 producing a band and 35 refusing.
  27 unit tests. Four expectations were wrong and the reference supplied the
  exact boundaries: the caption gap is 60–120pt measured to the *padded* top,
  the band height limit lands between 24pt and 25pt of row spacing, and the
  aspect window is 434–612pt of height for a 510pt-wide anchor.

- **Wave 69 — pages built from paired panels.**
  `pdfPairedColumnImages` joins `PdfReadingOrder.swift`. Where wave 68 reads
  a caption beneath one hero image, this recognises a page *built* from
  stacked figures either side of a split — a catalogue or photo essay, where
  the images mark the columns and the text fills around them.
  - The demanding test is the **vertical stack**. Three logos in a row across
    a header would otherwise satisfy the image count and send an ordinary
    asymmetric page through sequential column order, so at least one pair on
    the same side must sit one above the other: centres at least half the
    shorter panel apart, and a vertical gap at most half the taller one —
    inclusive at exactly half, which the tests pin at 75pt.
  - An image straddling the split belongs to neither column and is dropped
    rather than assigned, so it cannot make up the count.
  - Only **column-confined** text sets the band's lower extent. A spanning
    heading below the columns has to become the trailing full-width node
    rather than stretching the band to the page foot; a page whose text all
    straddles the split therefore has no finite bottom and is refused.
  - The columns must be **unbalanced** — under 0.55 by row count, both sides
    at five rows minimum. Evenly matched columns are ordinary two-column
    text, which the histogram already handles.

  236 probe cases agree on the first run. The generated cases were starved at
  first — 2 bands in 56 — because the baseline shape had four rows on the
  side where five is the floor; fixed, it reaches 16 bands in 56.

  **Gates that mask each other, recorded rather than asserted:** several
  constants cannot be isolated at a 600pt page. `MIN_IMAGE_WIDTH` (60pt) is
  always dominated by the 35%-of-page wide-panel bar (210pt), since three of
  *each* kind are required; and `MIN_IMAGE_HEIGHT` (40pt) is dominated by the
  vertical-stack gap bound, which fires first on any shape short enough to
  test it. The unit tests assert the bar that actually decides and say so.

- **Wave 70 — `reading_order.rs` complete.**
  `pdfInferImageAnchoredFlow` and `pdfBuildRegionGraph` finish the file that
  waves 67–69 were building. All eight of its functions are now ported.

  The inference is a two-step fallback: a split already found by column
  detection lets the paired-panel recogniser look either side of it, and
  failing that — or with no split at all — the hero-image recogniser tries.
  **The paired path is only reachable when a split was detected**, so a page
  whose columns the histogram could not find is judged solely on its hero
  image.

  `build_region_graph` partitions the page into `above → left → right →
  below`. An ordered list rather than a real DAG is enough because the shape
  is always this one: the band is a horizontal slice, so nothing can sit
  beside the material above or below it.
  - Empty regions are dropped, so a page with nothing above its band starts
    at the left column and callers never see a placeholder.
  - Direction comes from the **columns only**, ignoring the full-width
    material — a right-to-left page reads its right column first.
  - Both band comparisons are strict, so a run exactly on the top or bottom
    edge is column material rather than full-width.

  256 probe cases agree on the first run. The probe initially emitted only
  node *counts*, which cannot tell a right-to-left page from a left-to-right
  one — both give `f:1 c:5 c:5`. It now emits each node's first x as well,
  and the two orders are distinguishable: `c:5@280 c:5@55` against
  `c:5@55 c:5@280`.

  Two case-design corrections along the way: the region-graph pages had their
  columns 17pt below the image where the caption gap wants 60–120, and the
  Arabic test text had two words where the prose bar wants three — Arabic
  gets no CJK exemption, since that is keyed on the CJK blocks rather than on
  scripts written without spaces generally.

  **Next:** `group_into_lines_with_thresholds_and_regions_impl` in
  `layout.rs` now has every dependency ported, and closes the layout half of
  the pipeline.

- **Wave 71 — the layout assembly.**
  `PdfGroupLines.swift` ports
  `group_into_lines_with_thresholds_and_regions_impl`. Everything waves 61–70
  built is wired together here: given a page's items it decides the columns,
  checks whether the images imply a local flow, files each item into a
  column, groups each column into lines, and emits reading order.

  The reference loops over pages and looks per-page parameters up in maps;
  this port takes one page's items and those parameters directly, which is
  the same thing with the loop lifted out.
  - **Two orderings, chosen by `is_newspaper_layout`.** Tabular interleaves
    the columns by baseline and merges same-baseline lines into one; a
    newspaper emits whole columns in turn. The same page shape produces
    completely different output depending on which fires.
  - Items are filed by greatest horizontal **overlap** rather than by centre
    point, which is what stops an item leaning into the gutter being
    misfiled.
  - A straggler *above* the columns joins the shared material; one *below*
    stays with its column, since sorting it back by baseline would
    re-interleave the flows the ordering exists to separate.
  - Chart regions blind the histogram to chart-internal text only — two
    points of slack, and measured on the **raw** width. A page with any chart
    also skips the image-anchored path entirely.

  336 probe cases agree on the first run, 80 of them for the assembly — which
  is the whole stack composed, so a divergence anywhere beneath would surface
  here. Path instrumentation drove three rounds: the spanning-line branches
  of the newspaper ordering fired **zero** times until the cases used dense
  *balanced* columns, since an unbalanced page reads as tabular.

  **A harness lesson worth keeping.** The first attempt put the new probe arm
  in `probe_reading` while the cases went to the valleys file, so the arm was
  never reached and the answer file was silently empty. Before that, the case
  text came out as `<function valley_cases.<locals>.prose>` — a name
  collision with a local in the generator — which was still valid input but
  exercised none of the prose-dependent branches. Both were caught by
  checking output *shape* rather than trusting a passing comparison.

- **Wave 72 — completing heading detection.**
  The first wave to *fix* an existing port rather than add new surface.
  `pdfHeadingTiers` and `pdfHeadingLevel` were written in wave 5 as
  simplifications of `compute_heading_tiers` and `detect_header_level`, and
  the probe found three branches missing outright:
  - **The bold sub-gate.** A bold line between 1.05 and 1.2 times body size
    is checked against the tiers *before* the ratio gate. Tiers that low only
    exist because of the bold fallback below, and honouring them for non-bold
    text at the same size would promote every caption.
  - **The bold tier fallback.** When nothing clears the 1.2 gate at all, bold
    lines from 1.05 up supply the tiers. Books set section headings 11pt bold
    over 10pt body, and without this every heading in such a document
    defaults to H2.
  - **The no-tiers ratio fallback.** With no tiers discovered, the ratio
    decides alone — and never returns nothing. Past the gate, everything is a
    heading of some level. The old port returned `nil` for a 1.3 ratio where
    the reference gives H3.

  Also added: the four-tier cap, and `pdfLineIsMostlyBold`, which measures
  boldness by **character mass** so a heading with an unbold `4. ` prefix
  still counts as bold. The caller in `PdfMarkdown.swift` now threads it.

  **My own defensive guards were the divergence.** I added `bodySize > 0`
  checks to both functions; the reference has neither and relies on float
  division giving infinity — every line then clears the ratio gate rather
  than the document producing no tiers. The probe caught both immediately.
  A zero *font* size gives NaN, and since every NaN comparison is false the
  gate is passed and the fallback returns 4.

  268 probe cases agree once the guards came out. 17 unit tests; two
  expectations were wrong in instructive ways — tiers closer than half a
  point are indistinguishable, so a 10.6pt line matches an 11pt tier; and a
  size exactly half a point outside every tier is placed *after* the tiers
  rather than rejected, so a tenth of a point turns H2 into H4.

- **Wave 73 — the heading vetoes.**
  `PdfHeadingFragment.swift` ports `is_toc_entry_line`,
  `is_toc_marker_heading` and `is_heading_fragment` from
  `markdown/analysis.rs`.

  A table-of-contents entry and a display equation are both short, both sit
  alone on a line, and both are often set larger or bolder than body text, so
  the size heuristics promote them to headings. These three are the veto:
  each recognises a shape that cannot be a heading however it is typeset.
  - `is_toc_entry_line` catches what `has_dot_leaders` misses. That one wants
    **two** groups of dots and so passes over a single-group leader; a
    trailing run of dots followed by a one-to-four-digit number is strong
    enough evidence on its own.
  - `is_heading_fragment`'s equation-suffix rule is deliberately hard to
    satisfy: a trailing `(N)` alone is not enough, because real headings end
    with parenthesised numbers too — `Nicaea (325)`, appendix numbering. It
    needs a comma or colon immediately before, or a mathematical operator
    somewhere in the line.
  - It also recognises a page-of-total running header — `LIVSMEDELSVERKET PM
    2 (10)` — by the pair reading as a plausible page and total, with no
    maths anywhere.
  - The suffix rule splits on the **space character**, not on whitespace, so
    a tab before the equation number leaves it inside one token and the whole
    branch is missed. Pinned by a test, since it looks like an oversight and
    is reproduced deliberately.

  **Audit, following wave 72:** `has_dot_leaders` was checked against the
  reference and needed no change — `pdfHasDotLeaders` from wave 5 is
  faithful. 400 probe cases agree on the first run across all four
  predicates, each with both verdicts represented. 16 unit tests, all
  passing first try.

- **Wave 74 — font statistics, and two more corrections.**
  `PdfFontStats.swift` ports `FontStats`, both `calculate_font_stats`
  variants, `font_size_rarity` and `bold_heading_level`. Everything the
  heading detector decides rests on knowing which size is the body.

  **`pdfBodyFontSize` diverged in four ways** and has been rewritten to call
  the ported statistics:
  - it weighted every *item* by character count, where the reference casts
    **one vote per line** from its first item — which is what stops a page of
    short captions outvoting its body text;
  - it had no nine-point floor, so footnotes and superscripts could claim the
    majority on a densely annotated page;
  - it bucketed by **rounding** where the reference truncates, so 12.19 was
    grouped with 12.2 rather than with 12.11;
  - it fell back to 0 where the reference falls back to 12.

  **`pdfParagraphThreshold` diverged once:** the reference only measures gaps
  between lines on the **same page**, which this port could not express
  because `PdfTextLine` had no page. Added, stamped by `pdfGroupPageIntoLines`
  and used here. Usually the cross-page gap is negative and filtered anyway —
  the check only bites when the pages differ in height — but the probe now
  covers that case explicitly.

  531 probe cases agree on the first run, including the truncation buckets,
  the tie-to-the-smaller-size rule, and the page-boundary gaps. 11 unit
  tests.

  **Running tally of the audit habit (waves 72–74):** five functions checked,
  three found diverging (`detect_header_level`, `compute_heading_tiers`,
  `calculate_font_stats` via `pdfBodyFontSize`), one found diverging in a
  narrow case (`compute_paragraph_threshold`), one confirmed faithful
  (`has_dot_leaders`). The name-based coverage estimate cannot see any of
  this: it counts a wrong port and a right one alike.

- **Wave 75 — auditing the markdown cleanup.**
  `PdfPostprocess.swift` audited against `markdown/postprocess.rs`. **No
  divergence found** — the wave-5 port is faithful.

  The eight helpers already had a differential probe from wave 5, driven by
  a separate oracle. What this wave adds is the piece that probe skipped:
  `clean_markdown` itself, whose ordering, `\n\n\n` collapsing and final trim
  are behaviour of the composition rather than of any helper. Plus a second,
  differently-shaped corpus over the helpers, since two corpora reach
  branches one does not.

  1,130 cases agree on the first run, 222 of them the composed pass in both
  profiles.

  **Audit tally, waves 72–75:** six files or clusters checked. Four diverged
  (`detect_header_level`, `compute_heading_tiers`, `calculate_font_stats` via
  `pdfBodyFontSize`, `compute_paragraph_threshold`); two were clean
  (`has_dot_leaders`, all of `postprocess.rs`). The pattern so far: functions
  ported as *simplifications* diverge, and functions ported *verbatim against
  a probe* do not — which is an argument for the probe-first discipline
  rather than for suspicion of old code as such.

  **A note on redundancy.** Discovering the wave-5 probe only after building
  a second one cost some duplicated effort. Both are kept: the corpora differ
  and the overlap is cheap, but `PLAN.md` should be checked for existing
  probe coverage before a new audit is designed.

- **Wave 76 — section numbering.**
  `PdfNumbering.swift` ports `roman_value`, `parse_numbering`,
  `has_additional_decimal_numbering` and `numbering_forms_hierarchy` from
  `markdown/heading.rs` — the first of the three signals `PdfMarkdown.swift`
  records as missing. The sequence logic that consumes them is still not
  ported.

  A numbered line is evidence of a heading independent of its typography:
  `2.1 Method` is a heading whatever size it is set at.
  - Roman numerals use **only `I V X L C`** — not `D` or `M`. Section
    numbering does not reach five hundred, and admitting those letters would
    read `DOC` and `MIX` as numbers. Eight characters is the ceiling for the
    same reason.
  - The subtraction rule is loose: a character is subtracted whenever the
    *next* is larger, so `IIX` yields 1 − 1 + 10 = **10** rather than being
    rejected. Reproduced and pinned.
  - A number must carry a `.`, `)` or `:` — a bare `2` is a page number or a
    quantity far more often than a section — and every trailing delimiter is
    stripped, so `1...` and `1.` parse alike.
  - Each decimal part is at most **three** digits, and a longer one fails the
    whole token rather than truncating it, which keeps a year out of the
    numbering.
  - Decimal is tried before roman, so `1.1` is decimal and `I.` is roman.
  - `has_additional_decimal_numbering` skips the first word, so a heading's
    own number never counts as a reference to another section.

  352 probe cases agree on the first run. 18 unit tests; one expectation was
  wrong — I worked `IIX` out as 8 by hand where the rule gives 10, which the
  probe had already covered.

- **Wave 77 — does this line read as a title?**
  `PdfTitleLike.swift` ports `title_like` and `complete_sidebar_label` from
  `markdown/heading.rs` — the second of the three signals `PdfMarkdown.swift`
  records as missing. Where wave 76 asked whether a line is *numbered*, these
  ask whether it looks like a heading at all, which is what lets a bold line
  at body size be promoted.
  - Length bounds first (one to twelve words, four to a hundred and forty
    characters), then wave 73's vetoes, then capitalisation — with **numbered
    or bold standing in** for capitalisation entirely.
  - A numbered line is let through the list veto on purpose: telling a
    section run from an ordinary ordered list belongs to the sequence logic,
    not to this predicate.
  - `complete_sidebar_label` refuses a trailing hyphen or a dangling
    preposition, since either means the label continues on another line, and
    refuses a one-letter-plus-number pair like `G 02` as a navigation code.

  509 probe cases agree on the first run. 12 unit tests. Two expectations
  were wrong for the same reason and it is worth recording: a short
  *lowercase* line is caught by wave 73's fragment rule long before the
  length bounds are reached, so isolating a bound needs capitalised text.
  The predicates compose more tightly than they read.

- **Wave 78 — a line's visual identity.**
  `PdfVisualStyle.swift` ports `dominant_font`, `dominant_font_size`,
  `document_body_font`, `document_body_x_bucket` and `visual_style` from
  `markdown/heading.rs`. This is the **third and last** of the signals
  `PdfMarkdown.swift` has recorded as missing since wave 5.

  Size says how big a line is and numbering says where it sits; this says
  what it *looks like*, so a run of lines sharing a font, an indent and a
  weight can be recognised as one heading level even when none of them is
  larger than the body.

  **Every one is a weighted vote, and the tie-breaks are not uniform.** Two
  prefer the smaller key and one the larger:
  - `dominant_font` and `document_body_font` break ties toward the
    lexicographically **smaller** name;
  - `document_body_x_bucket` toward the **smaller** bucket, the leftmost
    indent;
  - `dominant_font_size` toward the **larger** size — between two equally
    weighted sizes the heading is the bigger one.

  Three more asymmetries, all deliberate:
  - `dominant_font` gives every run a weight of at least one, so a line of
    empty runs still has a font; `document_body_font` does not, so an empty
    run contributes nothing to the document-level vote.
  - Sizes are **rounded** to a tenth here, where wave 74's font statistics
    **truncate**. Different function, different rule.
  - `visual_style` takes its indent from the **first** run rather than the
    dominant one: where a line starts is what the eye reads as its indent.

  699 probe cases agree on the first run, 190 of them for these five. 14 unit
  tests, all passing first try.

  **All three deferred signals are now ported** — numbering (76),
  title-likeness (77) and visual style (78). What remains of
  `markdown/heading.rs` is the sequence logic that consumes them:
  `sequence_level`, `has_displaced_baseline_peer`,
  `numbering_has_section_separation` and the assembly around them.

- **Wave 79 — the sequence leaves.**
  `PdfHeadingSequence.swift` ports `has_displaced_baseline_peer`,
  `numbering_has_section_separation` and `sequence_level`. Waves 76–78 built
  the three signals; these decide when a *run* of lines sharing one is really
  a heading level, and what level to give it.
  - `has_displaced_baseline_peer` looks for the peer **twice**: as a wide
    void inside the line's own runs, since the grouper may already have
    merged the columns, and as a separate line at the same baseline with a
    displaced indent. 24pt is the bar for both, and the run widths are
    floored at zero so a bad width cannot reach backwards and manufacture a
    gap.
  - `numbering_has_section_separation` needs **two intervening lines** or a
    page boundary. A compact `1.` / `1.1.` run is an ordered list far more
    often than a document hierarchy, because genuine section headings have
    body content between them.
  - `sequence_level` lets numbering win outright — its depth *is* the level,
    clamped to the six Markdown offers — and otherwise falls back to size.
    Note the fallback never refuses: a line that size rejects still becomes a
    heading via `pdfBoldHeadingLevel`, which is what admits a bold section
    heading set at exactly body size.

  796 probe cases agree on the first run. 13 unit tests; one expectation was
  wrong — I built a "negative width" case whose gap cleared the bar anyway,
  so it demonstrated nothing until narrowed to where the flooring decides.

  **Remaining in `markdown/heading.rs`:** `classify_heading_sequences`, the
  ~176-line assembly that consumes all of the above.

- **Wave 80 — the heading assembly.**
  `PdfHeadingClassify.swift` ports `classify_heading_sequences`, the heading
  half's assembly and the counterpart to wave 71's layout one. Waves 76–79
  built the signals and the tests; this composes them into the question that
  matters: which lines does a *repetition* prove are headings?

  Repetition alone is weak evidence — captions, author lists and table rows
  repeat too. A group sharing a visual style is promoted only on one of two
  much stronger findings:
  - a **numbered hierarchy** running through it, where the numbering is
    itself set apart (1.05× the body size, or a bold face the body does not
    use) and the members are far enough apart to be sections rather than list
    items; or
  - a **displaced sidebar**, which must clear six guards at once: a distinct
    bold face, a document not already dense with candidates, either varied
    sizes or several complete distinct labels, one page, four lines between
    entries, an indent four buckets from the body's, and type under 0.95× the
    body.

  A hierarchy promotes only the lines that took part in it; a sidebar
  promotes its whole group.

  **The reference's `isolated_lines` parameter is used only in a trace log**
  and never consulted. It is omitted here rather than carried unused.

  860 probe cases agree on the first run, 64 of them for the assembly — 35
  promoting and 29 declining. 13 unit tests. One expectation was wrong for
  the same reason as wave 77's: the two ways numbering can be "set apart"
  are alternatives, so isolating the *size* bar means setting the headings in
  the body's own font, or the distinct face carries them at any size.

  **`markdown/heading.rs` is now ported** apart from the wiring that calls
  `classify_heading_sequences` from `markdown/mod.rs`.

- **Wave 81 — which text belongs to a chart.**
  `PdfChartRegions.swift` ports `is_chart_adjacent_label`,
  `item_is_in_chart_region` and `items_outside_chart_regions` from
  `markdown/mod.rs`. A chart's axis labels and caption are text like any
  other, and left in the flow they read as fragments scattered through the
  prose.
  - A run qualifies as a label **three ways, any one sufficing**: it is
    compact in its own right (18.5 ems wide), it is a caption, or it sits
    mostly within the chart's width, close to its edge, and is narrow
    relative to the chart. Bare bullets and list items never qualify however
    close they fall.
  - Membership is decided by the run's **centre** horizontally, and
    vertically has two routes: inside the box outright, which needs no
    further argument, or within the 20pt pad *and* passing the label test.
  - `PdfLayoutItem` gained a `height`, which nothing sets yet — the readers
    take `max(height, fontSize)`, which is the font size until the extractor
    records one.

  160 probe cases agree on the first run. 13 unit tests, and **five
  expectations were wrong for one reason**: the three qualifying routes are
  alternatives, so a test aiming at one was carried by another. Isolating the
  compact bar needs a gap outside the category band; isolating the overlap
  needs a run too wide to be compact. This is the fourth wave running where
  testing one condition required defeating its siblings — it is now the
  default assumption when writing these.

- **Wave 82 — prose columns on a chart page.**
  `PdfChartProse.swift` ports `chart_page_prose_column_split`,
  `chart_spans_prose_split`, `is_cross_row_prose_continuation`,
  `looks_like_numbered_section_heading` and `merged_retry_skips_body_font`.

  A page carrying both charts and two columns of prose defeats the
  projection histogram of wave 65: the charts fill the gutter, so the page
  reads as one column. These infer the gutter from the **prose alone** — only
  runs of four words, 80pt wide and more than half alphabetic vote, so axis
  labels cannot form a column — and then ask whether each chart genuinely
  crosses it. A chart confined to one column must stay in that column's local
  order rather than reordering the page.
  - Exactly two left-edge clusters must emerge, at least 120pt apart, each
    running 60pt tall, and **overlapping vertically by two fifths of the
    shorter**. That last is what separates side-by-side columns from a column
    and the caption beneath it.
  - Cluster anchors are running means, so a column whose left edge drifts
    still holds together.
  - `is_cross_row_prose_continuation` strips closing quotes and brackets
    before judging whether the previous row ended open, since `…said."` is
    closed by its full stop. A row of nothing but closers is not open.

  458 probe cases agree on the first run across both new modes. 17 unit
  tests, **all passing first try** — the first wave in five where none of my
  expectations were wrong, because every boundary was read off the reference
  before the assertion was written rather than after it failed.

- **Wave 83 — two tables or one?**
  `PdfSideBySide.swift` ports `split_side_by_side`. Two independent tables
  set beside each other look, to a column detector, exactly like one wide
  table with a big inner gap — and getting it wrong either way is bad:
  reading two as one interleaves their rows, reading one as two splits every
  row in half.

  So the test is deliberately hard to satisfy. A candidate gap must be wide,
  central and balanced; crossed by almost nothing; the **only** such gap on
  the page; and the two sides must not read as a label column beside a figure
  column.
  - Balance is counted by the runs' **centres**, not their left edges.
  - The crossing budget is a twentieth of the page, floored at two — which is
    what admits a spanning header or two without admitting a wide table's
    own rows.
  - The label-and-figures refusal needs **all three** signs: under 30%
    numeric on the left, at least 70% on the right, and half the right's runs
    sharing a baseline with a left one. Offsetting the figures by five points
    breaks the third and the page splits again.

  224 probe cases agree on the first run. 8 unit tests, all passing first
  try. One case-design correction along the way: my "gap width" sweep was
  really measuring *crossings* — bringing the tables together makes the left
  table's own runs cross the midpoint long before the gap itself becomes too
  narrow. The test now says so.

- **Wave 84 — bold paragraphs that are not headings.**
  `PdfWrappedBold.swift` ports `starts_with_section_number` (the
  `convert.rs` one), `is_body_size_all_bold_line`,
  `is_wrapped_same_style_line`, `find_wrapped_bold_paragraph_lines` and
  `struct_role_heading_level`.

  Wave 72 made a bold line at body size eligible to be a heading — right for
  a section title, wrong for a bold *paragraph*: a pull quote, a warning, an
  abstract. The difference is length, and the bar is **three lines and more
  than twenty words**: a bold heading may wrap once, and may be long, but not
  both. What this finds becomes the excluded set for wave 80's
  `classify_heading_sequences`, so those lines cannot support another line's
  candidacy either.

  **The reference has two different functions called
  `starts_with_section_number`**, in `tables/detect_heuristic.rs` and
  `markdown/convert.rs`. The first was already ported in an earlier wave and
  asks only whether the leading token is a dotted number, so `1.2` satisfies
  it; the second additionally requires whitespace and an alphabetic title,
  so `1.2` does not. Ported as `pdfStartsWithSectionNumberAndTitle`, with a
  test asserting the two disagree — the collision surfaced only because Swift
  refused the redeclaration.

  78 probe cases agree on the first run. 16 unit tests, all passing first
  try — third wave running.

- **Wave 85 — what the tags claim, and what the white space says.**
  `PdfIsolatedLines.swift` ports `resolve_line_struct_role`,
  `detect_overused_struct_heading_levels` and `find_isolated_lines`.

  Two pre-scans that answer the same question from opposite ends. A tagged
  PDF declares its headings, and where the tags are honest they beat every
  geometric guess — but a tagger that marks every numbered paragraph as H2
  is worse than no tags at all, so any level above **15%** of the document's
  tagged lines is suppressed wholesale. An untagged PDF declares nothing, and
  a section title set at body size is invisible to the size heuristics; what
  gives it away is the white space around it — one to six words, a paragraph
  break above and below.

  Boundaries pinned: the twenty-line floor under the overuse ratio (below it
  a single heading is already a large share); the ratio itself, exclusive, so
  6 of 40 survives and 7 does not; the 95%-of-body size floor; the strictly-
  greater paragraph gap; and the density guard, which drops a page's isolated
  lines when more than a quarter of a **ten-line-or-longer** page qualifies —
  the signature of a two-column page read as one. The guard is per page, so a
  dense page loses its lines while a sparse one beside it keeps them.

  Three findings. The reference's doc comment says the overuse bar is 25%
  while its code says 15%. Its `len() <= 3` floor is **bytes**, so `éé`
  clears a bar that `a b` does not — a port measuring `String.count` would
  disagree. And `B.3 Prompt Engineering`, named in the reference's own doc
  comment as an example of what isolation exists to find, is rejected by its
  `is_list_item` gate, which reads any letter followed by a dot as a lettered
  list marker; every appendix heading goes the same way. All three
  reproduced, the last with a test asserting it.

  **A harness bug that the probe could not have caught.** The case format
  spells a line as `page,y,x,size,mcid,text` and split on every comma, so a
  case ending its text on one silently tested a line ending on `g` instead.
  Both sides parsed identically, so the comparison agreed — and agreed about
  the wrong input. Found by reading the answer *shape*: `-` and `;` were
  rejected while `,` between them was not. Fixed by rejoining the tail, in
  wave 84's probe as well, which had the same latent split and no comma in
  its cases to trip it.

  191 probe cases agree on the first run once the harness was fixed. 22 unit
  tests, all passing first try — fourth wave running.

- **Wave 86 — the same run, the opposite verdict.**
  `PdfMergeBoldHeadings.swift` ports `merge_wrapped_bold_heading_groups` and
  `count_table_columns`.

  Wave 84 found the bold runs *too long* to be headings and suppressed them;
  this is the identical run scan reaching the opposite conclusion. Two or
  three bold lines totalling fifteen words or fewer are one heading that
  wrapped, and merging them is what stops the writer emitting a stack of
  `##`. Between the two functions every body-size bold run is accounted for:
  merge at two or three short lines, suppress at three or more long ones,
  leave alone in between. A single bold line is neither.

  The isolation test here is **column-local**, and deliberately ignores array
  order: on an interleaved multi-column page the neighbouring entries belong
  to the other column, so instead of looking at index ±1 it asks whether any
  line anywhere on the page falls within the paragraph gap *and* overlaps the
  group's x-range. Overlap is strict at both edges, so a neighbour starting
  exactly where the group ends is clear of it; the gap is inclusive, so one
  exactly a threshold away blocks. A section number overrides isolation
  entirely — but not the length gates, and not with a single component, since
  this is the `convert.rs` spelling where `1.` is an ordered list item.

  `count_table_columns` reads the **separator row alone**, so a table whose
  header and separator disagree reports the separator's width, and a second
  line carrying `---` but no pipes counts zero.

  Note that merging renumbers the lines, which invalidates every index set
  computed against the input — wave 85's isolation set and wave 84's
  suppression set both. Recorded at the call site for the assembly wave.

  **The delimiter audit.** Wave 85's harness bug prompted a sweep of all
  eleven case files with variable-width comma tokens, checking for the same
  shape: a fixed-field spec whose last field is free text. One more turned
  up — the chart probe, whose cases carry `1,234.56` as a label, exactly the
  formatted number that probe exists to classify. The text field was reading
  `1`. Fixed; the reference answers did not change, because the side-by-side
  banding those cases drive reads geometry and never looks at the text. A
  real format flaw with no consequence for what it was carrying.

  121 probe cases agree on the first run. 12 unit tests, all passing first
  try — fifth wave running.

- **Wave 87 — where a table goes on a chart page.**
  `PdfPositionedBlocks.swift` ports `ChartProseOrder`, `PositionedMarkdown`,
  `chart_stream_position`, `positioned_block_precedes_line`,
  `compare_positioned_blocks` and `positioned_blocks_for_page`.

  Tables and images are lifted out before the text is grouped into lines and
  have to be put back afterwards. On an ordinary page that is baseline order.
  On a page where a full-width chart cuts between two prose columns it is
  not — physical and reading order diverge, and a right-column table would be
  emitted ahead of the left-column prose it follows. The fix is to give every
  block the same logical stream coordinate the text uses: a `(zone, column)`
  pair compared lexicographically, where zone is above-chart, chart, then
  below-chart, and the band itself has no columns at all because a full-width
  chart spans both.

  Boundaries pinned: the band is padded by 8 points on each side and the test
  is inclusive, so 408 is still the band and 409 is above it; the column
  split is strict, so x 299 is left and 300 is right; being claimed by the
  chart overrides the geometry wherever the run sits; and a line with no
  items reads as x zero, which puts it in the left column.

  One inconsistency reproduced rather than repaired: the block comparator
  applies the stream ordering only when **both** blocks carry a chart order,
  and drops to the legacy tables-then-images ordering otherwise. On a mixed
  page that is not a consistent comparator — but a page either has a chart
  stream or it does not, so the mixed case does not arise.

  130 probe cases agree on the first run. 13 unit tests, all passing first
  try — sixth wave running.

- **Wave 88 — repairing the lines before anything is written.**
  `PdfPreprocess.swift` ports `effective_heading_level`,
  `merge_heading_lines`, `merge_drop_caps`, `normalize_whitespace`,
  `normalize_for_comparison`, `is_structural_line` and
  `is_decorative_separator` from `markdown/preprocess.rs`.
  `strip_repeated_lines` — the running-header remover, and the largest thing
  in that file — is left for the next wave.

  These run before any output, fixing lines the layout stage got right
  geometrically and wrong semantically: a wrapped heading is two lines and
  one heading, and a drop cap is a line of its own belonging to the front of
  another. This is the prerequisite for the assembly prologue in
  `to_markdown_from_lines_with_tables_and_images`, which calls both merges
  before it computes anything else.

  `merge_heading_lines` has two independent merge conditions. The ordinary
  one joins consecutive same-level headings within twice the font size and
  twenty words. The second exists because a bold heading at body size reaches
  no tier and would otherwise split into two output headings — it is narrow
  by design: both lines fully bold *and* tier-less, gap under 1.6× the font,
  continuation starting lowercase, no terminal punctuation before. The join
  is carried by a copied first item whose text gains a leading space, so the
  merged line reads as two words rather than one.

  `effective_heading_level` is **not** `resolve_line_struct_role`, though
  both walk the same map. This one does not skip container roles; it ignores
  every role that names no level and keeps looking. Two functions, one map,
  different questions.

  Findings: a drop cap that finds no home is **silently discarded** — the
  line is dropped whether or not a target was found, so a cap on a page whose
  paragraph starts uppercase loses its letter outright. And
  `is_decorative_separator` asks only whether every character matches the
  first, so `aaa` is a decorative separator and so is any single character.
  Both reproduced, both pinned by tests.

  **One wrong expectation, and the composition trap again.** The test for
  "a tiered heading must not absorb bold body text" passed both lines at the
  same size — where they reach the same tier and the *ordinary* path merges
  them. Isolating the second condition needs the sizes to differ so the
  levels disagree. Caught by the unit test rather than the probe, and fixed
  by querying the reference for both shapes.

  95 probe cases agree on the first run. 24 unit tests.

- **Wave 89 — the running-header remover.**
  `PdfStripRepeated.swift` ports `strip_repeated_lines`, the last thing in
  `markdown/preprocess.rs` and the largest single function in it.

  A header repeated on every page is noise once the document is one Markdown
  stream, and finding it is a frequency problem with many ways to go wrong: a
  table's column headings also repeat, a page number changes on every page,
  and a document title at the top of page one must survive. Six conditions
  hold together — enough distinct pages, ten bytes once normalised, not
  structural, near a page edge, consistent vertical position, not a rule —
  and lines sharing a baseline form **Y-bands**, so a column heading split
  into fragments too short to qualify individually is caught by its row's
  combined text, and removing any member removes the whole band.

  Boundaries pinned: the three-page floor; the frequency bar at 30% by
  *integer* division, so twenty pages need six occurrences and nineteen need
  five; the edge test at five distinct baselines from either end, with a page
  of ten or fewer counting as entirely margin — which is what lets a sparse
  cover page have its mid-page title stripped.

  **Two findings, both reproduced.**

  The structural exemption is tested against the *normalised* text, and
  normalisation strips leading digits. `1. Annual Report Section` arrives as
  `. Annual Report Section`, which no longer looks structural — so a repeated
  **numbered heading is stripped as a running header while a `#` or bullet
  heading is not**. Pinned by a test asserting the exemption holds before
  normalisation and fails after.

  "Keep the first occurrence" means first in *array* order, not lowest page:
  the reference records the page of whichever line it reaches first and never
  revises it. The band pass explicitly takes the minimum; the individual pass
  does not, and the two disagree. Fed pages in the order 3,1,2,4,5,6 the
  stripper keeps three copies; fed them backwards it strips nothing at all.
  The layout stage emits pages in order, so this does not bite in the
  pipeline — but the comment is only true for sorted input.

  123 probe cases agree on the first run. 13 unit tests, two of which had
  wrong expectations: `Report 2024` normalises to six bytes and falls under
  the length floor rather than being stripped, and the numbered-heading case
  above. Both corrected against the reference.

- **Wave 90 — what the writer knows before it writes.**
  `PdfAnalysis.swift` and `PdfMarkdownOptions.swift` port the opening third
  of `to_markdown_from_lines_with_tables_and_images`, plus `MarkdownOptions`
  and `MarkdownProfile`.

  The reference computes this state inline at the top of a six-hundred-line
  function before writing a character. Lifting it into a `PdfDocumentAnalysis`
  value is the same structural move `PdfGroupLines.swift` made with the
  per-page loop — same calls, same order, same results, state named rather
  than held in locals.

  **The ordering is the substance of the wave, and it is not obvious.** Font
  statistics are measured on the lines as they arrive; drop caps merge; the
  heading tiers are discovered from *those* lines; the heading merge uses the
  tiers; the paragraph threshold is measured after that merge; the bold merge
  uses the threshold; and every index-based set is computed last, against the
  final array.

  The drop-cap step earns its position. `compute_heading_tiers` has no
  minimum occupancy — one line clearing the 1.2× ratio gate defines a tier —
  so a 30pt cap over 10pt body would create a tier that exactly one glyph
  reaches. Verified both ways and pinned: `pdfHeadingTiers` on the unmerged
  lines returns `[30]`, and the prologue's tiers are empty.

  Two divergences, both deliberate. The reference gates the bold merge on a
  `PI_NO_MERGE` environment variable; reading the environment from inside a
  library is not something this port does, so the escape hatch is a
  parameter defaulting to the unset behaviour. And `classify_heading_sequences`
  takes an `isolated_lines` argument that it uses **only in a trace log** —
  wave 80 omitted it, which is confirmed correct here rather than assumed.

  **A weaker probe than usual, and worth saying so.** The prologue cannot be
  called on its own, so the oracle transcribes it verbatim from the reference
  and the comparison checks the port against a copy of the reference's
  ordering rather than against the reference itself. It is superseded once
  the writer lands and whole documents can be compared end to end.

  80 probe cases agree on the first run. 10 unit tests, all passing first
  try.

- **Wave 91 — the writer, and the first end-to-end probe.**
  `PdfWriter.swift` ports the body of
  `to_markdown_from_lines_with_tables_and_images` together with
  `flush_page_tables_and_images`. **`markdown/convert.rs` is now fully
  ported.**

  Everything the previous thirty waves built converges here: one pass over
  the analysed lines deciding what each is — caption, heading, list item,
  quote, code, prose — and emitting Markdown, with tables and images
  interleaved. Most of the subtlety is in when the dozen pieces of running
  state reset, not in the classification. A paragraph ends on a large
  baseline gap (absolute, so a *backward* jump breaks too), on a column
  switch, or on the transition out of a bold run; a list survives a paragraph
  break but not a failed continuation test; a code block spans lines and must
  be closed on a page break as well as on the first non-code line.

  **The probe is the wave's real result.** Because the reference function is
  callable whole, this compares *finished Markdown* for 95 documents against
  the reference actually running — the strongest check in the project so far,
  and it retires wave 90's transcription. That probe is kept only for
  isolation: when both fail, the prologue is where to look.

  It found three divergences on its first run, which is what an end-to-end
  probe is for:

  1. **The delimiter bug, a third time — and I introduced it knowing about
     it.** The case format joined blocks with `|`, and a rendered Markdown
     table is full of pipes, so every table case silently described a
     different block. Waves 85 and 86 found this shape twice; writing a new
     probe reintroduced it. Separator changed to `@`.
  2. A missing early return: the reference answers an empty document with an
     empty string, and the port returned a lone newline. I had read that
     early return in wave 90, deferred it to "the main loop", and then not
     written it.
  3. A paragraph-break difference that turned out to be a symptom of (1).

  Two reference behaviours worth naming, both pinned. A tagged `LI` at the
  top of a page **absorbs the body text below it** — once a list opens,
  following lines within seven line heights at a similar indent are
  continuations. And `P` and `Figure` tags leave the visual heuristic in
  charge, so a tagged paragraph can still become a heading.

  95 documents agree after the fixes. 16 unit tests, all passing first try.

- **Wave 92 — the plain entry point, and its nine divergences.**
  `PdfWriterSimple.swift` ports `to_markdown_from_lines`, the reference's
  public conversion for callers with nothing but text lines.

  It is **not** the big writer with arguments defaulted. It is a separate,
  older implementation that has drifted from its sibling, and the drift is
  the substance of the port: no bold-run merge; a narrower sequence
  exclusion; a page break that also clears the list state; no band-switch
  break; a heading gate missing the bullet-marker, list-continuation and
  non-heading-role tests; a rarity fallback that needs no strong signal but
  demands isolation for a single word; no numbered-bold shortcut; code fenced
  per line rather than accumulated; and no handling for tagged captions,
  lists, quotes or code.

  Sharing an implementation would mean choosing which behaviour is "right",
  and both are the reference's. They are kept apart.

  **The divergence is measured, not asserted.** The probe now runs every
  document through both entry points: of 100 documents, **38 produce
  different Markdown**. Two hundred documents compared in total, all agreeing
  with the reference on the first run.

  Checking before asserting paid again. Of three divergences I expected to
  demonstrate, only one did. A bullet-marked line at heading size is a
  heading here and a list item in the full writer — real. But a list crossing
  a page break comes out identical, because the page break resets the
  baseline and the continuation test fails on the gap whether or not the list
  state was cleared; and a standalone bold `CONTENTS` is promoted by both.
  The first was corrected in the doc comment from a behavioural claim to a
  code-level one, and pinned by a test that records the difference is *not*
  live.

  200 probe documents, 10 unit tests, all passing first try.

- **Wave 93 — the first piece of `lib.rs`.**
  `PdfLayoutComplexity.swift` ports `compute_layout_complexity` from
  `lib.rs`, together with `filter_rects_to_band` and `filter_lines_to_band`
  from `markdown/mod.rs`.

  This is the summary the pipeline reports alongside the Markdown — which
  pages hold tables, which hold columns — and it is the first thing in
  `lib.rs` this port reaches. It runs every table detector the project has,
  rect-based then line-based then the borderless heuristic, per band of a
  side-by-side page, and only a **data** table counts: a table of contents
  routes through the same detector and renders as a flat list.

  The two filters differ in a way worth knowing. A rectangle narrower than
  70% of the band needs only to touch it, while one at or above that width
  must have 70% of *itself* inside — so a cell border belongs to whichever
  band it reaches and a page-spanning frame belongs to neither. Line segments
  have no proportional rule at all: a plain overlap test, strict at both
  ends, so a full-width rule is claimed by every band it crosses. Boundaries
  pinned at 139/140/141 points and at the zero-overlap edge, along with the
  negative-width normalisation a right-to-left path produces.

  **Scoping note.** `process_document` is the pipeline proper, and it is not
  portable yet: it needs `detector::detect_from_document`, the lopdf-dependent
  half of `detector.rs`, which remains unported. This wave took the largest
  self-contained piece downstream of it instead. Nothing in `Sources` calls
  `pdfExtractTextRuns` yet and `AnyDoc.swift:27` still throws.

  43 probe cases agree on the first run. 10 unit tests, all passing first
  try.

- **Wave 94 — the detector's byte-level half.**
  `PdfContentScan.swift` ports `scan_content_for_text_operators`,
  `extract_font_name_before_tf`, `collect_text_chars_before` and `hex_val`
  from `detector.rs`.

  Detection decides whether a page carries real text before anything is
  decoded, by reading the raw content stream as bytes — no object graph, no
  fonts. It counts text operators against path operators, because a page
  whose "text" is vector outlines has thousands of the latter and almost none
  of the former, and collects the distinct bytes inside string operands,
  which is what later separates an Identity-H page with no ToUnicode from
  ordinary text.

  Behaviours pinned: `Tj` needs white space or the stream's end after it,
  while `Tf` also accepts `[`, `(`, `<` or `/`, because writers run it
  straight into the next operand; single-byte path operators must stand alone
  as words, so `form` contributes nothing; `f*` counts once rather than twice,
  since the lone `f` inside it fails the word-end test; and the image count is
  **always zero** — `Do` invokes any XObject, forms included, so images are
  counted by walking resources instead.

  Two reference quirks, both reproduced. `/F1 ` with no size **loses its last
  digit**: the backward scan skips a size that is not there, eating the `1`,
  and yields `F`. And `collect_text_chars_before` collects rather than
  parses, so the inner delimiters of `(a(b)c)` are themselves counted as
  characters — which cost one wrong test expectation, corrected against the
  reference.

  191 probe cases agree on the first run. 15 unit tests.

- **Wave 95 — the ToUnicode string helpers, and a gap they expose.**
  `PdfToUnicodeText.swift` ports `parse_hex_u16`, `hex_to_unicode_string`,
  `normalize_tounicode_destination`, `hex_to_unicode_scalar` and
  `find_usecmap_name` from `tounicode.rs`.

  Turning a CMap destination into text is less mechanical than it looks.
  Destinations are UTF-16BE, so surrogate pairs must survive — treating each
  four-digit chunk as a scalar loses every emoji. `String::from_utf16`
  *rejects* an unpaired surrogate rather than substituting, so a destination
  naming half a pair yields nothing at all. A one-byte destination is
  accepted although no specification allows it, provided it is not a control
  character — with tab and newline readmitted by name.

  And some producers write a **list of alternatives** into a single
  destination: every acceptable whitespace codepoint, or every acceptable
  hyphen. `normalize_tounicode_destination` collapses those back to one
  character, narrowly enough that an ordinary multi-character mapping — a
  ligature expanding to `ffi` — survives untouched. The whitespace signature
  requires a control character among the run; the hyphen signature requires
  the soft hyphen specifically.

  **A gap this exposes.** These helpers sit inside
  `build_cmap_entry_from_stream`, which wave 5 ported as
  `parsePdfToUnicode` — a byte scanner that reaches destinations by its own
  path and **does not apply the normalisation**. So a malformed CMap that
  maps one code to a list of whitespace alternatives currently yields the
  whole run where the reference yields one character. The helpers are ported
  and probed here; routing the scanner through them is a correctness fix
  that needs its own wave, and is recorded rather than rushed at the end of
  a session.

  179 probe cases agree on the first run. 10 unit tests, all passing first
  try.

- **Wave 96 — closing wave 95's gap.**
  `parsePdfToUnicode` now applies `pdfNormalizeToUnicodeDestination`, and a
  new `PdfCMapScannerTests` pins the scanner against the reference's own
  `ToUnicodeCMap::parse` answers.

  Wave 5 ported `ToUnicodeCMap::parse` by reimplementing it as a byte
  scanner rather than transliterating its helpers. That passed its own probe
  — but the probe only checked what the scanner *did*, never what the
  reference's helpers did on the same path, so a behaviour could be silently
  **absent** rather than wrong. Wave 95 exposed one; this wave measured and
  closed it.

  The reference's `ToUnicodeCMap::parse` is public and takes bytes, so it can
  be queried directly. Asked about a destination of `<00200009>` it answers
  `U+0009`; the port answered `U+0020 U+0009`. Four such cases failed before
  the fix and pass after. The neighbouring behaviours were already correct:
  surrogate pairs join, an unpaired half maps to nothing, and ordinary runs
  — two spaces, a `ffi` ligature — are left alone.

  The comparison is by **what the map answers**, not how it stores it: the
  reference keeps ranges lazily and this port flattens them, so `lookup` is
  the only fair basis.

  **Not done, and recorded as such.** The oracle now carries a `--cmapparse`
  mode, but the case generator is not wired to it, so this wave's evidence is
  a set of reference answers pinned as unit tests rather than a generated
  differential suite. Wiring it is the first thing to do next — and the
  broader question wave 95 raised stands: **wherever an early wave
  reimplemented rather than transliterated, the probe validates the port's
  structure, not the reference's behaviour.** Those sites are worth
  enumerating.

- **Wave 97 — the audit's first result: four bugs in a ninety-wave-old file.**
  `PdfToUnicode.swift` rewritten, and the `--cmapparse` differential suite
  wave 96 left unwired now runs 383 streams.

  Wave 5 ported `ToUnicodeCMap::parse` by **reimplementing** it — scanning
  the stream its own way and flattening every mapping into one dictionary —
  rather than transliterating the reference's structure. That passed its own
  probe for ninety waves, because the probe compared the scanner against
  cases of the scanner's own design and never against the reference running
  on the same input. Wiring the differential suite found **seven divergences
  immediately**, of which four were real defects:

  1. **Direct mappings must outrank ranges**, whatever order the sections
     appear in. The reference keeps `char_map` and `ranges` apart and
     consults the first before the second; a flattened dictionary gets
     whichever was written last, which is wrong for one of the two orders
     whatever it picks.
  2. **A one-byte destination is legal.** `<41>` means `A`; the port rejected
     any destination whose digits did not divide into 16-bit units, losing
     the character.
  3. **An unpaired surrogate voids its whole destination.** The port dropped
     the unpaired half and kept the rest, inventing a character —
     `<D992C581>` became U+C581 where the reference maps nothing.
  4. **The code width comes from the entries when the codespace disagrees.**
     A `<0000> <FFFF>` codespace beside one-byte entries is producer
     boilerplate, and the reference believes the entries.

  Three further differences were structural rather than defects: the
  reference returns `None` where this port returns an empty map, and it
  stores ranges unexpanded so an *inverted* range still makes the CMap
  non-empty while never matching. Both are now modelled explicitly.

  The rewrite adopts the reference's structure — `charMap` plus unexpanded
  `ranges`, with lookup precedence and its two-candidate binary search —
  because the structure is what carries the behaviour. It also drops the
  earlier port's range-size cap, which existed only because expansion made
  a full-codespace range expensive.

  **The lesson generalises.** Where an early wave reimplemented rather than
  transliterated, its probe validates the port's structure, not the
  reference's behaviour, and a missing behaviour has nothing to disagree
  with. `parsePdfToUnicode` was one such site; enumerating the others is
  still outstanding.

  383 probe streams agree. 11 unit tests, each recording one of the fixed
  behaviours.

- **Wave 98 — the audit: what was never being run.**
  `scripts/run-probes.sh` and `PdfProbeCoverageTests.swift`.

  Wave 97 showed that a reimplemented port's own probe proves less than it
  appears to. This wave asked the next question — which probes were running
  at all — and the answer was worse than the question assumed.

  Every differential suite in the package is gated on an environment
  variable naming a generated corpus, and a suite whose variable is unset
  **returns before comparing anything and reports as a pass**. That is right
  for a fresh checkout, which cannot build the oracles. It also means
  `swift test` reports green whether or not a single comparison ran.

  Seven gates exist. Only `ANYDOC_GRID_PROBE` was being set. The other six —
  the object graph against lopdf, the font, marked-content and
  structure-tree corpora, the line classifiers, and NFKC over every
  codepoint — **had not run in more than thirty waves**. And no `ANYDOC`
  variable appears in the CI workflow at all, so *every* differential suite,
  the grid probe included, has always run vacuously in CI.

  **All six were regenerated and run. Every one passes**: 27 object graphs
  against lopdf with 3 rejections agreed, 26 graphics and underline dumps,
  12 font documents, 21 marked-content cases, 20 tagged documents, 22,047
  classifier strings, 5,579 cleanup strings, and 1,112,064 codepoints of
  NFKC. No defects — the coverage was real and correct, it simply was not
  being exercised.

  Two changes so this cannot recur quietly. `scripts/run-probes.sh` builds
  every oracle, generates every corpus and runs the suite with all seven
  gates set, in one command. And `PdfProbeCoverageTests` prints, at the end
  of *every* run, which gates were set and which compared nothing — it never
  fails, it just refuses to let the gap be invisible.

  **CI still does not run any of this, deliberately.** The oracles are built
  from a vendored copy of the reference crate, and fetching that in CI was
  rejected in favour of keeping the published repository independent of
  upstream. That decision stands; what changes is that the reports now say
  so. A green CI badge means the package builds and the non-differential
  tests pass — nothing more.

- **Wave 99 — the pipeline, and the first byte-diff.**
  `PdfPipeline.swift`, `AnyDoc.swift` wired, a `--markdown` oracle mode, and
  `PdfEndToEndTests`.

  `AnyDoc.markdown` no longer throws for PDF. The assembly the previous
  ninety-eight waves were building towards is a hundred lines: pages, runs,
  letter-spacing repair, line grouping, font styles, underlines, header
  stripping, analysis, writer. Everything it calls was ported and probed
  separately; what was missing was the wiring, which had been sitting in the
  test target as scaffolding for the corpus suite.

  **The byte-diff `PLAN.md` §2 calls the real bar now runs, and the result is
  22 of 27 documents byte-identical to the reference on the first attempt.**
  The five that differ each name a stage that is honestly unported, and the
  suite prints the first differing line of each:

  | file | reference | this port | missing |
  |---|---|---|---|
  | `two-column.pdf` | a Markdown table | prose | table detection per page |
  | `annotations.pdf` | `address.city: Lisbon` | nothing | form-field text |
  | `underline-fraction.pdf` | `12 34` | `<u>12</u> 34` | `suppress_table_underlines` |
  | `merge-thresholds.pdf` | `AB cd` | `ABcd` | a word-join threshold |
  | `merge-fragments.pdf` | `TRACK` | `## T R A C K` | fragment merging |

  That is the remaining work ordered by a measurement rather than by
  guesswork, and each row is a wave.

  The suite **reports the tally rather than failing on it**, and fails only
  when a file leaves the matching set — so the 22 are a ratchet. Adding to
  that list is now the unit of progress.

  One fix landed with the wiring: letter-spacing repair runs per page and
  the threshold it measures becomes that page's word-join threshold, as the
  reference does. It did not change the tally, which is worth stating —
  `merge-fragments.pdf` needs fragment merging, not tracking repair.

  **What the pipeline still is not.** No detector, so a scanned document is
  not distinguished from a text one; no table or image detection; no
  structure tree, so a tagged PDF is read as untagged. Each is noted at its
  call site rather than summarised, so adding one is a local edit.

- **Wave 100 — underlines inside tables, and a wiring bug the ratchet caught.**
  `PdfTableUnderlines.swift` ports `suppress_table_underlines`, and the
  end-to-end tally moves to **23 of 27**.

  A ruled table's cell borders are strokes like any other, so the geometric
  underline detector reads the rule *under* a cell as an underline *on* its
  text and every cell comes out `<u>`-wrapped. The fix runs after detection
  and clears the flags on any item a table detector claims — but only if the
  table is **plausible**, because erasing wherever a table is detected erases
  legitimate underlines whenever the detector is wrong. The gate is cell
  length: a grid where 30% or more of its non-empty cells exceed a hundred
  characters has captured flowing prose, not data. The reference's own note
  records the case that forced this — a 4×8 grid claiming 52 of 52 items on
  a prose page, one cell holding 806 characters.

  **The port was right and the wiring was wrong, and only the byte-diff said
  so.** The first attempt applied the suppression per *line*, after grouping.
  Every unit test passed and the tally did not move: a line holds one or two
  items, so no detector ever found a grid and the function did nothing at
  all. Emphasis and decoration are decided for the whole page, before
  grouping — as the reference does, and as `merge-fragments` and
  `merge-thresholds` will need too.

  That is the first defect this project has found through end-to-end output
  rather than through a unit probe, which is exactly the class wave 99 was
  built to catch: a correct function connected at the wrong level has
  nothing to disagree with in isolation.

  7 unit tests. Remaining divergences: `two-column.pdf` (table detection),
  `annotations.pdf` (form-field text), `merge-thresholds.pdf` (a word-join
  threshold), `merge-fragments.pdf` (fragment merging).

- **Wave 101 — two passes that were never connected.**
  The per-page order in `PdfPipeline.swift` corrected, and the end-to-end
  tally moves to **25 of 27**.

  Wave 100 predicted this: `merge-fragments` and `merge-thresholds` both
  concern page-level operations, so the same connected-at-the-wrong-level
  question would apply. It did, and worse — `pdfMergeTextItems` and
  `pdfMergeSubscriptItems` were ported, probed and **never called by
  anything**. A PDF does not draw words: `Hel`/`lo`/`wor`/`ld` at four
  explicit positions is one word, and without those passes it stays four.

  The order matters as much as the presence. The reference runs, per page:
  mark underlines, merge text, merge subscripts, measure letter-spacing,
  suppress table underlines — then groups into lines. This port had the
  letter-spacing measurement *before* the merges, so it was measuring
  fragments rather than words. Both rows cleared at once when the order was
  fixed.

  `PdfPipelineOrderTests` pins the order by its **effects** rather than by
  reading the code, so a dropped pass fails a test however the pipeline is
  rearranged: fragments become words, a letterspaced run rejoins, a
  mixed-case pair keeps its space where a lowercase pair does not, and a
  subscript folds into `H₂O`.

  Those tests failed on their first run for an unrelated reason worth
  recording: a hand-built PDF whose font omits `/Widths` gets a different
  glyph advance, so every gap measures differently and every threshold test
  is meaningless. The corpus generator's font declares 500/1000 em for all
  95 glyphs; the test's now does too.

  Remaining: `two-column.pdf` (table detection) and `annotations.pdf`
  (form-field text).

- **Wave 102 — form fields are text, hyperlinks are not.**
  Annotations wired into `PdfPipeline.swift`, and the end-to-end tally moves
  to **26 of 27**.

  Neither a link nor a field value is drawn by any content stream — a link is
  a rectangle plus an action, and a field value lives off the trailer — so
  both need their own extraction. Both were ported in an earlier wave and,
  for the fourth wave running, neither was connected to anything.

  Wiring them naively made it *worse*: appending both to the page's items
  emitted a bare URL the reference never prints. The reference sorts items by
  type before the markdown path and **links go to a separate stream**, used
  to decorate matching text as `[text](url)`; they never contribute text of
  their own. Form fields go in with the text. That decoration pass is
  unported, so a hyperlink currently survives as plain text — noted at the
  call site.

  Annotations join *after* the merge and letter-spacing passes, which is the
  reference's order: they are not text the page drew, and merging must not
  see them. They carry font size zero and no font name, so they cannot vote
  in the body-size statistics that every heading ratio is measured against.

  **The remaining divergence is `two-column.pdf`**, which needs per-page
  table detection — the largest of the five gaps wave 99 measured, and now
  the only one.

- **Wave 103 — per-page table detection: the corpus goes whole.**
  `PdfPageTables.swift` ports the detector cascade, and the end-to-end tally
  reaches **27 of 27 — every file in the corpus byte-identical to the
  reference.**

  Four detectors run in priority order and each *claims* the items it uses,
  so a later one never re-reads text an earlier one already gridded: rects,
  then lines when rects found nothing, then rect-guided construction over
  hint regions, then the borderless heuristic. The claimed items are
  withheld from the text stream — a table's cells must not also appear as
  prose — which is the half of this that the writer needed and the detectors
  could not provide alone.

  **This is the single-band, chart-free, untagged case**, and the omissions
  are each noted at their branch: the reference also splits a page into
  side-by-side bands and retries merged, masks chart regions from every
  detector, and gives structure-tree tables priority over all four. Stage 3
  is absent too — `try_build_rect_guided_table` is unported — so a page whose
  rects cluster without gridding yields no table where the reference finds
  one. No corpus file exercises any of those, which is precisely why they
  can wait and why saying so matters.

  One deliberate divergence, recorded rather than hidden: the heuristic
  detector measures candidates against the document's body size, but nothing
  has read the whole document at that point in the pipeline, so the page's
  own body size is used. On a document whose pages differ in body size this
  will diverge, and the fix is to move the analysis ahead of the page loop.

  The ratchet is now closed: with every file matching, *any* divergence is a
  regression, so the suite asserts the whole tally rather than a list.

  5 unit tests.

- **Wave 104 — widening the corpus until it breaks.**
  Fourteen documents added to `gen-pdf-corpus.py`, and the end-to-end
  comparison now runs **38 of 41** with three named gaps.

  Wave 103 finished at 27/27, but that corpus was built to stress the
  *object layer* — xref shapes, filters, object streams — and its text is
  deliberately trivial. A perfect score against it says little about the
  passes that turn positioned glyphs into Markdown. So this wave built
  documents for the other half.

  **Nine markdown-shaped files, all byte-identical on the first run**:
  heading tiers, lists with a wrapped continuation, captions and a dot-leader
  contents page, bold/italic/monospace runs, a drop cap, a three-page
  document with a running header and a numbered footer, hyphenation and a
  bare URL and a standalone page number, a bordered table from `re` rects,
  and a ruled table from strokes. That the whole markdown path agreed
  immediately is the strongest evidence so far that waves 61–103 are sound.

  **Five files built to fail**, targeting stages this port has not wired.
  Three did, and each is exactly the predicted gap:

  | file | reference | this port | missing |
  |---|---|---|---|
  | `gap-xobject-text.pdf` | the text | nothing at all | `extractor/xobjects.rs` |
  | `gap-tagged.pdf` | `# Tagged As A Heading` | `##` | structure-tree tagging |
  | `gap-rotated.pdf` | `## rotated ninety degrees` | no heading | rotated-CTM placement |

  Two did **not** fail, which is as useful: `gap-chart.pdf` and
  `gap-newspaper.pdf` both match without chart masking or band splitting.
  Those stages are unported and, on these shapes, unnecessary — so they are
  not the next work.

  The `gap-*` files are excluded from the graphics and underline probes,
  which would otherwise report the same three gaps a second time as noise.
  `PdfEndToEndTests` tracks them by name, so the gap stays measured rather
  than merely excused.

- **Wave 105 — form XObjects, and a shadow that hid the fix.**
  `PdfFormXObjects.swift` ports `extractor/xobjects.rs`, and the end-to-end
  tally moves to **39 of 41**.

  A `Do` invokes an XObject: an image, or a *form* — a content stream of its
  own drawn under the graphics state in effect. Real documents put a great
  deal of text in forms, and a reader that ignores `Do` loses all of it
  silently, which is exactly what `gap-xobject-text.pdf` measured.

  **This port inlines rather than recurses.** The reference carries a second
  five-hundred-line walker specialised for forms; the specification says a
  form invocation *means* `q`, the form's `/Matrix` as a `cm`, its content,
  then `Q`, so splicing precisely that into the operation stream lets the one
  walker already here handle both. A hundred and thirty lines instead of five
  hundred, and the byte-diff judges whether it is equivalent.

  Two findings, both caught by probes rather than by reading:

  **A form never inherits the page's fonts.** The specification says
  resources are inherited, so a form with no `/Resources` should draw with
  the page's. `get_form_fonts` returns nothing at all in that case and never
  consults the page, leaving those runs with no metrics and a **zero
  advance**. This port inherited them, giving a real width of 160 where the
  reference assigns 0 — invisible in the Markdown, caught by the item-level
  underline probe. Reproduced by namespacing every `Tf` inside a form, so an
  undeclared name resolves to nothing here too.

  **A test-target function shadowed the module's.** `pdfPageTextRuns` and its
  five siblings still existed at file scope in `PdfTextTests.swift` from when
  the pipeline was scaffolding. A file-scope function in the test target
  shadows the module's, so after teaching the real one to inline forms, every
  test kept calling the old copy that did not — the pipeline handled forms
  correctly while the probes reported them missing, and the two disagreed for
  half an hour before the cause was obvious. The duplicates are deleted; 123
  lines of them.

- **Wave 106 — the tagged path, joined at last.**
  `PdfStructRoles.swift` ports `mcid_to_roles` and `mcid_count`, and the
  end-to-end tally moves to **40 of 41**.

  A tagged PDF says what its content *means*, and the writer prefers those
  declarations to any geometric guess. The link is the marked-content id: a
  structure element names an id and a page, and the content stream's `BDC`
  stamps the same id onto the runs it wraps.

  **Every piece of this had been ported and none of them were joined.** The
  tree walker landed in an early wave, the role vocabulary and
  `resolve_line_struct_role` in wave 85, `effective_heading_level` in wave
  88, the extractor's `BDC`/`EMC` tracking earlier still. What was missing
  was forty lines mapping the tree's page *references* to the page *numbers*
  items carry — the sixth connection gap this session, and the last one the
  corpus could see.

  One distinction that matters and is easy to lose: an empty map becomes
  **nothing at all** rather than an empty dictionary. The two differ
  downstream, where the overuse audit returns before counting when there are
  no roles but counts nothing when handed an empty map. The reference makes
  the same distinction explicitly.

  A stale comment was corrected while here. `PdfLayoutItem.mcid` still
  claimed "nothing sets this yet — the extractor's `BDC`/`EMC` tracking is
  not ported", written when that was true and left standing after it stopped
  being. A reader trusting it would have concluded the tagged path was
  further away than it was.

  5 unit tests. The last divergence is `gap-rotated.pdf`.

- **Wave 107 — rotated text, and a bug that had been there since wave 2.**
  `pdfEffectiveFontSize` ported from `text_utils.rs`, and the end-to-end
  tally reaches **41 of 41 — every file, including all five documents built
  to fail.**

  The reference measures a transform's two axes as whole vectors —
  `√(a²+b²)` and `√(c²+d²)` — and takes the larger. This port used the
  vertical component `|d|` alone.

  For ordinary upright text the two agree exactly: `b` and `c` are zero and
  `d` *is* the vertical scale. They diverge the moment text is rotated. A
  quarter turn puts the scale entirely into `b` and `c` and leaves `d` at
  zero, so **every rotated run reported size zero** — invisible to heading
  detection, and contributing a zero to the body-size statistics every
  heading ratio is measured against. Anisotropic scaling was wrong too:
  text stretched horizontally was measured by its height.

  This is the first defect this session that is a **computation** rather
  than a connection, and it had been in the extractor since wave 2. Ninety
  waves of probes never touched it, because every probe fed the extractor
  upright text — the same blind spot that made `gap-rotated.pdf` worth
  writing.

  The `unwiredGaps` exclusion list in the graphics probes is now empty, and
  kept as the place a knowingly-unported divergence must be written down
  rather than assumed. The end-to-end suite asserts the whole tally again.

  6 unit tests.

- **Wave 108 — feeding the extractor things it had never seen.**
  Fourteen more corpus documents, one real defect found and fixed, and the
  end-to-end comparison at **55 of 55**.

  Wave 107's bug survived ninety waves because every probe fed the extractor
  upright, unscaled, unspaced text. So this wave fed it the rest of the text
  state and the whole decoding path.

  **Eight documents of text-state arithmetic — all passed on the first run.**
  Horizontal scaling, rise, character and word spacing, large kerning in both
  directions, render modes 3 and 7, nested `q`/`Q` with accumulating `cm`, a
  negative vertical scale, and the `TD`/`T*`/`'` operators that set leading
  as a side effect. A negative result, and worth having: that arithmetic is
  now measured rather than assumed.

  **Six documents of fonts and encodings — one failed.** A `/Differences`
  encoding was **ported and never consulted**: `pdfParseEncodingDifferences`
  existed and was probed, and the decode path went straight from `ToUnicode`
  to taking the byte at face value. A font saying code 65 draws `bullet` read
  as `ABC` where the reference reads `•—“`. That is the seventh connection
  gap this session, and the first one found in the *decoding* path rather
  than the pipeline.

  The precedence is now explicit and pinned by test: `ToUnicode` first, the
  `/Differences` encoding second, the byte itself last. A *named* encoding —
  `/WinAnsiEncoding` — selects a standard table, which the reference leaves
  to lopdf and this port still does not implement; noted at the call site
  rather than silently treated as Latin-1.

  The CMap parser rewritten in wave 97 also ran end to end for the first
  time: `bfchar`, `bfrange` in both forms, a surrogate pair, a ligature
  destination, and the whitespace-list collapse wave 96 found — all correct
  on real documents.

- **Wave 109 — encrypted documents, which the reference does not implement.**
  `PdfCrypto.swift` and `PdfDecryption.swift`: MD5, RC4 and the standard
  security handler for revisions 2 and 3. The end-to-end comparison reaches
  **57 of 57**, two of them encrypted.

  This is the first wave with nothing to transliterate. The reference hands
  an encrypted file to lopdf and lets that crate decrypt; this port has no
  such dependency, so the algorithms are written out. Both are small, both
  are fully specified, and both have published test vectors — which is what
  makes hand-rolling them defensible rather than reckless. MD5 is checked
  against every vector in RFC 1321's own test suite plus the 55/56/64-byte
  block boundary, and RC4 against RFC 6229.

  **Why this matters more than its size suggests.** Most "protected" PDFs
  carry an *empty user password*: the producer wanted permissions, not
  secrecy, and every reader opens them without asking. Before this wave they
  parsed, decoded to noise, and produced confident nonsense. Failing loudly
  would have been better; succeeding wrongly is the worst option, and it was
  the one in place.

  Unsupported revisions are now refused rather than attempted. Running RC4
  over AES-encrypted bytes yields plausible-looking noise, so `/V 4` with
  `/AESV2` and `/R 6` with AES-256 set `isUnreadablyEncrypted` instead. Those
  remain unported.

  Two notes on verification. The corpus builds its encrypted files with its
  own Python implementation of the same algorithms, and **lopdf reads them** —
  so the generator is confirmed by a third party rather than by agreeing with
  the code under test. And lopdf *consumes* the `/Encrypt` dictionary when it
  decrypts, dropping it from the object table, where this reader keeps it;
  that is a difference in what the two model, not in what they parsed — the
  stream lengths either side agree byte for byte — and it is corrected in the
  comparison rather than papered over.

- **Wave 110 — the dependency audit, and reading embedded fonts.**
  `PdfTrueType.swift`: the sfnt table directory and the `cmap` table's four
  common subtable formats. The end-to-end comparison reaches **58 of 58**.

  Wave 109 raised the point this wave acts on: **anything the reference gets
  from a dependency is invisible to a differential port.** The diff can only
  compare what both sides compute, so a capability the reference delegates
  never shows up as a divergence — it shows up as a document nobody thought
  to write. So the dependencies were enumerated: `lopdf` (object layer and
  decryption — reimplemented, compared by the corpus), `unicode-normalization`
  (NFKC — ported, 1.1M codepoints probed), `regex` (classification patterns —
  ported, 22k strings probed), `log`/`once_cell`/`thiserror`/`pyo3`
  (infrastructure and bindings, nothing to port), and **`ttf-parser`**, which
  was the one real hole.

  A producer that subsets a font often omits `/ToUnicode`, on the grounds
  that the font already says which character each glyph draws. Such a
  document extracted as raw glyph ids — the corpus file now proves it, since
  before this wave it produced `"\0\u{03}\0\u{04}\0\u{05}"` where the
  reference reads `Hi!`. Confident, well-shaped nonsense, on a shape common
  in the wild.

  Formats 0, 4, 6 and 12 are read; anything else is ignored rather than
  guessed at, since a misread mapping yields plausible wrong characters.
  Format 4's `idRangeOffset` is a byte distance *from the slot that holds
  it*, which is the part everyone gets wrong and which the unit tests pin
  directly. `/FontFile3` holds CFF, whose charset needs its own parser and
  is not implemented.

  **One difference that is the reference's, not this port's.** Its
  `--underline` probe extracts at a layer with no font-program fallback and
  reports *no text at all* for this file, while its Markdown path recovers
  it. The two disagree with each other, so no single port can match both.
  This port applies the fallback once, in the extraction both its paths
  share; the Markdown is byte-identical and the item-level dump is not. That
  is recorded by name with the reason rather than excused.

  7 unit tests, against `cmap` tables built byte by byte from the
  specification's layouts.

- **Wave 111 — AES-128, the second delegated hole.**
  `PdfAES.swift` and `/AESV2` wired into the security handler. The
  end-to-end comparison reaches **59 of 59**.

  Wave 109 refused the AES revisions deliberately, on the grounds that RC4
  against AES bytes yields plausible noise. This closes the common one:
  `/V 4` with a `/StdCF` crypt filter of `/AESV2`, which is what most
  encryption written this century actually is.

  The inverse cipher, the key schedule and CBC, checked against **FIPS-197's
  own vectors** — appendix C.1's canonical block, appendix B's worked
  example, and appendix A.1's expanded key. Padding is PKCS#7 and removed
  only when it *is* valid: a corrupt final block otherwise truncates real
  text, and a slightly-too-long string is the lesser damage.

  Two details that are easy to miss and fatal to get wrong. AES mixes four
  extra bytes into every object key — `sAlT` spelled in ASCII, which is the
  specification's own joke and its own constant — so without them the key is
  an RC4 key and decrypts to noise. And `/V 4` names its algorithm in a
  crypt filter rather than inline, where `/Length` is in **bytes** while the
  outer `/Length` is in bits.

  `/R 5` and `/R 6` with AES-256 remain unimplemented: they key from SHA-256
  rather than MD5, which is a different wave. They are still refused rather
  than attempted.

  As in wave 109 the corpus builds its encrypted file with an independent
  Python implementation — this time of AES *encryption*, the direction this
  port does not implement — and lopdf reads it. Three implementations
  agreeing is worth more than one agreeing with itself.

  One test-harness fix: the corpus comparison identified the `/Encrypt`
  object by its key list, which broke the moment a document carried `/CF`,
  `/StmF` and `/StrF`. It now uses the trailer's own reference.

- **Wave 112 — OpenType programs, the third delegated hole.**
  `/FontFile3` read alongside `/FontFile2`, and the end-to-end comparison
  reaches **60 of 60**.

  Wave 110 read a font program only from `/FontFile2` and said `/FontFile3`
  "holds CFF, whose charset would need its own parser". That was half right
  and the wrong half was load-bearing. OpenType wraps CFF outlines in the
  **same sfnt container** — same table directory, same `cmap` — so the
  parser wave 110 already wrote reads it unchanged. The reference passes
  both to one function for exactly that reason. Only a bare `/Type1C`
  program has no container, and that yields nothing here as it does there.

  So the fix was two lines, and the wave was really about noticing that a
  documented limitation was a mistaken one. A comment that says "not
  implemented" reads as a decision; this one was an assumption.

  **The necessity is now asserted, not assumed.** Wave 100 established that
  an obviously-required fix can be a no-op, so `PdfFontProgramTests` checks
  that the program is *located at all* — the part a refactor can silently
  drop, after which the pipeline goes on emitting raw glyph ids that look
  like text and pass every check not comparing against the reference.

  A verification attempt worth recording: reverting the fix to watch the
  tally drop timed out mid-run and left the working tree modified. The
  restore then hit an interactive `cp` prompt and silently did nothing, so
  the next measurement was of the *reverted* code. Checking the file rather
  than trusting the command is what caught it.

- **Wave 113 — the stale-claim sweep, and the eighth connection gap.**
  Structure-tree tables wired as stage 0 of the per-page cascade;
  **62 of 62** byte-identical.

  Wave 112 ended on "a comment that says 'not implemented' reads as a
  decision; this one was an assumption". This wave took that seriously and
  grepped every such claim in `Sources/AnyDoc/Pdf`. Eleven claims; **four
  were stale**, describing work finished waves ago — `strip_repeated_lines`
  (wave 89), the numbered-heading sequencer (wave 80), the structure-tree
  walker (wave 106), and `PdfLayoutItem.mcid` (set since the `BDC`/`EMC`
  tracking landed).

  The fourth was the expensive one. `PdfStructTables.swift` said its
  detector could not run because nothing set `mcid` — and behind that
  claim, `pdfDetectTablesFromStructTree` **had no caller at all**. A
  complete, probe-verified detector, unreachable from any document. That is
  the eighth connection gap, and the first one a *comment* hid rather than
  an oversight: the claim explained the silence, so nobody looked.

  Wiring it is the reference's stage 0, ahead of all four geometric
  detectors — an author's own tagging outranks any guess read from ink —
  gated on the tagged tables covering at least **half** the page's items.

  **Both halves were measured, and the first attempt measured nothing.**
  The corpus document added to prove the stage works passed with the stage
  suppressed: its cells sat at regular column positions, so the alignment
  heuristic gridded them and the test named for stage 0 was carried by
  stage 4. The composition trap again, this time in a fixture rather than
  in a predicate. Making the columns **ragged** — no two rows sharing an x
  — is what let the file discriminate: 61/62 with the stage off, 62/62
  with it on. The 50% gate got the same treatment in the other direction:
  a second document with ten untagged paragraphs against six tagged cells
  (0.375 coverage), which the reference renders as prose, and which our
  side renders as a table the moment the gate is widened.

  The remaining claims were re-verified as true, not merely left alone:
  `detector.rs`'s document half, the link-decoration pass, the rect-guided
  detector, and `PdfLayoutItem.isImage` (`isImage = true` appears nowhere).

  The lesson generalises past comments. A claim about *absence* is the one
  kind a differential port cannot check, because both sides agree about a
  feature neither exercises. It has to be re-derived from the code, and the
  cost of not doing it is a finished component sitting unreachable for
  seven waves.

- **Wave 114 — stage 3, and the branch that stage 3 needed.**
  `try_build_rect_guided_table` ported and wired; **63 of 63**
  byte-identical.

  The rect *grid* detector wants rows and columns it can read off directly.
  A calendar gives it neither: ragged first and last weeks, holidays that
  draw no box, a legend off to the side. So it declines, leaves a **hint**,
  and the layout falls through to the alignment heuristic, which reads a
  calendar as prose. Stage 3 takes the weaker signal the rects still carry
  — their x positions — as column boundaries, derives rows from the text,
  interpolates the columns the missing boxes would have supplied, and
  splits a week drawn as one text run back into one item per day.

  **Reading the call site found a second gap.** The reference's heuristic
  has three branches: no claims and no hints, no claims with hints, and
  *claims found* — run the heuristic on whatever is left. This port had
  only the first two, so a bordered table and a borderless one on one page
  lost the second. Stage 3 makes that branch mandatory rather than merely
  correct: stage 3 always leaves the page claimed, so without the third
  branch it would silence the heuristic entirely.

  It also forced the two claim-sets apart. The reference keeps
  `table_items` (what the prose must not repeat) and `rect_claimed` (what a
  later detector must not re-read); they hold the same indices for stages 0
  to 2, which is why one set had sufficed, and diverge at stage 3, where a
  hint region blocks **every** item inside it while only the items the
  table used are withheld from the text.

  **Two attempts at the corpus document failed before one worked**, and the
  failures were the useful part. A large-cluster hint has three conditions
  the reference never states together: boxes within **3pt** of each other
  so they cluster at all, at least **30** of them, and a bounding box no
  wider than **400pt**. The first calendar missed all three — 6pt gaps, 27
  boxes, 462pt wide — and the reference emitted prose for it, which read
  exactly like a correct port of a stage that had not run. Only probing
  `--recttables` and finding `hints 0` distinguished "the stage declined"
  from "the stage was never reached".

  Verification is layered because one calendar cannot separate the column
  floor from the fill floor from the tilde cleanup: the corpus proves the
  wiring (dropping stage 3 costs `rect-guided-calendar.pdf` its
  byte-identical status, and the ratchet reports it), and the reference's
  own eight unit tests are ported case for case to pin the rest.

- **Wave 115 — the ninth connection gap: the cascade runs per band.**
  Side-by-side splitting wired into table detection; **64 of 64**
  byte-identical.

  The whole four-stage cascade is a *band*-level thing in the reference,
  not a page-level one. A two-column page has two independent layouts side
  by side, and a detector shown both at once reads across the gutter: the
  left column's rows line up with the right column's, so the alignment
  heuristic finds a two-column table where there is only prose.

  `pdfSplitSideBySide` was ported waves ago and had exactly one caller —
  the complexity scorer. The table cascade never saw it. That is the ninth
  connection gap and the second in three waves found by reading a *call
  site* rather than a function, which is now the more productive habit.

  Ported with it: the two band filters, which are not the same rule. A
  small rectangle need only touch a band, because a cell border may sit on
  a boundary; one as wide as the band itself must be **70% inside** it, or
  every band on the page would claim the page-wide rule. A line needs only
  to touch, having no area to share out. And a negative width — a
  rectangle drawn right to left, which producers do emit — is normalised
  first, or it computes an empty overlap and vanishes from every band.

  The retry is the half worth understanding. Splitting is a guess that
  fails in one specific way: a genuinely borderless table's columns are
  indistinguishable from page-layout columns. So a page that was split and
  found nothing is tried again whole.

  **Two fixtures and one corpus document all failed to test anything, for
  the same reason.** `split_side_by_side` wants forty runs on the page and
  twenty either side of the gutter; the nine-row two-column document was a
  page it declined to split at all. It matched the reference with banding
  on and with banding *ripped out*, because the layer under test never
  ran — the same composition trap as wave 113's tagged table, from the same
  cause: a fixture built to look like the case rather than to satisfy the
  gate. Twenty rows fixed all three, and the document now diverges the
  moment banding is disabled.

  One test also had to be rewritten because it was wrong about the
  reference rather than about the port. It asserted the retry recovers a
  borderless table on a split page; `merged_retry_skips_body_font` says
  otherwise — where the column detector *did* find columns, body-size text
  may not found a table on the retry, because that is precisely the
  evidence that just proved to be page layout. The test now pins the gate
  and shows it is what decides, rather than the candidate being
  unfindable.

- **Wave 116 — looking for connection gaps on purpose.**
  `scripts/find-orphans.py`, and what it found; **65 of 65**
  byte-identical.

  Nine connection gaps had been found by wave 115, every one by accident.
  Three in a row came from reading a *call site*. So this wave stopped
  waiting for the next accident and swept for the class directly: every
  top-level `pdf*` function with no caller anywhere in `Sources/`.

  **441 functions, 34 with no caller.** Most are honest — they wait on a
  consumer that is genuinely unported (chart regions, the detector's
  document half, OCR reasons). Two were not.

  `pdfMergedRetrySkipsBodyFont` had been ported, and wave 115 wrote the
  same rule out inline without noticing. One wave is all it took to
  duplicate a function this port already had; a sweep that runs in a
  second would have caught it before the commit.

  `pdfSelectedRectangles` is the substantive one. The reference chooses
  between `re` rectangles, clip regions and filled paths **inside its
  extractor**, so everything downstream already sees one chosen list. This
  port kept the three lists apart and never chose: the pipeline passed
  `graphics.rectangles` straight to every detector.

  **The fix is wired, and I could not make it change any output.** Two
  corpus documents tried and failed. A clip-drawn table (`re W n` per
  cell) proved nothing because `re` is recorded unconditionally, painted
  or clipped, so the list is never empty and the substitution never runs.
  A path-drawn table (`m`/`l`/`h`/`f`, no `re` anywhere) does empty the
  list — and still matched, because six cells in a 2×3 grid are exactly
  the heuristic detector's minimum, so it finds the table from text
  alignment with no rectangles at all.

  So the change stands on its structure matching the reference, not on
  measurement, and that is the weakest kind of evidence this project
  accepts — recorded here as such rather than written up as a fix.

  **A third document was built and also failed to discriminate.** The
  prediction above was that a table too large or too irregular for the
  heuristic *and* drawn without `re` would do it, so `path-drawn-table.pdf`
  became a 3×4 grid of filled paths with the text set at ragged x positions
  — no two rows sharing a column, the trick that worked in wave 113. It
  matches with the substitution in place and with it removed. Since
  `graphics.rectangles` is appended to only from the `re` operator, and this
  page has none, the rectangle list must be empty and the table is still
  being found: something other than the rect detector is gridding it, and
  which thing is not yet known.

  That is where this stands. The fix agrees with the reference structurally
  and is inert on every input tried. The next step is not a fourth document
  but a probe — dump our own rect list and table-stage attribution for this
  page and find out what actually produces the grid, rather than guessing at
  geometry a fourth time.

- **Wave 118 — the probe, and the answer.**
  `pdfSelectedRectangles` proven load-bearing; **65 of 65** byte-identical,
  and **64 of 65** with it removed.

  The probe wave 117 asked for took ten minutes and settled a question two
  waves of geometry-guessing had not. For `path-drawn-table.pdf` it printed
  `re=0 filled=12 clip=0 selected=12` — so the substitution was working all
  along, exactly as designed. What it also printed was `heuristic alone: 1`.
  Both routes found the same grid, so removing the substitution changed
  nothing about the output.

  The ragged x offsets meant to defeat the heuristic were **9pt against
  120pt columns** — well inside its alignment tolerance, so the columns
  still lined up. At 26pt they do not, and the document separates cleanly:
  the rect route finds the table, the heuristic finds nothing, and dropping
  the substitution costs the file its byte-identical status.

  Worth naming as a method, because three waves went the other way: when a
  fixture will not discriminate, **measure the intermediate values** rather
  than vary the input again. Waves 116 and 117 each built a document on a
  hypothesis about why the last one failed, and each hypothesis was wrong in
  a way the document could not reveal. A twenty-line throwaway test that
  printed the four counts and the three stage outcomes answered it at once —
  and the answer, that the fix worked and the *fixture* was blunt, was not
  on either wave's list of guesses.

  The unit tests pin what one document cannot: `re` winning outright, fills
  at exactly 3× the clips and one short of it, the four-clip floor, both
  fallbacks, and that the clip list is deduplicated *before* it is counted —
  six copies of one rectangle must not out-vote two genuine fills.

- **Wave 119 — the detector's font half, and a probe built to check it.**
  `PdfPageAnalysis` gets a producer for its font fields; **68 of 68**
  byte-identical, 68 of 68 on the new probe.

  This is the port's defence against its own worst failure mode. A page
  whose only font is Identity-H with no `/ToUnicode` extracts *something* —
  raw CIDs, well-formed, nonsense — and so does a Type 3 page, where each
  glyph is a drawing procedure with no character behind it. Telling those
  apart from real text is what stands between a document being extracted
  and a document being sent to OCR.

  Ported: the resource-inheritance chain with shadowing, `FontInfo` keyed by
  **object id** rather than name (two dictionaries may both define `/F1`),
  `cid_values_look_like_unicode`, the embedded-`cmap` fallback, and the
  three usage-based predicates. *Usage*-based throughout: the question is
  which fonts the `Tf` operators actually select, not which the resource
  dictionary lists. The reference keeps resource-based twins of each check
  and marks them `#[cfg(test)]`; only the usage-based ones are here.

  **The existing `--detector` probe never touches a document** — it feeds
  constructed `PageAnalysis` values to `page_ocr_reasons`. So this wave
  added `--pagefonts` to the vendored oracle: one line per page, the used
  font count and the three verdicts. It found a defect within a minute of
  first running. `document.value` *resolves* references, so
  `descriptor["FontFile2"]?.asReference` — written as `document.value(…)` —
  was always nil, and every embedded font program looked absent. Two corpus
  documents that should have read their own `cmap` were being called
  undecodable. The fix is to read the entry raw, as the reference's `.get()`
  does.

  Four documents were built for this, because **every other document in the
  corpus answers `1 0 0 1`** — one font, decodable. Without them the probe
  would pass on a port that always said so. The suite asserts the verdict
  *distribution*, not just agreement, for that reason.

  **The fourth was withdrawn in the same wave, and that is the finding worth
  keeping.** An undecodable Identity-H font beside a readable one tests the
  `and nothing else` clause — and the port gets that verdict right. But its
  `<0001> Tj` then reaches the decode chain's last resort, which returns the
  bytes as their own code points, putting a literal NUL and SOH into the
  Markdown where the reference emits nothing. The reference's ladder skips
  unmapped bytes below `0x20`. One document, three suites failing, and the
  fix is a ladder that has not been read yet — so the document is withdrawn
  with its reason recorded in the generator, rather than carried broken or
  hidden behind an exception set. Wave 120 ports the ladder and restores it.

  Still unported from `analyze_page_content`: the XObject recursion, the
  image analysis, and the path/text operator statistics that feed
  `has_vector_text`. The font fields are complete; the struct is not.

- **Wave 120 — the decode ladder's last rung, and the eleventh gap.**
  Control bytes dropped rather than rendered; **70 of 70** byte-identical,
  and the document wave 119 withdrew is back.

  Wave 119 left a specific debt: an undecodable font's `<0001> Tj` reached
  the decode chain's last resort, which returned the bytes as their own code
  points and wrote a literal NUL and SOH into the Markdown. The rule that
  fixes it is one line — **a byte below `0x20` is dropped, not rendered** —
  and finding it took measurement rather than reading.

  Reading was tried first and failed. Tracing `[0x00, 0x01]` down the
  reference's ladder, *every* branch either skips or renders those bytes, so
  the code said the reference should print them too. It does not. Four
  one-line experiments settled it: `<0001>` yields nothing, `<4142>` yields
  `AB`, `<00410042>` yields `AB`, `<0041>` yields `A`. Byte-wise, controls
  dropped. A fifth experiment asked whether the rule is CID-specific — a
  *simple* font drawing `41 00 42 02` also gives `AB` — which is the
  difference between a fix that works and one scoped to the case that
  happened to expose it. `decode-control-bytes.pdf` exists to hold that
  answer.

  Wiring it closed the **eleventh connection gap**. `pdfDecodeSingleByteRun`
  and `pdfShouldUseCp1252` were ported waves ago and had no caller: the
  pipeline's last resort was `String(decoding: bytes, as: UTF8.self)`,
  which is neither the Windows-1252 nor the Latin-1 reading the reference
  uses. Both were on wave 116's orphan list, in plain sight, unread.

  The rule is load-bearing on both restored documents — removing it diverges
  two files — and the unit tests pin the boundary at `0x20` itself, since a
  space is text and an off-by-one there would silently join every word.

  What this is really defending is the failure mode PLAN.md §2 names first:
  confident nonsense. Control codes in the output are invisible to a reader
  and are text to every check that does not look. The port now fails loudly
  where it used to fail silently.

- **Wave 121 — `analyze_page_content` completed, and five documents that
  finally test it.** **70 of 70** byte-identical, **75 of 75** on the new
  page-analysis probe with all thirteen fields exercised.

  Wave 119 filled `PdfPageAnalysis`'s font fields and left the rest: image
  analysis, the Form XObject recursion, and the path/text statistics behind
  `has_vector_text`. All three are ported, and the struct now carries the
  reference's full thirteen fields.

  A second oracle probe, `--pageanalysis`, dumps every field per page. It is
  a far stricter check than `--pagefonts`: a miscounted path operator or a
  missed nested XObject shows up here and nowhere else.

  **And it immediately showed the image half was tested by nothing.** Of the
  twelve value fields, only eight ever varied across seventy documents —
  `hasImages`, `hasTemplateImage`, `totalImageArea`, `imageCount` and
  `hasVectorText` were constant, because **the corpus contained no images at
  all**. A whole file, `PdfPageImages.swift`, verified by zero evidence.
  That is the wave-113 lesson arriving by a different road: not a fixture
  carried by another path, but a fixture that never existed. Printing the
  per-field distribution is what caught it, and the probe now reports it
  every run.

  Five documents close it: a small image, one over the 500,000-pixel
  threshold, twelve tiles that are a template only in aggregate, an image
  nested inside a Form XObject that only the recursion finds, and a page of
  1,200 filled outlines with one text operator. Both rules are measured
  load-bearing — removing the tiled-scan rule diverges `image-tiled.pdf`,
  removing the recursion diverges `image-in-form.pdf`.

  **They live in `corpus/detector/`, and the reason is worth recording.**
  The reference's *own* detector calls an image-backed page scanned and
  emits no Markdown for it, while this port — having no document-level
  detector yet — extracts the text that is there. So these documents cannot
  join the end-to-end corpus without reporting a divergence already known
  and not yet fixable. A subdirectory the detector probes read and the
  pipeline suite does not is the honest arrangement: the image fields get
  exercised, and nothing pretends the pipeline matches. The graphics probe
  names them in its existing `unwiredGaps` set, with image extraction named
  as the gap.

  The unit tests were rewritten once. The first draft asserted arithmetic on
  constants — `threshold >= threshold` — and exercised none of the code.
  They now build real documents and run the real walker, and flipping the
  boundary from `>=` to `>` makes one fail.

- **Wave 122 — the document detector.** `detect_from_document` ported;
  **78 of 78** on a third oracle probe, all four kinds and all four OCR
  reasons reached.

  This is the spine PLAN.md named. Waves 119 to 121 built the per-page
  evidence; this weighs it. The reference runs it *before* extraction to
  decide whether extraction is worth attempting, and a port without it
  converts every document as though it were text — including the scans
  where there is no text to convert.

  Four phases, ported in order: classify the document, list the pages a
  mixed document needs OCR for, add pages whose fonts cannot decode what
  they draw, and explain each one. The third phase is the one that matters
  most and the easiest to leave out: it flags pages in a document the first
  phase already called **text-based**, which is the ordinary case of a
  readable file with two unreadable pages. Removing it diverges two corpus
  documents.

  Also ported: the newspaper rule, which recommends OCR for a document that
  extracts cleanly and *reads* badly. Density alone would also catch a
  heavily styled contract, so the discriminator is font changes per text
  operator — a newspaper switches font rarely per unit of prose, a styled
  document constantly.

  **Two branch-coverage gaps, found by asserting the distribution rather
  than the agreement.** The first probe run matched 75 of 75 while never
  producing `mixed` or `no_text`. A two-page document (image page, text
  page) and an empty page reach both.

  **And one boundary that was untested and stayed untested for a while.**
  Flipping `text_ratio >= threshold` to `>` changed nothing across 77
  documents — no document sat on 0.6. The first attempt at one classified
  `mixed` at 0.680 instead: a single large image makes a page a *template*,
  and the template branch pre-empts the ratio branch entirely. Two small
  images per page instead of one large one defeats the scan test, and the
  document lands on `textBased 0.600` — flipping the comparison now moves
  it to `mixed 0.700`.

  That failure also corrected a misreading recorded in the generator: the
  template and text conditions are counted per page and combined at
  *document* level, so one page can supply the template and another the
  text. They do not have to hold together, as the code first suggested.

- **Wave 123 — the detector reaches the pipeline.** **78 of 78**
  byte-identical, up from 70, and the `detector/` subdirectory is gone.

  Wave 122 ported the classifier; this wires it in. `pdfMarkdown` now
  detects first, and a **scanned or image-based document returns nothing at
  all** rather than the stray caption extraction would scrape off it. That
  fragment is the worse outcome: emitting nothing says the document needs
  OCR, emitting three words says here is your document.

  The measurable result is that wave 121's compromise dissolved. Eight
  documents had been quarantined in `corpus/detector/` because the
  reference's own detector called them scanned while this port extracted
  their text — a divergence known and unfixable at the time. With the
  detector wired, all eight match, so the subdirectory, the split in
  `gen-pdf-oracles.sh` and the two-directory scan in three probe suites all
  came back out. The five image documents are load-bearing: disabling the
  short-circuit diverges exactly those five.

  Two things were investigated and left alone deliberately. `mixed` still
  extracts normally — the reference's invisible-text retry, which unlocks
  OCR layers behind scanned images when the first attempt yields garbage,
  needs an extraction variant this port does not have and is its own wave.
  And `ratio-exactly-threshold.pdf` renders as a bare newline on **both**
  sides despite the detector seeing three pages of prose; the two agree
  exactly, so the fixture is sound and the cause is somewhere in the writer,
  noted rather than chased.

  One test expectation was wrong about the reference rather than the port:
  an image page with **no text operator at all** is `scanned`, not
  `imageBased`. The two differ by precisely that, and the corpus's
  `image-small.pdf` sits in the other class only because it carries a
  caption.

- **Wave 124 — the invisible-text retry, not ported; the detector's result,
  exposed.** **78 of 78** byte-identical, 1672 tests.

  This wave set out to port `process_document`'s retry: when a *mixed*
  document extracts to garbage or nothing, the reference re-extracts with
  invisible (`Tr 3`) text included, which is how an OCR layer behind a
  scanned image gets recovered. `pdfIsGarbageText` was already ported and
  the extractor already takes an `includeInvisible` flag, so the work looked
  like threading one parameter.

  **It was not ported, because it could not be verified.** Four documents
  were built to make the reference exercise it — a scanned page with an
  invisible OCR layer, the same as a two-page mixed document, the text moved
  off the image, and a visible-text control. The control confirms the text
  is extractable and the classification is `mixed 0.650`, so the retry's
  precondition holds; every invisible variant still produces **empty**
  output from the reference. Either the retry is dead in this version or
  something downstream discards what it recovers.

  Porting it anyway would have meant shipping a change with no measurement
  behind it — the position wave 116 recorded and wave 118 resolved by
  measuring instead of guessing. So it stays unported, with the four
  experiments recorded here so the next attempt starts from them rather than
  repeating them.

  The wave pivoted to something the detector made newly worth doing.
  `AnyDoc.markdown` returns a bare `String`, so a scanned document and an
  empty one are indistinguishable — both `""`. That was cosmetic before wave
  123 and a real gap after it, since the port now *knows* the difference and
  was throwing it away. `AnyDoc.inspectPdf` and
  `AnyDoc.markdownInspectingPdf` expose the classification, the confidence,
  the title, and the per-page OCR reasons, with `isUnreadableWithoutOcr` for
  the question the string cannot answer.

  Deliberately not `markdown.isEmpty`: an empty page is *readable* and has
  nothing on it, and its reason is `no_text` rather than `scanned`. Sending
  it to OCR would be wasted work, and the tests pin that distinction.

  `pdfConvert` now returns both, so a caller wanting the pair pays for one
  content scan rather than two.

- **Wave 125 — image extraction, and the last of `unwiredGaps`.**
  **78 of 78** byte-identical, and the graphics probe's image exemptions are
  gone.

  A `Do` on an image XObject now leaves a **positional placeholder** in the
  item stream — `[Image: Im0]`, at the box the transform paints into. Six
  corpus documents whose item dumps had been exempted since wave 121 now
  match the reference exactly, and disabling the collection breaks all six.

  The box is the **unit square's four corners** transformed and bounded, not
  two corners scaled. A negative scale is how a producer flips an image and
  is common in real documents; two corners would give it a negative width.
  A rotation puts no corner at the box's corner at all. Both are pinned.

  **The image is inside a Form XObject in one document, and that found a
  real hole.** `pdfPageOperationsWithForms` inlines a form's content stream,
  which brings its `Do` operators along while leaving their names defined in
  the *form's* resources — so a page whose only figure sits inside a form
  loses it. The name collection recurses for that reason. Five of six
  documents passed before the recursion was added, which is exactly how a
  gap like this survives.

  Two consequences had to be handled rather than papered over. Images
  reaching the *text* stream merged with neighbouring prose and landed in
  the Markdown as a literal `[Image: Im0]`; the reference partitions them at
  the top of its writer, before any layout, and renders them only when
  `include_images` is set — which it is not by default. And a geometry
  invariant asserting `fontSize > 0` for every run now excludes images,
  which carry a box rather than a baseline.

  This also sets `PdfLayoutItem.isImage`, the one claim from wave 113's
  stale-comment sweep that was **true**: nothing had ever set it. The column
  detector already filtered on it, so it had been quietly reading figure
  placeholders as text for as long as it had existed — except that no
  placeholder existed either, which is why nothing showed. The image regions
  are collected alongside, for the chart masking that is still to come.

  The composition trap appeared for the third session running, and the
  pattern is now unmistakable: a fixture built to *look like* the case
  under test is carried by some other path more often than not. The
  discipline that catches it is cheap — disable the thing under test and
  re-measure — and it is the only reason waves 113 to 115 have honest
  numbers.
