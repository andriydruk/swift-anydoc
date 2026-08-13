"""Turn the nfkcdump output into Sources/AnyDoc/Pdf/PdfNfkcTables.swift.

Flat integer arrays rather than dictionary literals: a Swift dictionary
literal of several thousand entries takes minutes to type-check, while an
array of integers compiles immediately. The lookups binary-search instead.
"""

import argparse
import os

HEADER = '''/// Unicode normalisation tables, generated — do not edit.
///
/// Produced by `scripts/gen-nfkc-tables.sh` from `unicode-normalization`, the
/// crate the reference itself uses, so the data matches its Unicode version
/// ({version}) exactly rather than whatever a local Python happens to carry.
///
/// Hangul is absent on purpose: its decomposition and composition are
/// arithmetic, and tabulating 11,172 syllables would add nothing. See
/// `PdfNfkc.swift`.
///
/// Flat arrays rather than dictionaries — a dictionary literal this size takes
/// minutes to type-check, an integer array compiles at once.

'''


def emit(name, values, per_line=12, element="UInt32"):
    lines = [f"let {name}: [{element}] = ["]
    for start in range(0, len(values), per_line):
        chunk = ", ".join(str(v) for v in values[start:start + per_line])
        lines.append(f"    {chunk},")
    lines.append("]")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dump")
    arguments = parser.parse_args()

    version = "unknown"
    decompositions = []          # (cp, [values])
    combining = []               # (cp, ccc)
    pairs = []                   # (starter, combining, composed)

    with open(arguments.dump, encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "VERSION":
                version = " ".join(parts[1:]).strip("()").replace(",", ".").replace(" ", "")
            elif parts[0] == "D":
                decompositions.append(
                    (int(parts[1], 16), [int(v, 16) for v in parts[2:]]))
            elif parts[0] == "C":
                combining.append((int(parts[1], 16), int(parts[2])))
            elif parts[0] == "P":
                pairs.append(
                    (int(parts[1], 16), int(parts[2], 16), int(parts[3], 16)))

    decompositions.sort()
    combining.sort()
    pairs.sort()

    keys = [cp for cp, _ in decompositions]
    offsets = []
    values = []
    for _, expansion in decompositions:
        offsets.append(len(values))
        values.extend(expansion)
    offsets.append(len(values))

    out = [HEADER.format(version=version)]
    out.append("/// Codepoints whose compatibility decomposition differs from themselves.")
    out.append(emit("pdfNfkdKeys", keys))
    out.append("")
    out.append("/// Where each key's expansion starts in `pdfNfkdValues`; one extra entry")
    out.append("/// closes the last range.")
    out.append(emit("pdfNfkdOffsets", offsets))
    out.append("")
    out.append("/// The expansions, concatenated.")
    out.append(emit("pdfNfkdValues", values))
    out.append("")
    out.append("/// Codepoints with a non-zero canonical combining class.")
    out.append(emit("pdfCombiningKeys", [cp for cp, _ in combining]))
    out.append("")
    out.append("/// Their classes, in the same order.")
    out.append(emit("pdfCombiningValues", [ccc for _, ccc in combining]))
    out.append("")
    out.append("/// Composable pairs, keyed by starter and combining mark packed into one")
    out.append("/// value so the search is a single comparison.")
    # A starter and a mark packed together need more than 32 bits once either
    # is astral.
    out.append(
        emit("pdfComposeKeys", [(s << 21 | c) for s, c, _ in pairs], per_line=8,
             element="UInt64"))
    out.append("")
    out.append("/// What each pair composes to.")
    out.append(emit("pdfComposeValues", [r for _, _, r in pairs]))
    out.append("")

    path = os.path.join("Sources", "AnyDoc", "Pdf", "PdfNfkcTables.swift")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out))
    print(
        f"{path}: {len(keys)} decompositions, {len(combining)} combining classes, "
        f"{len(pairs)} pairs (Unicode {version})"
    )


if __name__ == "__main__":
    main()
