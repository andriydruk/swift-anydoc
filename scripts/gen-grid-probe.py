#!/usr/bin/env python3
"""Generate table-grid probe cases and the reference's answers.

`tables/grid.rs` decides where a table's columns and rows are by clustering
positions, and the threshold it picks depends on the shape of the gap
distribution — three branches, chosen by item count and by how bimodal the
gaps are. Those branches are impossible to reach from a hand-written example
by accident, so the cases are generated to hit each one, plus a random tail.

    scripts/gen-graphics-oracle.sh /tmp/oracle
    python3 scripts/gen-grid-probe.py /tmp/probe --oracle /tmp/oracle
    ANYDOC_GRID_PROBE=/tmp/probe swift test --filter PdfGridProbe

Each case is a block of `x y width font_size text` lines; blocks are
separated by a line of `---`.
"""

import argparse
import os
import random
import subprocess


def item(x, y, width, size, text):
    return f"{x:g} {y:g} {width:g} {size:g} {text}"


def cases(random_count):
    out = []

    # A plain three-column table.
    block = []
    for row, cells in enumerate(
        [("Name", "Qty", "Price"), ("Widget", "12", "3.50"), ("Gadget", "7", "9.99")]
    ):
        for column, text in enumerate(cells):
            block.append(item(100 + column * 100, 700 - row * 15, 40, 10, text))
    out.append(block)

    # Columns closer together than the 25pt floor, which the default
    # threshold cannot separate.
    block = []
    for row in range(4):
        for column in range(5):
            block.append(item(100 + column * 20, 700 - row * 12, 15, 9, f"c{column}r{row}"))
    out.append(block)

    # A strong bimodal signal with few items: tight within a column, wide
    # between. Should take the lowered threshold without over-splitting.
    block = []
    for row in range(5):
        for column in range(3):
            base = 100 + column * 120
            block.append(item(base, 700 - row * 14, 30, 10, f"a{row}"))
            block.append(item(base + 3, 700 - row * 14, 30, 10, f"b{row}"))
    out.append(block)

    # A wrapped header sitting slightly left of a numeric column, which the
    # merge pass should pull back together.
    block = [item(100, 700, 40, 10, "Item"), item(196, 700, 40, 10, "Total")]
    for row in range(8):
        block.append(item(100, 685 - row * 14, 40, 10, f"row{row}"))
        block.append(item(200, 685 - row * 14, 30, 10, f"{row}.50"))
    out.append(block)

    # Prose: everything at the left margin. The body-font pass must reject it
    # and the small-font pass must not.
    block = [item(72, 700 - line * 14, 300, 10, f"line{line}") for line in range(12)]
    out.append(block)

    # A dense table over the 500-item threshold, which switches the clustering
    # to edge-based.
    block = []
    for row in range(24):
        for column in range(24):
            block.append(item(50 + column * 22, 700 - row * 12, 16, 8, f"{row}-{column}"))
    out.append(block)

    # Cell joining: hyphens, brackets, and a subscript returning to full size.
    out.append(
        [
            item(100, 700, 20, 10, "co-"),
            item(120, 700, 20, 10, "operate"),
            item(150, 700, 10, 10, "("),
            item(160, 700, 20, 10, "note"),
            item(180, 700, 10, 10, ")"),
            item(200, 700, 10, 10, "H"),
            item(210, 697, 5, 6, "2"),
            item(215, 700, 10, 10, "O"),
            item(230, 700, 10, 10, "-"),
            item(240, 700, 20, 10, "dash"),
        ]
    )

    # Shapes the detector must reject: a key-value list, prose broken across
    # a false grid with hyphenated word breaks, and letterspaced display text.
    out.append(
        [
            item(100, 700 - r * 14, 60, 10, lbl)
            for r, lbl in enumerate(["Name:", "Date:", "Total:", "Status:", "Owner:"])
        ]
        + [
            item(200, 700 - r * 14, 40, 10, v)
            for r, v in enumerate(["Widget", "2026", "12", "open", "me"])
        ]
    )
    out.append(
        [
            item(100 + c * 90, 700 - r * 14, 80, 10, w)
            for r in range(12)
            for c, w in enumerate(["a long sentence frag-", "ment continuing here"])
        ]
    )
    out.append(
        [
            item(100 + c * 90, 700 - r * 14, 80, 10, "l e t t e r s p a c e d")
            for r in range(6)
            for c in range(2)
        ]
    )

    # Single item, and a pair — the degenerate shapes.
    out.append([item(100, 700, 40, 10, "alone")])
    out.append([item(100, 700, 40, 10, "left"), item(400, 700, 40, 10, "right")])

    generator = random.Random(20260809)
    words = ["alpha", "12", "3.50", "-", "1,234.00", "Total", "x", "+5%", "(a)", "beta"]
    for _ in range(random_count):
        block = []
        columns = generator.randint(1, 6)
        rows = generator.randint(1, 8)
        spacing = generator.choice([15, 22, 40, 80, 130])
        leading = generator.choice([9, 12, 14, 20])
        size = generator.choice([6, 8, 10, 12])
        for row in range(rows):
            for column in range(columns):
                jitter = generator.choice([0, 0, 0, 1, -1, 4, -4])
                block.append(
                    item(
                        100 + column * spacing + jitter,
                        700 - row * leading + generator.choice([0, 0, 1, -1]),
                        generator.randint(5, 40),
                        size,
                        generator.choice(words),
                    )
                )
        out.append(block)
    return out


def format_cases(random_count):
    """Cell grids for the formatter: continuation rows and the four shapes
    that look like one but must not be merged, footnotes, and the contents
    forms."""
    out = [
        [["Item", "Qty", "Price"], ["Widget", "12", "3.50"], ["", "overflow text", ""]],
        [["A", "B", "C"], ["x", "1", "2"], ["(1) a footnote", "", ""]],
        [["A", "B", "C"], ["x", "1", "2"], ["2) another footnote", "", ""]],
        [["A", "B", "C"], ["x", "1", "2"], ["Note: see below", "", ""]],
        # A short sub-header, not overflow.
        [["Month", "Val", "Pct"], ["Jan", "1", "2"], ["", "FEB", ""]],
        # A data row with a spanned first column.
        [["A", "B", "C", "D"], ["x", "1", "2", "3"], ["", "4", "5", "6"]],
        # A hierarchical sub-row.
        [["6 Section", ""], ["6.1 Part", ""], ["", "6.2.1 Sub"]],
        # A bare section label in a wide table.
        [["A", "B", "C"], ["x", "1", "2"], ["Results And Notes", "", ""]],
        # A wrapped first-column label continuing from an incomplete phrase.
        [["A", "B", "C"], ["costs and", "1", "2"], ["overheads", "", ""]],
        # Contents shapes.
        [["Introduction", "....", "3"], ["Methods", "....", "vii"], ["Results", "", "5-21"]],
        [["Title only", "", ""], ["", "", "42"]],
        [[""]],
        [["only one cell"]],
    ]

    # Contents shapes that actually trip each classifier. Without these the
    # random tail only ever produces dot-leader listings, and the other two
    # branches are compared vacuously.
    titles = [
        "Introduction To The Subject", "Materials And Methods", "Results",
        "Discussion Of Findings", "Conclusions", "Appendix A", "References",
        "Acknowledgements", "Further Reading",
    ]
    # Page-number listing: no leaders, ascending pages that span the document.
    out.append([[titles[i % len(titles)], str(3 + i * 7)] for i in range(8)])
    # The same shape with a dense consecutive run, which needs the titles to
    # read like headings before it is accepted.
    out.append([[titles[i % len(titles)], str(10 + i)] for i in range(8)])
    # And with short labels, which should be rejected as a rank column.
    out.append([[f"Rank{i}", str(10 + i)] for i in range(8)])
    # Front-matter roman numerals.
    out.append(
        [[titles[i % len(titles)], r] for i, r in enumerate(["i", "ii", "iv", "vii", "ix", "xii"])]
    )
    # A two-column numeric data table, which must NOT be a listing.
    out.append([[f"Mineral{i}", str(100 + i * 3)] for i in range(8)])
    # Tabular listing: dotted section numbers, page numbers last.
    out.append([[f"{1 + i // 3}.{1 + i % 3} Section Title", str(4 + i * 5)] for i in range(9)])
    # The same, but with a non-numeric last column, which must be rejected.
    out.append([[f"{1 + i // 3}.{1 + i % 3} Section Title", "n/a"] for i in range(9)])

    generator = random.Random(97531)
    # Randomised listings around the thresholds, so the accept/reject edges
    # are compared rather than only the clear cases.
    for _ in range(random_count // 4):
        rows = generator.randint(3, 9)
        style = generator.choice(["page", "tabular", "mixed"])
        block = []
        page = generator.randint(1, 40)
        for i in range(rows):
            page += generator.choice([0, 1, 1, 2, 7, -3])
            if style == "page":
                label = generator.choice(titles)
            elif style == "tabular":
                label = f"{1 + i // 3}.{1 + i % 3} {generator.choice(titles)}"
            else:
                label = generator.choice(titles + ["X", "Rank1", "1973"])
            tail = generator.choice([str(max(page, 1)), "vii", "A-1", "n/a", ""])
            block.append([label, tail])
        out.append(block)

    pieces = [
        "", "x", "12", "3.50", "....", "Total", "Note: x", "(2) note", "3)",
        "Results And Notes", "costs and", "overheads", "6.2.1 Sub", "JAN", "vii",
        "A-1", "long descriptive continuation text", "Item Name",
    ]
    for _ in range(random_count):
        columns = generator.randint(1, 5)
        rows = generator.randint(1, 7)
        out.append(
            [[generator.choice(pieces) for _ in range(columns)] for _ in range(rows)]
        )
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory")
    parser.add_argument("--oracle", required=True, help="work dir from gen-graphics-oracle.sh")
    parser.add_argument("--cases", type=int, default=400)
    arguments = parser.parse_args()

    probe = os.path.join(arguments.oracle, "pdfinspector", "target", "release", "graphicsprobe")
    if not os.path.exists(probe):
        raise SystemExit(f"oracle binary not found: {probe}\nrun scripts/gen-graphics-oracle.sh")

    os.makedirs(arguments.directory, exist_ok=True)
    blocks = cases(arguments.cases)

    with open(os.path.join(arguments.directory, "grid-cases.txt"), "w", encoding="utf-8") as f:
        f.write("\n---\n".join("\n".join(block) for block in blocks) + "\n")

    answers = []
    for block in blocks:
        result = subprocess.run(
            [probe, "--grid"],
            input="\n".join(block) + "\n",
            capture_output=True,
            text=True,
            check=True,
        )
        answers.append(result.stdout.rstrip("\n"))
    with open(os.path.join(arguments.directory, "grid-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n---\n".join(answers) + "\n")

    # The detector runs over the same positional cases as the grid probe —
    # they already cover the clustering branches — plus prose and key-value
    # shapes it must reject.
    detect_answers = []
    for block in blocks:
        result = subprocess.run(
            [probe, "--detect"],
            input="\n".join(block) + "\n",
            capture_output=True,
            text=True,
            check=True,
        )
        detect_answers.append(result.stdout)
    with open(os.path.join(arguments.directory, "detect-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n---\n".join(detect_answers))

    fmt_blocks = format_cases(arguments.cases)
    with open(os.path.join(arguments.directory, "format-cases.txt"), "w", encoding="utf-8") as f:
        f.write("\n---\n".join("\n".join("\t".join(r) for r in b) for b in fmt_blocks) + "\n")

    fmt_answers = []
    for block in fmt_blocks:
        result = subprocess.run(
            [probe, "--format"],
            input="\n".join("\t".join(r) for r in block) + "\n",
            capture_output=True,
            text=True,
            check=True,
        )
        fmt_answers.append(result.stdout)
    with open(os.path.join(arguments.directory, "format-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n---\n".join(fmt_answers))

    print(
        f"{len(blocks)} grid cases and {len(fmt_blocks)} format cases; "
        f"oracle answers written to {arguments.directory}"
    )


if __name__ == "__main__":
    main()
