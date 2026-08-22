# Changelog

Format per [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
per [docs/VERSIONING.md](docs/VERSIONING.md), which extends SemVer to cover the
Markdown output as well as the API.

## [Unreleased]

Nothing released yet — the package is untagged. This section accumulates until
the first tag.

### Added
- All 14 formats: csv, docx, doc, pptx, ppt, xlsx, xls, odt, ods, odp, rtf,
  epub, pdf. Validated byte-for-byte against `firecrawl/anydoc` v0.1.7.
- `AnyDoc.markdown(contentsOf:)`, `AnyDoc.markdown(_:format:)` and
  `AnyDoc.document(_:format:)`; the shared document model; `PdfInspection`.
- DocC catalog covering the public surface.

### Known limitations
- `.xlsb` is recognised but unported and fails as malformed; the reference
  reaches it through `calamine` and no fixture on either side exercises it.
- PDF encryption is supported for the handlers the reference implements.
