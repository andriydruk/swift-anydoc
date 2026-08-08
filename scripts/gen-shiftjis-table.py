#!/usr/bin/env python3
"""Generate Sources/AnyDoc/Encoding/ShiftJis.swift.

The WHATWG shift_jis decoder turns a lead/trail byte pair into a pointer and
looks that pointer up in `index jis0208`. This script recovers that index by
asking `encoding_rs` — the library anydoc decodes with — what every valid
byte pair means, so the Swift table cannot drift from the reference.

usage:
    cd scripts/dump-cjk-tables && cargo run --release > /tmp/cjk.txt
    scripts/gen-shiftjis-table.py /tmp/cjk.txt

Re-run only when the pinned encoding_rs version changes; the generated file
is committed.
"""
import os
import sys

OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Sources/AnyDoc/Encoding/ShiftJis.swift",
)
# The index has 11104 entries; pointers at or past it are unmapped.
INDEX_LEN = 11104


def load_doubles(path, label):
    """The (lead, trail) -> scalar map for one encoding out of the dump."""
    out = {}
    section = None
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line.startswith("#"):
                kind, name = line[1:].split()
                section = (kind, name)
                continue
            if section != ("DOUBLE", label):
                continue
            lead, trail, value = (int(v) for v in line.split())
            out[(lead, trail)] = value
    return out


def pointer(lead, trail):
    """WHATWG shift_jis: the index pointer a byte pair denotes."""
    if not (0x40 <= trail <= 0x7E or 0x80 <= trail <= 0xFC):
        return None
    lead_offset = 0x81 if lead < 0xA0 else 0xC1
    offset = 0x40 if trail < 0x7F else 0x41
    return (lead - lead_offset) * 188 + trail - offset


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    doubles = load_doubles(sys.argv[1], "shift_jis")
    if not doubles:
        sys.exit("no shift_jis double-byte data in the dump")

    index = [0] * INDEX_LEN
    for (lead, trail), value in doubles.items():
        if not (0x81 <= lead <= 0x9F or 0xE0 <= lead <= 0xFC):
            continue
        p = pointer(lead, trail)
        if p is None or not (0 <= p < INDEX_LEN):
            # 8836..10715 is the private-use range the decoder computes
            # arithmetically rather than looking up.
            continue
        if 8836 <= p <= 10715:
            continue
        if value > 0xFFFF:
            sys.exit("index entry above the BMP at pointer %d" % p)
        index[p] = value

    lines = [
        "/// The WHATWG `index jis0208` table. GENERATED — do not edit.",
        "///",
        "/// Regenerate with `scripts/gen-shiftjis-table.py`. `0` marks a pointer the",
        "/// index leaves unmapped, which decodes to U+FFFD.",
        "",
        "let jis0208Index: [UInt16] = [",
    ]
    for row in range(0, INDEX_LEN, 12):
        chunk = ", ".join("0x%04X" % v for v in index[row : row + 12])
        lines.append("    %s," % chunk)
    lines.append("]")
    with open(OUT, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    mapped = sum(1 for v in index if v)
    print("wrote %s (%d of %d pointers mapped)" % (OUT, mapped, INDEX_LEN))


if __name__ == "__main__":
    main()
