#!/usr/bin/env python3
"""Generate Sources/AnyDoc/Encoding/Codepages.swift.

The legacy single-byte code pages RTF (`\\ansicpg`, `\\fcharset`) and binary
DOC select are pure data. anydoc decodes them through `encoding_rs`, whose
tables are generated from the WHATWG Encoding Standard's index files; this
script reads those same tables straight out of a vendored `encoding_rs`
checkout so the Swift port cannot drift from the reference by a code point.

usage: scripts/gen-encoding-tables.py [path/to/encoding_rs/src/data.rs]

With no argument the newest encoding_rs in the local cargo registry is used.
Re-run it only when the pinned encoding_rs version changes; the generated
file is committed.
"""
import glob
import os
import re
import sys

# The pages anydoc's `charset_encoding` and `codepage_encoding` can select.
# Multi-byte pages (shift_jis, gbk, euc-kr, big5) are not single-byte tables
# and are not emitted here.
WANTED = [
    ("windows_874", "windows874", "windows-874"),
    ("windows_1250", "windows1250", "windows-1250"),
    ("windows_1251", "windows1251", "windows-1251"),
    ("windows_1252", "windows1252", "windows-1252"),
    ("windows_1253", "windows1253", "windows-1253"),
    ("windows_1254", "windows1254", "windows-1254"),
    ("windows_1255", "windows1255", "windows-1255"),
    ("windows_1256", "windows1256", "windows-1256"),
    ("windows_1257", "windows1257", "windows-1257"),
    ("windows_1258", "windows1258", "windows-1258"),
]

OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Sources/AnyDoc/Encoding/Codepages.swift",
)


def find_data_rs():
    if len(sys.argv) > 1:
        return sys.argv[1]
    matches = sorted(
        glob.glob(os.path.expanduser("~/.cargo/registry/src/*/encoding_rs-*/src/data.rs"))
    )
    if not matches:
        sys.exit(
            "no encoding_rs found in the cargo registry; pass the path to its src/data.rs"
        )
    return matches[-1]


def parse_tables(text):
    """Pull each `name: [ 0x…, … ],` array out of the SINGLE_BYTE_DATA static."""
    start = text.index("pub static SINGLE_BYTE_DATA")
    body = text[start:]
    tables = {}
    for field, _, _ in WANTED:
        match = re.search(r"\b%s:\s*\[(.*?)\],\s*\n" % re.escape(field), body, re.S)
        if not match:
            sys.exit("field %s not found in data.rs" % field)
        values = [int(v, 16) for v in re.findall(r"0x([0-9A-Fa-f]{4})", match.group(1))]
        if len(values) != 128:
            sys.exit("field %s has %d entries, expected 128" % (field, len(values)))
        tables[field] = values
    return tables


def emit(tables):
    lines = [
        "/// Legacy single-byte code pages. GENERATED — do not edit.",
        "///",
        "/// Regenerate with `scripts/gen-encoding-tables.py`. Each table maps bytes",
        "/// 0x80...0xFF to a scalar value; `0` marks a position the code page leaves",
        "/// unmapped, which decodes to U+FFFD (the reference's lossy `decode`).",
        "/// Bytes below 0x80 are ASCII in every one of these pages.",
        "",
        "extension LegacyEncoding {",
    ]
    for field, swift_name, label in WANTED:
        values = tables[field]
        lines.append("    /// %s" % label)
        lines.append(
            "    static let %s = LegacyEncoding(name: \"%s\", high: [" % (swift_name, label)
        )
        for row in range(0, 128, 8):
            chunk = ", ".join("0x%04X" % v for v in values[row : row + 8])
            lines.append("        %s," % chunk)
        lines.append("    ])")
        lines.append("")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    path = find_data_rs()
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    tables = parse_tables(text)
    with open(OUT, "w", encoding="utf-8") as handle:
        handle.write(emit(tables))
    print("wrote %s from %s" % (OUT, path))


if __name__ == "__main__":
    main()
