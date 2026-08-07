# Fixture corpus

Copied verbatim from [firecrawl/anydoc](https://github.com/firecrawl/anydoc)
(`tests/fixtures/`, v0.1.7, MIT license). The matching expected outputs live in
`../Golden/`, converted from anydoc's insta snapshots by
`scripts/import-goldens.py`. These files are the executable specification this
port is validated against; do not edit them by hand.

Naming conventions inherited from upstream:

- `malformed/name--<outcome>.ext` — the outcome after `--` is the specified
  behavior on that malformed input: `recovers`, `skips`, `ignores`, `errors`.
- `abuse/` — resource-abuse shapes, exercised by dedicated limit tests, not by
  the snapshot sweep.
