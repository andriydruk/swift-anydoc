# Versioning

Semantic Versioning 2.0.0, with one addition this package needs: **the Markdown
it produces is part of the contract, not just the API that produces it.**

## Why the output counts

A caller depends on this package to turn a document into Markdown. If a release
keeps every signature identical but starts emitting a different string for the
same input, nothing the compiler checks has changed and everything the caller
cares about has. Snapshot tests downstream break; diffs churn; a pipeline that
compared yesterday's output to today's reports changes that no document made.

So a version bump is decided by two surfaces, and the larger of the two wins.

## What counts as breaking (major)

**API.** Removing or renaming a public symbol; changing a signature, an
associated value, or a stored property's type; adding a case to a public
non-frozen enum that callers switch over exhaustively — ``Format``, ``Block``,
``Inline``, ``LinkTarget``, ``TableKind``, ``CellSlot``, ``ImageSource``,
``MarkerKind``, ``NoteKind``.

**Output.** Any change to the Markdown produced for an input that already
converted successfully — including whitespace, escaping and ordering. The
snapshot corpus is the record of what that output is; a diff there in a release
that is not a major bump is a bug in the release, not in the corpus.

**Errors.** Turning a case that succeeded into a thrown error.

## What counts as a feature (minor)

- A new public symbol, or a new case on an enum callers are not expected to
  switch exhaustively.
- **A format, or a construct within one, that previously produced nothing and
  now produces Markdown.** This is the common case: it changes output, but only
  where output was absent, so no existing successful conversion moves. `.xlsb`
  support would land here.
- A file that previously threw and now converts.

## What counts as a fix (patch)

- Performance, memory, internal restructuring.
- Crash, hang and resource-exhaustion fixes.
- **A correction that moves output toward the reference.** These are the
  awkward ones: they change the Markdown for an input that already converted,
  which the rule above calls breaking. They are treated as patches anyway,
  because this package's stated definition of correct is "byte-identical to
  firecrawl/anydoc" — output that disagreed with the reference was never the
  contract, it was a defect against it. Every such change names the divergence
  it closes in the changelog, so a caller pinning behaviour can see exactly
  what moved and why.

That exception is deliberately narrow. It covers *converging on the reference*,
never *diverging from it by choice*: a change that makes output differ from the
reference for a reason of our own is breaking, whatever its merits.

## Reference version

Releases record which `firecrawl/anydoc` version they were validated against
(`v0.1.7` today). Retargeting a newer reference is a major bump whenever the
reference's own output changed, because ours changes with it.

## Before 1.0

`0.x` releases carry no compatibility promise. The public surface is still
being decided — see the open question about `inlinesAreEmpty` in PLAN.md — and
pre-1.0 is the free moment to settle it. Everything above takes effect at 1.0.

## Tag format

Tags are bare — `1.2.0`, not `v1.2.0`. The release workflow looks the tag name
up in `CHANGELOG.md` verbatim, so a `v`-prefixed tag would search for
`## [v1.2.0]`, find nothing, and fail the release. The trigger only matches
bare tags, so a mistyped one does nothing at all rather than publishing
something wrong.

Releasing is therefore: add the version's section to `CHANGELOG.md`, commit,
tag, push the tag. The workflow re-verifies from a clean checkout on Linux and
macOS before it publishes anything.
