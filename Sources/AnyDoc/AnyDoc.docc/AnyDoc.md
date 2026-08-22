# ``AnyDoc``

Convert documents to GitHub-Flavored Markdown.

## Overview

One call converts a file:

```swift
import AnyDoc

let markdown = try AnyDoc.markdown(contentsOf: "report.docx")
```

Every format parses into a shared document model — ``Document``, ``Block``,
``Table`` — and renders through a single Markdown serializer, so a heading is a
heading whether it arrived from `.docx`, `.odt` or `.rtf`. PDF is the exception:
it converts straight to Markdown and has no document-model form, because its
input has no document structure to recover, only glyphs at coordinates.

This is a port of [firecrawl/anydoc](https://github.com/firecrawl/anydoc), and
the Rust crate is treated as an executable specification rather than as
inspiration. Output is validated byte-for-byte against it. Where the reference
has a bug, this port reproduces it deliberately and records why at the call
site — matching the reference matters more than being independently right,
because a caller migrating between the two should see no difference at all.

## Choosing a format

Pass `nil` and the format is detected from the content itself:

```swift
let markdown = try AnyDoc.markdown(bytes)              // detect
let markdown = try AnyDoc.markdown(bytes, format: .csv) // name it
```

Detection reads the signature each container specification designates, never
the extension. That means CSV cannot be detected — delimited text carries no
signature — so it must be named. ``Format/detect(from:)`` returns `nil` for it,
and ``AnyDoc/markdown(contentsOf:)`` falls back to the extension for exactly
this case.

## Errors

``ConvertError`` means conversion was impossible, not merely lossy: unreadable
or structurally unusable input, encryption, or a fixed limit crossed. A document
that converts to nothing useful — an empty spreadsheet, a slide of images —
succeeds and returns what it has. Callers wanting to distinguish "no text" from
"no conversion" should check the result, not catch an error.

## Topics

### Converting

- ``AnyDoc``
- ``Format``
- ``ConvertError``
- ``IOError``

### The document model

A ``Document`` is a list of ``Block``s. Blocks carry ``Inline`` runs, which are
the styled text spans; ``inlinesToPlainText(_:)`` flattens a run when only the
text matters.

- ``Document``
- ``Block``
- ``Inline``
- ``Style``
- ``inlinesToPlainText(_:)``
- ``inlinesAreEmpty(_:)``

### Lists and notes

- ``List``
- ``ListItem``
- ``MarkerKind``
- ``Note``
- ``NoteKind``

### Tables

- ``Table``
- ``TableKind``
- ``Cell``
- ``CellSlot``

### Links, images and assets

Binary payloads are not decoded. An ``Asset`` holds the bytes as the container
stored them, keyed by ``AssetId``; ``ImageSource`` says whether an image points
at one of those or at an external URL.

- ``LinkTarget``
- ``AnchorId``
- ``ImageSource``
- ``Asset``
- ``AssetId``

### Rendering

- ``documentToMarkdown(_:)``

### PDF

PDF bypasses the document model. ``PdfInspection`` reports what the conversion
found — page count, what kind of document it turned out to be, and whether OCR
would recover anything the text layer does not already give. A scanned page and
a blank one both convert to an empty string, so a caller holding only that
string cannot tell "this needs OCR" from "there was nothing here"; the
inspection is what separates them.

- ``PdfInspection``
