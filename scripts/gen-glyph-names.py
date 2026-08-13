"""Generate Sources/AnyDoc/Pdf/PdfGlyphNamesTable.swift from the reference.

The Adobe Glyph List is a published table, but the reference carries its own
copy with its own additions and omissions — so the port takes *that* copy,
parsed straight out of `glyph_names.rs`, rather than the published list. A
freshly fetched AGL would differ, and every difference would be a divergence.

Sorted parallel arrays rather than a dictionary literal: 4,500 entries of
`[String: Unicode.Scalar]` take minutes to type-check, while a string array
and an integer array compile at once. Lookups binary-search.

    scripts/gen-glyph-names.py <path-to-glyph_names.rs>
"""

import argparse
import os
import re

ENTRY = re.compile(
    r"""m\.insert\("([^"]+)",\s*'((?:\\u\{[0-9A-Fa-f]+\}|\\x[0-9A-Fa-f]{2}|\\.|[^'])+)'\)""")

ESCAPES = {
    "\\\\": 0x5C,
    "\\'": 0x27,
    '\\"': 0x22,
    "\\n": 0x0A,
    "\\r": 0x0D,
    "\\t": 0x09,
    "\\0": 0x00,
}


def scalar_of(literal: str) -> int:
    """The codepoint a Rust char literal body denotes."""
    if literal.startswith("\\u{"):
        return int(literal[3:-1], 16)
    if literal.startswith("\\x"):
        return int(literal[2:], 16)
    if literal in ESCAPES:
        return ESCAPES[literal]
    if len(literal) == 1:
        return ord(literal)
    raise ValueError(f"unrecognised char literal: {literal!r}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    arguments = parser.parse_args()

    entries = {}
    with open(arguments.source, encoding="utf-8") as handle:
        for line in handle:
            match = ENTRY.search(line)
            if match:
                entries[match.group(1)] = scalar_of(match.group(2))

    names = sorted(entries)
    out = [
        "/// Adobe Glyph List mappings, generated — do not edit.",
        "///",
        "/// Produced by `scripts/gen-glyph-names.py` from the reference's own",
        "/// `glyph_names.rs`, not from the published Adobe Glyph List: the reference",
        "/// carries its own copy with its own additions, and every difference between",
        "/// the two would be a divergence.",
        "///",
        "/// Sorted parallel arrays rather than a dictionary — a dictionary literal this",
        "/// size takes minutes to type-check. Lookups binary-search `pdfGlyphNames`.",
        "",
        "let pdfGlyphNames: [String] = [",
    ]
    for start in range(0, len(names), 6):
        chunk = ", ".join(f'"{name}"' for name in names[start:start + 6])
        out.append(f"    {chunk},")
    out.append("]")
    out.append("")
    out.append("/// The scalar each name maps to, in the same order.")
    out.append("let pdfGlyphScalars: [UInt32] = [")
    values = [entries[name] for name in names]
    for start in range(0, len(values), 12):
        chunk = ", ".join(str(v) for v in values[start:start + 12])
        out.append(f"    {chunk},")
    out.append("]")
    out.append("")

    path = os.path.join("Sources", "AnyDoc", "Pdf", "PdfGlyphNamesTable.swift")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out))
    print(f"{path}: {len(names)} glyph names")


if __name__ == "__main__":
    main()
