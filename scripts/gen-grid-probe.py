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

    # Consolidated financial rows: one very wide item holding a whole row of
    # figures, which must be split before any column can be found.
    out.append(
        [
            item(100, 700 - r * 14, 400, 10, txt)
            for r, txt in enumerate(
                [
                    "$ 5,147,649 114,167 \u2014 778,177",
                    "$ 1,234 5,678 9,012 3,456",
                    "114,167 (2,340) \u2013 778,177",
                    "Land $ 778,177 114,167 5,147",
                    "$ 1,234 5,678",
                ]
            )
        ]
    )
    out.append([item(100, 700, 100, 10, "$ 1,234 5,678 9,012")])

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


def rule_cases(random_count):
    """Segment sets for the horizontal-rule primitives. Each block is
    `y x_min x_max` lines, a blank line, then `x y width size text` items."""
    def block(rules, items=()):
        return "\n".join(f"{y:g} {a:g} {b:g}" for y, a, b in rules) + "\n\n" + "\n".join(
            f"{x:g} {y:g} {w:g} {s:g} {t}" for x, y, w, s, t in items
        )

    out = [
        # Segmented cells on one baseline: joins across a 5pt gap, not a 10pt one.
        block([(700, 100, 200), (700, 205, 300), (700, 310, 400), (660, 100, 400)]),
        # Ruled bands filled with real multi-column rows. Without these the
        # anchor primitives only ever see one-word rows: the other cases in
        # this file exist for the rule geometry and carry almost no text.
        block(
            [(700, 100, 500), (680, 100, 500), (560, 100, 500)],
            [(100 + c * 100, 690 - r * 20, 70, 10, f"c{c}r{r}")
             for r in range(6) for c in range(4)],
        ),
        # Columns close enough to join into one anchor, against columns that
        # stay apart: the join gap is 6pt, so 4pt merges and 8pt does not.
        block(
            [(700, 100, 400), (600, 100, 400)],
            [(100, 690, 40, 10, "a"), (144, 690, 40, 10, "b"),
             (250, 690, 40, 10, "c"), (298, 690, 40, 10, "d"),
             (100, 670, 40, 10, "e"), (250, 670, 190, 10, "wide")],
        ),
        # Baselines drifting by 2pt a line — inside the row tolerance, so they
        # chain into one row and the row keeps the first item's y.
        block(
            [(700, 100, 400), (600, 100, 400)],
            [(100 + i * 60, 690 - i * 2, 40, 10, f"t{i}") for i in range(5)],
        ),
        # Items sharing a point exactly, which is where a non-stable sort
        # would diverge from the reference.
        block(
            [(700, 100, 400), (600, 100, 400)],
            [(200, 660, 30, 10, "same"), (200, 660, 30, 10, "point"),
             (200, 660, 30, 10, "again"), (100, 660, 30, 10, "left")],
        ),
        # Text reaching past the rules on both sides, and blank items that are
        # dropped before rows are formed.
        block(
            [(700, 200, 300), (600, 200, 300)],
            [(190, 690, 20, 10, "edgeL"), (295, 690, 20, 10, "edgeR"),
             (100, 690, 20, 10, "far"), (250, 670, 20, 10, " "),
             (250, 650, 20, 10, "keep")],
        ),
        # Negative widths, which the span sweep clamps to zero.
        block(
            [(700, 100, 400), (600, 100, 400)],
            [(150, 690, -40, 10, "neg"), (200, 690, 40, 10, "pos"),
             (300, 690, -5, 10, "neg2")],
        ),
        # A booktabs table: three full-width rules.
        block([(700, 100, 400), (660, 100, 400), (500, 100, 400)]),
        # Two tables sharing endpoints, separated by a numbered caption.
        block(
            [(700, 100, 400), (660, 100, 400), (500, 100, 400), (460, 100, 400)],
            [(120, 580, 60, 10, "Table 2")],
        ),
        # The same, separated by a large empty gap instead of a caption.
        block([(700, 100, 400), (660, 100, 400), (500, 100, 400), (460, 100, 400)]),
        # ...and the same with text filling the gap, which must NOT split.
        block(
            [(700, 100, 400), (660, 100, 400), (500, 100, 400), (460, 100, 400)],
            [(120, 640 - i * 14, 60, 10, "row") for i in range(9)],
        ),
        # A uniform ruled grid (evenly spaced, 5+ rules).
        block([(700 - i * 20, 100, 400) for i in range(6)]),
        # Nearly uniform, but outside the 2% bar.
        block([(700, 100, 400), (680, 100, 400), (659, 100, 400), (640, 100, 400), (618, 100, 400)]),
        # Segment endpoints that recur down the table → columns.
        block([(700 - i * 20, 100, 200) for i in range(4)]
              + [(700 - i * 20, 205, 300) for i in range(4)]
              + [(700 - i * 20, 305, 400) for i in range(4)]),
        # Ragged endpoints that do not recur → no columns.
        block([(700 - i * 20, 100 + i * 9, 400 - i * 7) for i in range(4)]),
        # Baselines drifting 1.5pt at a time — the grouping must not chain.
        block([(700 - i * 1.5, 100, 400) for i in range(5)]),
        block([]),
        block([(700, 100, 400)]),
    ]

    generator = random.Random(31337)

    # Evenly-spaced runs, which is the only way rules_are_uniform_grid says
    # yes. The random tail below almost never produces one, so these are
    # generated deliberately, straddling the 2% relative-deviation bar.
    for _ in range(random_count // 3):
        n = generator.randint(4, 9)
        pitch = generator.choice([14, 18, 20, 24, 30])
        jitter = generator.choice([0, 0, 0.05, 0.2, 0.5, 1.0, 2.0])
        rules = [
            (
                700 - i * pitch + generator.uniform(-jitter, jitter),
                100,
                400,
            )
            for i in range(n)
        ]
        out.append(block(rules))

    # Segmented rows whose endpoints recur, which is the only way columns are
    # derived — again with jitter across the 5pt clustering tolerance.
    for _ in range(random_count // 3):
        rows = generator.randint(2, 6)
        spans = generator.choice(
            [[(100, 200), (205, 300), (305, 400)],
             [(100, 180), (185, 260), (265, 340), (345, 420)],
             [(100, 250), (255, 400)]]
        )
        drift = generator.choice([0, 0, 1, 3, 6])
        rules = [
            (700 - r * 20, a + generator.uniform(0, drift), b + generator.uniform(0, drift))
            for r in range(rows)
            for a, b in spans
        ]
        out.append(block(rules))

    for _ in range(random_count):
        rules = []
        for _ in range(generator.randint(1, 9)):
            y = generator.choice([700, 690, 660, 620, 500, 460, 300]) + generator.choice(
                [0, 0, 1, -1, 2, -2, 3]
            )
            a = generator.choice([100, 105, 200, 205, 300, 310])
            b = a + generator.choice([50, 95, 100, 200, 300])
            rules.append((y, a, b))
        items = [
            (
                generator.choice([120, 200, 300]),
                generator.choice([680, 640, 580, 520, 480]),
                40,
                10,
                generator.choice(["body", "Table 2", "Table x", "", "note"]),
            )
            for _ in range(generator.randint(0, 4))
        ]
        out.append(block(rules, items))
    return out


def hypothesis_cases(random_count):
    """Competing table hypotheses. Each line is `L|A rowY cells items`, where
    cells are `a,b;c,d` (semicolon between rows) and items are indices."""
    def cand(tag, y, rows, items):
        cells = ";".join(",".join(r) for r in rows)
        return f"{tag} {y:g} {cells} {','.join(str(i) for i in items)}"

    out = [
        # An alternative that explains more displaces the legacy reading.
        "\n".join([
            cand("L", 700, [["a", "b"], ["c", "d"]], [1, 2, 3]),
            cand("A", 700, [["a", "b", "c"], ["d", "e", "f"]], [1, 2, 3, 4, 5]),
        ]),
        # ...and one that explains less does not.
        "\n".join([
            cand("L", 700, [["a", "b", "c"], ["d", "e", "f"]], [1, 2, 3, 4, 5]),
            cand("A", 700, [["a"], ["b"]], [1, 2]),
        ]),
        # Non-overlapping candidates all survive.
        "\n".join([
            cand("L", 700, [["a", "b"], ["c", "d"]], [1, 2]),
            cand("A", 500, [["x", "y"], ["z", "w"]], [9, 10]),
        ]),
        # No alternatives at all → legacy passes through untouched.
        cand("L", 700, [["a", "b"], ["c", "d"]], [1, 2]),
        # No legacy → alternatives are selected among themselves.
        "\n".join([
            cand("A", 700, [["a", "b"], ["c", "d"]], [1, 2, 3]),
            cand("A", 690, [["e", "f"], ["g", "h"]], [3, 4]),
        ]),
        # Equal scores: the tie-break is item count, then input order.
        "\n".join([
            cand("L", 700, [["a", "b"], ["c", "d"]], [1, 2]),
            cand("A", 700, [["a", "b"], ["c", "d"]], [1, 2]),
        ]),
        # A sparse grid over the same items loses to a tight one.
        "\n".join([
            cand("L", 700, [["a", "", "", ""], ["", "", "", "b"]], [1, 2]),
            cand("A", 700, [["a", "b"]], [1, 2]),
        ]),
        # A candidate straddling two accepted tables.
        "\n".join([
            cand("L", 700, [["a"], ["b"]], [1, 2]),
            cand("L", 500, [["c"], ["d"]], [7, 8]),
            cand("A", 600, [["x", "y"]], [2, 7]),
        ]),
    ]

    generator = random.Random(24680)
    words = ["a", "bb", "ccc", "", "12", "total"]
    for _ in range(random_count):
        lines = []
        pool = list(range(1, 14))
        for _ in range(generator.randint(1, 4)):
            tag = generator.choice(["L", "A"])
            rows = generator.randint(1, 4)
            cols = generator.randint(1, 4)
            grid = [[generator.choice(words) for _ in range(cols)] for _ in range(rows)]
            n = generator.randint(1, 6)
            items = sorted(generator.sample(pool, min(n, len(pool))))
            lines.append(cand(tag, generator.choice([700, 690, 600, 500]), grid, items))
        out.append("\n".join(lines))
    return out


def rect_cases(random_count):
    """Rect sets for clustering. First line is `tol min_size gap min_group`,
    then `x y w h` per rect."""
    def block(header, rects):
        return " ".join(str(h) for h in header) + "\n" + "\n".join(
            f"{x:g} {y:g} {w:g} {h:g}" for x, y, w, h in rects
        )

    out = [
        # Two tables side by side, far apart: two clusters, and a clean split.
        block((2, 2, 40, 2), [(100, 700, 50, 20), (150, 700, 50, 20),
                              (300, 700, 50, 20), (350, 700, 50, 20)]),
        # A grid of abutting cells: one cluster.
        block((2, 4, 40, 2),
              [(100 + c * 50, 700 - r * 20, 50, 20) for r in range(4) for c in range(4)]),
        # Cells separated by more than the tolerance: no cluster survives.
        block((1, 4, 40, 2),
              [(100 + c * 60, 700 - r * 30, 50, 20) for r in range(4) for c in range(4)]),
        # Nested rects (a border around cells) — all one component.
        block((2, 2, 40, 2), [(100, 700, 200, 80), (110, 710, 50, 20), (170, 710, 50, 20)]),
        # A gap too narrow to split on.
        block((2, 2, 200, 2), [(100, 700, 50, 20), (160, 700, 50, 20)]),
        # Lopsided split: one side too small.
        block((2, 2, 40, 3), [(100, 700, 20, 20), (300, 700, 20, 20),
                              (330, 700, 20, 20), (360, 700, 20, 20)]),
        block((2, 1, 40, 1), []),
        block((2, 1, 40, 1), [(100, 700, 50, 20)]),
    ]

    generator = random.Random(1357)
    for _ in range(random_count):
        n = generator.randint(0, 24)
        style = generator.choice(["grid", "scatter", "twogrids", "nested"])
        rects = []
        if style == "grid":
            cols, rows = generator.randint(2, 5), generator.randint(2, 5)
            cw = generator.choice([40, 50, 60])
            ch = generator.choice([15, 20, 25])
            pad = generator.choice([0, 0, 1, 4, 12])
            rects = [
                (100 + c * (cw + pad), 700 - r * (ch + pad), cw, ch)
                for r in range(rows) for c in range(cols)
            ]
        elif style == "twogrids":
            for base in (100, generator.choice([260, 320, 400])):
                for r in range(generator.randint(2, 4)):
                    for c in range(2):
                        rects.append((base + c * 50, 700 - r * 20, 50, 20))
        elif style == "nested":
            rects = [(100, 650, 250, 100)] + [
                (110 + c * 60, 660 + r * 30, 55, 25)
                for r in range(2) for c in range(3)
            ]
        else:
            rects = [
                (
                    generator.randrange(50, 500),
                    generator.randrange(300, 720),
                    generator.choice([10, 30, 50]),
                    generator.choice([10, 20]),
                )
                for _ in range(n)
            ]
        header = (
            generator.choice([0.5, 1, 2, 5]),
            generator.choice([1, 2, 4, 8]),
            generator.choice([10, 40, 100]),
            generator.choice([1, 2, 3]),
        )
        out.append(block(header, rects))
    return out


def assign_cases(random_count):
    """Grid-assignment cases: column edges, row edges, then items."""
    def block(cols, rows, items):
        return (
            " ".join(f"{c:g}" for c in cols) + "\n"
            + " ".join(f"{r:g}" for r in rows) + "\n"
            + "\n".join(f"{x:g} {y:g} {w:g} {s:g} {t}" for x, y, w, s, t in items)
        )

    out = [
        # A plain 2x2.
        block([100, 200, 300], [720, 700, 680],
              [(110, 710, 40, 10, "a"), (210, 710, 40, 10, "b"),
               (110, 690, 40, 10, "c"), (210, 690, 40, 10, "d")]),
        # Items outside the grid are dropped.
        block([100, 200], [720, 700],
              [(110, 710, 40, 10, "in"), (500, 710, 40, 10, "out"),
               (110, 400, 40, 10, "below")]),
        # An item straddling a border: assignment is by horizontal centre.
        block([100, 200, 300], [720, 700],
              [(180, 710, 40, 10, "straddles")]),
        # Exactly on a border, and just outside it by less than the slack.
        block([100, 200], [720, 700],
              [(80, 710, 40, 10, "onedge"), (78, 701.5, 40, 10, "slack")]),
        # Several items in one cell: down the page, then left to right.
        block([100, 300], [720, 680],
              [(110, 690, 40, 10, "second"), (200, 710, 40, 10, "first-right"),
               (110, 710, 40, 10, "first-left")]),
        # Bracket spacing inside a joined cell.
        block([100, 300], [720, 680],
              [(110, 710, 20, 10, "value"), (140, 710, 10, 10, "("),
               (160, 710, 20, 10, "12"), (190, 710, 10, 10, ")")]),
        # Degenerate: too few edges to bound a cell.
        block([100], [720], [(110, 710, 40, 10, "x")]),
    ]

    generator = random.Random(8642)
    words = ["a", "bb", "12", "(", ")", "3.50", "", "total"]
    for _ in range(random_count):
        ncols = generator.randint(1, 5)
        nrows = generator.randint(1, 5)
        cols = [100.0]
        for _ in range(ncols):
            cols.append(cols[-1] + generator.choice([30, 50, 80, 120]))
        rows = [720.0]
        for _ in range(nrows):
            rows.append(rows[-1] - generator.choice([15, 20, 30]))
        items = []
        for _ in range(generator.randint(0, 12)):
            items.append((
                generator.uniform(60, cols[-1] + 40),
                generator.uniform(rows[-1] - 20, 730),
                generator.choice([10, 20, 40]),
                10,
                generator.choice(words),
            ))
        out.append(block(cols, rows, items))
    return out


def gridbuild_cases(random_count):
    """Rect clusters for grid building. Line 1 is `strict skipflags`, then
    `R x y w h` rects and `I x y w size text` items."""
    def block(strict, skips, rects, items):
        head = f"{1 if strict else 0} " + (",".join("1" if s else "0" for s in skips) or "")
        body = [f"R {x:g} {y:g} {w:g} {h:g}" for x, y, w, h in rects]
        body += [f"I {x:g} {y:g} {w:g} {s:g} {t}" for x, y, w, s, t in items]
        return head + "\n" + "\n".join(body)

    def cell_grid(rows, cols, cw=60, ch=20, x0=100, y0=700):
        return [(x0 + c * cw, y0 - r * ch, cw, ch) for r in range(rows) for c in range(cols)]

    def fill(rows, cols, cw=60, ch=20, x0=100, y0=700, word="v"):
        return [
            (x0 + c * cw + 10, y0 - r * ch + 5, 30, 10, f"{word}{r}{c}")
            for r in range(rows) for c in range(cols)
        ]

    out = []
    # A well-formed grid, loose and strict.
    for strict in (False, True):
        rects = cell_grid(3, 3)
        out.append(block(strict, [False] * len(rects), rects, fill(3, 3)))
    # Too few edges.
    out.append(block(False, [False, False], cell_grid(1, 2), fill(1, 2)))
    # Sparse: cells drawn but no text.
    rects = cell_grid(4, 3)
    out.append(block(False, [False] * len(rects), rects, fill(1, 1)))
    # A page background that would manufacture margin columns unless skipped.
    rects = [(50, 400, 500, 340)] + cell_grid(3, 3)
    out.append(block(False, [True] + [False] * (len(rects) - 1), rects, fill(3, 3)))
    # ...and the same without the skip flag.
    out.append(block(False, [False] * len(rects), rects, fill(3, 3)))
    # A merged label spanning three rows in column 0.
    rects = [(100, 640, 60, 60)] + cell_grid(3, 3)[1:]
    out.append(block(False, [False] * len(rects), rects, fill(3, 3)))
    # A paragraph swept into a cell — rejected in strict mode only.
    rects = cell_grid(3, 3)
    long_items = fill(3, 3) + [(110, 665, 30, 10, "x" * 240)]
    for strict in (False, True):
        out.append(block(strict, [False] * len(rects), rects, long_items))
    # Empty outer columns (rect edges beyond the text).
    rects = cell_grid(3, 4)
    out.append(block(False, [False] * len(rects), rects,
                     fill(3, 2, x0=160) ))
    # Too many columns.
    rects = cell_grid(3, 28, cw=20)
    out.append(block(False, [False] * len(rects), rects, fill(3, 28, cw=20)))

    # Shapes the classifiers exist to recognise, which the random tail below
    # produces only by accident.
    #   full-width shaded bands (row stripes)
    stripes = [(100, 700 - r * 20, 400, 18) for r in range(6)]
    out.append(block(False, [False] * len(stripes), stripes,
                     [(110 + c * 100, 705 - r * 20, 40, 10, f"s{r}{c}")
                      for r in range(6) for c in range(3)]))
    #   bands of varying width — not stripes
    ragged = [(100, 700 - r * 20, 400 - r * 60, 18) for r in range(6)]
    out.append(block(False, [False] * len(ragged), ragged, []))
    #   a vertical bar chart: equal widths, spaced, data-driven heights
    bars = [(100 + i * 60, 400, 30, 40 + i * 35) for i in range(6)]
    out.append(block(False, [False] * len(bars), bars,
                     [(105 + i * 60, 395, 20, 8, str(10 * i)) for i in range(6)]))
    #   the same bars but labelled with words — a table, not a chart
    out.append(block(False, [False] * len(bars), bars,
                     [(105 + i * 60, 395, 20, 8, "category") for i in range(6)]))
    #   a horizontal bar chart
    hbars = [(100, 400 + i * 40, 60 + i * 45, 20) for i in range(6)]
    out.append(block(False, [False] * len(hbars), hbars, []))
    #   many page backgrounds, and too few to count
    for count in (9, 3):
        bg = [(0, 0, 600, 780)] * count + cell_grid(3, 3)
        out.append(block(False, [False] * len(bg), bg, fill(3, 3)))

    # Prose-shaped content, which the cell-rect strategy gates on and no
    # other case reaches: `v00`-style filler contains no English function
    # words, so its whole prose block would never run. Tildes stand in for
    # spaces in the case format and are word separators to the splitter
    # either way, so the fragments read the same to it.
    prose_rng = random.Random(32_2026)
    short_prose = ["the~total", "of~each", "is~set", "in~use", "by~hand", "a~note"]
    long_prose = [
        "this~is~a~description~of~the~control~and~how~it~is~applied~in~practice",
        "the~value~was~set~by~hand~and~has~not~been~reviewed~since~that~time",
        "each~of~these~items~is~a~fragment~of~a~sentence~that~wrapped~in~a~frame",
    ]
    for case in range(40):
        rows = prose_rng.randint(3, 6)
        cols = prose_rng.randint(2, 4)
        long_cells = prose_rng.random() < 0.5
        rects = cell_grid(rows, cols)
        items = []
        for r in range(rows):
            for c in range(cols):
                if prose_rng.random() < 0.15:
                    continue
                if c == 0 and prose_rng.random() < 0.7:
                    text = f"{r + 1}"
                elif long_cells:
                    text = prose_rng.choice(long_prose)
                else:
                    text = prose_rng.choice(short_prose)
                items.append((100 + c * 60 + 10, 700 - r * 20 + 5, 30, 10, text))
        out.append(block(False, [False] * len(rects), rects, items))

    # Whole-page shapes, for the orchestrator rather than a single cluster.
    # Every other case here is one cluster, so without these the multi-table,
    # split, merged-fallback and row-stripe-fallback branches never run.

    # Two grids far enough apart to cluster separately.
    two = cell_grid(3, 3, y0=700) + cell_grid(3, 3, y0=500)
    out.append(block(False, [False] * len(two),
                     two, fill(3, 3, y0=700) + fill(3, 3, y0=500, word="w")))

    # Two grids bridged by a full-width header, so they arrive as one wide
    # cluster with a gutter down the middle. The halves sit on different row
    # baselines, which is what stops the combined geometry gridding cleanly
    # and sends the cluster to the split retry.
    for offset in (0, 7):
        bridged = ([(100, 720, 460, 20)]
                   + cell_grid(3, 3, x0=100, y0=700)
                   + cell_grid(3, 3, x0=380, y0=700 - offset))
        bridged_items = ([(110, 725, 200, 10, "header")]
                         + fill(3, 3, x0=100, y0=700)
                         + fill(3, 3, x0=380, y0=700 - offset, word="w"))
        out.append(block(False, [False] * len(bridged), bridged, bridged_items))

    # Calendar-style decorative clusters carrying no text: no table can be
    # built, but the bounding boxes still scope the heuristic detector. Two of
    # them, because a single hint is dropped as probable decoration.
    calendars = []
    for g in range(2):
        for r in range(6):
            for c in range(6):
                calendars.append((100 + c * 60, 700 - g * 200 - r * 20, 60, 20))
    out.append(block(False, [False] * len(calendars), calendars, []))

    # Two such clusters side by side with a gap under 50pt and a combined
    # width under 400pt, which is what the hint merge exists to fold together.
    side = []
    for g in range(2):
        for r in range(10):
            for c in range(3):
                side.append((100 + g * 200 + c * 60, 700 - r * 20, 60, 20))
    out.append(block(False, [False] * len(side), side, []))

    # Three two-column groups: each detects a narrow table on its own, which
    # is the signal that the real table was split across clusters — so the
    # merged fallback replaces all three.
    narrow = []
    narrow_items = []
    for g in range(3):
        for r in range(15):
            for c in range(2):
                x = g * 180 + c * 70 + 50
                narrow.append((x, 700 - r * 20, 70, 20))
                narrow_items.append((x + 5, 705 - r * 20, 40, 10, f"g{g}c{c}r{r}"))
    out.append(block(False, [False] * len(narrow), narrow, narrow_items))

    # Clip-path style: each column its own cluster, none overlapping.
    columns = []
    column_items = []
    for c in range(4):
        for r in range(15):
            columns.append((100 + c * 80, 700 - r * 20, 70, 20))
            column_items.append((105 + c * 80, 705 - r * 20, 40, 10, f"c{c}r{r}"))
    out.append(block(False, [False] * len(columns), columns, column_items))

    # Row stripes: full-width bands separated by more than the 3pt cluster
    # tolerance, so clustering finds nothing at all and the whole page has to
    # be tried at once.
    stripes = [(100, 700 - r * 30, 400, 15) for r in range(16)]
    stripe_items = [
        (110 + c * 130, 705 - r * 30, 60, 10, f"s{r}{c}")
        for r in range(16) for c in range(3)
    ]
    out.append(block(False, [False] * len(stripes), stripes, stripe_items))
    # ...and the same shape too short to clear the fifteen-rect bar.
    short_stripes = stripes[:12]
    out.append(block(False, [False] * len(short_stripes), short_stripes,
                     [i for i in stripe_items if i[1] > 705 - 12 * 30]))

    # A bar chart: equal-breadth bars of varying length, standing apart, with
    # numeric labels. Bars never overlap each other, so an axis rule is what
    # bridges them into one cluster — which is how a chart reaches the loop.
    bars = [(100, 294, 220, 6)] + [(100 + c * 40, 300, 25, 60 + c * 35) for c in range(6)]
    bar_items = [(105 + c * 40, 295, 20, 10, f"{c * 12}") for c in range(6)]
    out.append(block(False, [False] * len(bars), bars, bar_items))
    # The same bars under repeated page fills, which is what makes a real
    # shaded-cell table look chart-like.
    filled = [(0, 0, 612, 792)] * 3 + bars
    out.append(block(False, [False] * len(filled), filled, bar_items))

    # Shapes aimed at the gates the randomised prose cases never reach:
    # a paragraph-length cell in a short table, a tall skinny grid, and
    # uniformly long prose across enough columns to pass the distribution
    # test and be caught on mean cell length alone.
    wall = "the~quick~brown~fox~jumps~over~the~lazy~dog~again~and~again~" * 10
    short_rects = cell_grid(3, 3)
    out.append(block(False, [False] * len(short_rects), short_rects,
                     fill(3, 3) + [(110, 665, 30, 10, wall)]))
    tall_rects = cell_grid(25, 2)
    out.append(block(False, [False] * len(tall_rects), tall_rects, fill(25, 2)))
    tall_rects = cell_grid(25, 4)
    out.append(block(False, [False] * len(tall_rects), tall_rects, fill(25, 4)))
    for cols in (3, 4):
        rects = cell_grid(4, cols)
        items = [
            (100 + c * 60 + 10, 700 - r * 20 + 5, 30, 10,
             long_prose[(r + c) % len(long_prose)])
            for r in range(4) for c in range(cols)
        ]
        out.append(block(False, [False] * len(rects), rects, items))

    # A wide description column beside a narrow label column, which is the
    # only shape the wrapped-row collapse repairs.
    desc_rects = [(100, 700 - r * 20, 40, 20) for r in range(4)]
    desc_rects += [(140, 700 - r * 20, 260, 20) for r in range(4)]
    desc_items = []
    for r in range(4):
        if r % 2 == 0:
            desc_items.append((110, 705 - r * 20, 20, 10, f"{r + 1}"))
        desc_items.append(
            (150, 705 - r * 20, 240, 10,
             "the~description~continues~onto~the~next~band~of~this~row"))
    out.append(block(False, [False] * len(desc_rects), desc_rects, desc_items))

    # Too few rect y-edges, so rows must come from the text instead.
    out.append(block(False, [False] * 3,
                     [(100, 700, 60, 20), (160, 700, 60, 20), (220, 700, 60, 20)],
                     [(110 + c * 60, 705 - r * 14, 30, 10, f"t{r}{c}")
                      for r in range(5) for c in range(3)]))
    out.append(block(False, [False] * 2,
                     [(100, 700, 60, 20), (160, 700, 60, 20)],
                     [(110, 705, 30, 10, "a"), (110, 690, 30, 10, "b")]))

    # Preprocessing shapes: negative extents, decoration, an oversized fill,
    # and cell-internal shading inside a cell.
    out.append(block(False, [False] * 4, [
        (300, 700, -100, 20), (100, 700, 60, -20),
        (100, 600, 3, 20), (100, 500, 60, 3),
    ], []))
    grid_rects = cell_grid(3, 3)
    out.append(block(False, [False] * (len(grid_rects) + 1),
                     grid_rects + [(0, 0, 600, 780)], fill(3, 3)))
    shaded = cell_grid(3, 3) + [(102, 702, 56, 16)]
    out.append(block(False, [False] * len(shaded), shaded, fill(3, 3)))

    # Stacked boxes: a framed list, and the prose shapes that must be
    # rejected. The random tail almost never produces a clean stack.
    def stack(n, h=24, gap=2, width=300):
        return [(100, 700 - i * (h + gap), width, h) for i in range(n)]

    #   a clean framed list
    boxes = stack(5)
    out.append(block(False, [False] * len(boxes), boxes,
                     [(110, b[1] + 8, 120, 10, f"Item {i}") for i, b in enumerate(boxes)]))
    #   prose wrapping across the boxes
    prose = [
        "the quick brown fox jumps over the lazy dog and then,",
        "continues running for a while before it finally stops",
        "at the edge of the field where the fence has a gap in",
        "it that leads through to the neighbouring property and",
        "onwards to the road beyond the hill",
    ]
    out.append(block(False, [False] * len(boxes), boxes,
                     [(110, b[1] + 8, 250, 10, prose[i]) for i, b in enumerate(boxes)]))
    #   numbered list items behind stripes
    out.append(block(False, [False] * len(boxes), boxes,
                     [(110, b[1] + 8, 120, 10, f"{i+1}) something here")
                      for i, b in enumerate(boxes)]))
    #   boxes flanked by text — one column of something wider
    out.append(block(False, [False] * len(boxes), boxes,
                     [(110, b[1] + 8, 80, 10, f"Item {i}") for i, b in enumerate(boxes)]
                     + [(450, b[1] + 8, 60, 10, f"v{i}") for i, b in enumerate(boxes)]))
    #   two runs per box — multi-column content
    out.append(block(False, [False] * len(boxes), boxes,
                     [(110, b[1] + 8, 60, 10, f"L{i}") for i, b in enumerate(boxes)]
                     + [(220, b[1] + 8, 60, 10, f"R{i}") for i, b in enumerate(boxes)]))
    #   too few boxes, and boxes with a gap larger than a row
    out.append(block(False, [False, False], stack(2),
                     [(110, 708, 80, 10, "a"), (110, 682, 80, 10, "b")]))
    gapped = [(100, 700, 300, 24), (100, 600, 300, 24), (100, 500, 300, 24)]
    out.append(block(False, [False] * 3, gapped,
                     [(110, b[1] + 8, 80, 10, f"g{i}") for i, b in enumerate(gapped)]))

    generator = random.Random(4242)
    words = ["a", "bb", "12", "", "3.50", "total"]

    # Randomised shapes for the preprocessing filters: flipped extents, sub-
    # threshold decoration, oversized fills straddling the 10x median-width
    # gate, and nested shading straddling the 4x container-height gate.
    for _ in range(random_count // 3):
        rects = list(cell_grid(generator.randint(2, 4), generator.randint(2, 4)))
        for _ in range(generator.randint(0, 4)):
            kind = generator.choice(["flip", "tiny", "oversize", "nested", "pagebg"])
            if kind == "flip":
                x, y = generator.randrange(100, 400), generator.randrange(500, 700)
                rects.append((x, y, -generator.choice([20, 60]), -generator.choice([10, 30])))
            elif kind == "tiny":
                rects.append((generator.randrange(100, 400), generator.randrange(500, 700),
                              generator.choice([1, 3, 4.5, 6]), generator.choice([2, 4, 8])))
            elif kind == "oversize":
                base = rects[0][2] if rects else 60
                rects.append((100, 400, base * generator.choice([5, 9, 11, 20]), 30))
            elif kind == "pagebg":
                rects.append((0, 0, 600, 780))
            else:
                if rects:
                    bx, by, bw, bh = rects[0]
                    shrink = generator.choice([0.9, 0.6, 0.2])
                    rects.append((bx + 2, by + 2, bw * shrink, bh * shrink))
        generator.shuffle(rects)
        out.append(block(False, [False] * len(rects), rects, fill(2, 2)))

    # Randomised framed stacks, straddling the gates: box count, the 120-char
    # cell cap, the 60-char prose mean, the continuation and list-marker
    # tests, and the flanking checks.
    labels = ["Overview", "Scope", "Method", "Results", "Summary", "Appendix",
              "Introduction to the topic", "Findings and discussion"]
    for _ in range(random_count // 3):
        n = generator.randint(2, 7)
        h = generator.choice([16, 24, 40])
        gapv = generator.choice([0, 2, 6, 30])
        boxes = [(100, 700 - i * (h + gapv), generator.choice([200, 300, 420]), h)
                 for i in range(n)]
        style = generator.choice(["label", "prose", "list", "flanked", "tworuns"])
        its = []
        for i, b in enumerate(boxes):
            y = b[1] + h / 2
            if style == "prose":
                its.append((110, y, 250, 10,
                            "the quick brown fox jumps over the lazy dog and then,"))
            elif style == "list":
                its.append((110, y, 120, 10, f"{i+1}) {generator.choice(labels)}"))
            else:
                its.append((110, y, 100, 10, generator.choice(labels)))
            if style == "flanked":
                its.append((b[0] + b[2] + 40, y, 60, 10, f"v{i}"))
            if style == "tworuns":
                its.append((110 + 120, y, 60, 10, f"R{i}"))
        out.append(block(False, [False] * len(boxes), boxes, its))

    # Randomised stripes and bar charts straddling their thresholds — the
    # 200pt median width, the 10% width tolerance, the 0.5-breadth bar gap
    # and the 1.3x length variation. The general tail below produces these
    # only by accident.
    for _ in range(random_count // 3):
        rows = generator.randint(2, 8)
        width = generator.choice([120, 190, 205, 300, 450])
        wobble = generator.choice([0, 0, 0.05, 0.12, 0.4])
        rects = [
            (100, 700 - r * 20, width * (1 + generator.uniform(-wobble, wobble)), 18)
            for r in range(rows)
        ]
        items = [
            (110 + c * 90, 705 - r * 20, 40, 10, generator.choice(words))
            for r in range(rows) for c in range(generator.randint(1, 3))
        ]
        out.append(block(False, [False] * len(rects), rects, items))

    for _ in range(random_count // 3):
        count = generator.randint(3, 8)
        breadth = generator.choice([15, 30, 45])
        gap = generator.choice([0, 5, 20, 40])
        vary = generator.choice([1.0, 1.2, 1.5, 3.0])
        horizontal = generator.random() < 0.5
        rects = []
        for i in range(count):
            length = 40 * (1 + (vary - 1) * i / max(count - 1, 1))
            if horizontal:
                rects.append((100, 400 + i * (breadth + gap), length, breadth))
            else:
                rects.append((100 + i * (breadth + gap), 400, breadth, length))
        labelled = generator.random() < 0.5
        items = [
            (
                105 + (0 if horizontal else i * (breadth + gap)),
                395 + (i * (breadth + gap) if horizontal else 0),
                20, 8,
                str(10 * i) if labelled else "category",
            )
            for i in range(count)
        ]
        out.append(block(False, [False] * len(rects), rects, items))
    for _ in range(random_count):
        rows = generator.randint(1, 6)
        cols = generator.randint(1, 6)
        cw = generator.choice([30, 60, 90])
        ch = generator.choice([15, 20, 30])
        jitter = generator.choice([0, 0, 2, 8])
        rects = [
            (100 + c * cw + generator.uniform(0, jitter),
             700 - r * ch + generator.uniform(0, jitter), cw, ch)
            for r in range(rows) for c in range(cols)
        ]
        # Occasionally drop some cells, or add a spanning rect.
        if generator.random() < 0.3 and len(rects) > 3:
            rects = rects[: -generator.randint(1, 3)]
        if generator.random() < 0.25:
            rects.insert(0, (100, 700 - (rows - 1) * ch, cw, ch * rows))
        items = [
            (100 + c * cw + 10, 700 - r * ch + 5, 25, 10, generator.choice(words))
            for r in range(rows) for c in range(cols)
            if generator.random() < 0.8
        ]
        skips = [generator.random() < 0.1 for _ in rects]
        out.append(block(generator.random() < 0.5, skips, rects, items))
    return out



def collapse_cases(count):
    """Cases for collapse_multiline_description_rows.

    The function only acts on one narrow shape — a label column, a much wider
    description column, and continuation bands with text in that column alone
    — so purely random grids would never reach the merging loop. Half the
    cases are built to that shape and then perturbed; half are random, to
    exercise the early returns.
    """
    rng = random.Random(31_2026)
    words = ["Alpha", "Beta", "value", "a~long~wrapped~description~line", "12.5", "x", ""]

    def block(col_edges, row_edges, rows):
        out = ["#collapse"]
        out.append("E " + " ".join(f"{v:.3f}" for v in row_edges))
        out.append("X " + " ".join(f"{v:.3f}" for v in col_edges))
        for r in rows:
            out.append("R\t" + "\t".join(r))
        return "\n".join(out)

    out = []
    for case in range(count):
        shaped = case % 2 == 0
        cols = rng.randint(2, 5)
        if shaped:
            # Narrow label columns, then one dominant description column.
            widths = [rng.uniform(20, 40) for _ in range(cols - 1)]
            widths.insert(rng.randrange(1, cols), rng.uniform(120, 260))
            widths = widths[:cols]
        else:
            widths = [rng.uniform(10, 200) for _ in range(cols)]
        col_edges = [50.0]
        for w in widths:
            col_edges.append(col_edges[-1] + w)
        widest = max(range(cols), key=lambda c: col_edges[c + 1] - col_edges[c])

        rows_n = rng.randint(1, 8)
        rows = []
        for r in range(rows_n):
            if shaped and r > 0 and rng.random() < 0.45:
                # A continuation band: description column only.
                row = ["" for _ in range(cols)]
                row[widest] = rng.choice(words[2:5]) or "cont"
            elif shaped and r > 0 and rng.random() < 0.15:
                # A header continuation: short text in column 0 alone.
                row = ["" for _ in range(cols)]
                row[0] = rng.choice(["Version", "Controls", "x" * rng.randint(20, 30)])
            else:
                row = [rng.choice(words) for _ in range(cols)]
            rows.append(row)

        # Row edges usually match, sometimes deliberately do not.
        edge_n = len(rows) + 1 if rng.random() < 0.85 else len(rows) + rng.choice([0, 2])
        row_edges = [700.0 - i * rng.uniform(10, 20) for i in range(max(edge_n, 0))]
        out.append(block(col_edges, row_edges, rows))

    # Degenerate shapes the random generator will not reach.
    out.append(block([50.0, 50.0, 50.0, 50.0], [700.0, 690.0, 680.0, 670.0],
                     [["a", "b", "c"], ["", "", "d"], ["e", "", ""]]))
    out.append(block([50.0, 100.0, 150.0, 400.0], [700.0, 690.0, 680.0, 670.0],
                     [["l1", "", "desc one"], ["", "", "wrapped two"],
                      ["l2", "", "desc three"]]))
    out.append(block([50.0, 300.0, 320.0, 340.0], [700.0, 690.0, 680.0, 670.0],
                     [["wide", "b", "c"], ["", "", "d"], ["e", "f", "g"]]))
    return out



def openedge_cases(random_count):
    """Cases for the stacked-token and open-edge grid strategies.

    A separate file from `rule_cases`, deliberately: these carry `v x y_min
    y_max` vertical-rule lines, and feeding those to the wave-21 and wave-35
    probes would have them parsed as a horizontal rule at y=0 on the Rust side
    (`unwrap_or(0.0)`) and skipped on the Swift side — a divergence in the
    harness rather than the port.
    """
    rng = random.Random(36_2026)

    def block(rules, verticals, items, paths=()):
        head = [f"{y:g} {a:g} {b:g}" for y, a, b in rules]
        head += [f"v {x:g} {lo:g} {hi:g}" for x, lo, hi in verticals]
        head += [f"p {a:g} {b:g} {c:g} {d:g}" for a, b, c, d in paths]
        body = [f"{x:g} {y:g} {w:g} {s:g} {t}" for x, y, w, s, t in items]
        return "\n".join(head) + "\n\n" + "\n".join(body)

    def grid_case(cols, body_rows, x0=100, width=400, y0=700, row_gap=20,
                  header=True, vertical_span=1.0, first_header=True):
        colw = width / cols
        rules = [(y0 - r * row_gap, x0, x0 + width) for r in range(body_rows + 1)]
        y_bottom = y0 - body_rows * row_gap
        height = y0 - y_bottom
        verticals = [
            (x0 + c * colw, y_bottom, y_bottom + height * vertical_span)
            for c in range(1, cols)
        ]
        items = []
        if header:
            for c in range(cols):
                if c == 0 and not first_header:
                    continue
                items.append((x0 + c * colw + 10, y0 + 12, colw - 30, 10, f"H{c}"))
        for r in range(body_rows):
            for c in range(cols):
                items.append(
                    (x0 + c * colw + 10, y0 - r * row_gap - 10, colw - 30, 10, f"d{r}{c}"))
        return block(rules, verticals, items)

    out = [
        # A textbook open-edge grid: three rules, one interior vertical.
        grid_case(2, 3),
        grid_case(3, 4),
        grid_case(5, 5),
        # The header stub case: first column unlabelled.
        grid_case(3, 4, first_header=False),
        # No header above the band at all.
        grid_case(3, 4, header=False),
        # Verticals too short to be column edges (60% of the band).
        grid_case(3, 4, vertical_span=0.6),
        # Band too narrow, and too short.
        grid_case(3, 3, width=80),
        grid_case(3, 3, row_gap=5),
        # Only two rules — below the run minimum.
        block([(700, 100, 500), (680, 100, 500)],
              [(300, 680, 700)],
              [(110, 690, 60, 10, "a"), (310, 690, 60, 10, "b")]),
        # No verticals at all: a ruled band, not a grid.
        block([(700, 100, 500), (680, 100, 500), (660, 100, 500)], [],
              [(110, 690, 60, 10, "a"), (310, 690, 60, 10, "b")]),

        # Twenty-five interior verticals: hatching, not columns.
        block([(700, 100, 500), (680, 100, 500), (660, 100, 500)],
              [(110 + i * 15, 660, 700) for i in range(25)],
              [(110 + i * 15, 690, 10, 10, f"h{i}") for i in range(25)]),
        # Rules that snap down to two row edges while still spanning 28pt.
        block([(700, 100, 500), (703, 100, 500), (725, 100, 500), (728, 100, 500)],
              [(300, 700, 728)],
              [(110, 715, 60, 10, "a"), (310, 715, 60, 10, "b")]),
        # Only one body row carries text.
        block([(700, 100, 500), (680, 100, 500), (660, 100, 500), (640, 100, 500)],
              [(300, 640, 700)],
              [(110, 712, 60, 10, "H0"), (310, 712, 60, 10, "H1"),
               (110, 690, 60, 10, "only"), (310, 690, 60, 10, "row")]),
        # A column with no text in it at all.
        block([(700, 100, 500), (680, 100, 500), (660, 100, 500)],
              [(233, 660, 700), (366, 660, 700)],
              [(110, 712, 60, 10, "H0"), (243, 712, 60, 10, "H1"), (376, 712, 60, 10, "H2"),
               (110, 690, 60, 10, "a"), (376, 690, 60, 10, "c"),
               (110, 670, 60, 10, "d"), (376, 670, 60, 10, "f")]),
        # A header item whose centre falls left of the first column edge.
        block([(700, 100, 500), (680, 100, 500), (660, 100, 500)],
              [(300, 660, 700)],
              [(95, 712, 2, 10, "x"), (110, 712, 60, 10, "H0"), (310, 712, 60, 10, "H1"),
               (110, 690, 60, 10, "a"), (310, 690, 60, 10, "b"),
               (110, 670, 60, 10, "c"), (310, 670, 60, 10, "d")]),
        # A header missing its second cell.
        block([(700, 100, 500), (680, 100, 500), (660, 100, 500)],
              [(300, 660, 700)],
              [(110, 712, 60, 10, "H0"),
               (110, 690, 60, 10, "a"), (310, 690, 60, 10, "b"),
               (110, 670, 60, 10, "c"), (310, 670, 60, 10, "d")]),
        # A fully populated header alongside a logical rule of a different
        # span inside the band: better left to the physical-grid detector.
        block([(700, 100, 500), (680, 100, 500), (660, 100, 500), (670, 150, 450)],
              [(300, 660, 700)],
              [(110, 712, 60, 10, "H0"), (310, 712, 60, 10, "H1"),
               (110, 690, 60, 10, "a"), (310, 690, 60, 10, "b"),
               (110, 665, 60, 10, "c"), (310, 665, 60, 10, "d")]),

        # A stacked-token table: three rules, six single-token rows carrying
        # underscores, all starting at the same x.
        block([(700, 100, 400), (600, 100, 400), (500, 100, 400)], [],
              [(120, 690 - i * 12, 80, 10, t) for i, t in enumerate(
                  ["Field_name", "first_value", "second_value", "third_value",
                   "fourth:value", "fifth_value"])]),
        # The same, but the tokens carry neither underscore nor colon.
        block([(700, 100, 400), (600, 100, 400), (500, 100, 400)], [],
              [(120, 690 - i * 12, 80, 10, f"plain{i}") for i in range(6)]),
        # The same, but one row holds two items.
        block([(700, 100, 400), (600, 100, 400), (500, 100, 400)],
              [],
              [(120, 690 - i * 12, 80, 10, f"tok_{i}") for i in range(6)]
              + [(300, 690, 40, 10, "extra")]),
        # The same, but the rows are not left-aligned.
        block([(700, 100, 400), (600, 100, 400), (500, 100, 400)], [],
              [(120 + i * 9, 690 - i * 12, 80, 10, f"tok_{i}") for i in range(6)]),
        # Accepting variants: exactly five rows (the minimum), colons rather
        # than underscores, and the 3/4 token ratio from both sides.
        block([(700, 100, 400), (600, 100, 400), (500, 100, 400)], [],
              [(120, 690 - i * 12, 80, 10, t) for i, t in enumerate(
                  ["Label:", "a_1", "b_2", "c_3", "d_4"])]),
        block([(700, 100, 400), (600, 100, 400), (500, 100, 400)], [],
              [(120, 690 - i * 12, 80, 10, t) for i, t in enumerate(
                  ["Name", "x:1", "y:2", "z:3", "w:4", "v:5", "u:6"])]),
        # Four of five body rows are tokens: 4*4 >= 5*3, accepted.
        block([(700, 100, 400), (600, 100, 400), (500, 100, 400)], [],
              [(120, 690 - i * 12, 80, 10, t) for i, t in enumerate(
                  ["Head", "a_1", "b_2", "c_3", "plain"])]),
        # Three of five: 3*4 < 5*3, refused by one row.
        block([(700, 100, 400), (600, 100, 400), (500, 100, 400)], [],
              [(120, 690 - i * 12, 80, 10, t) for i, t in enumerate(
                  ["Head", "a_1", "b_2", "plain", "plainer"])]),
        # A token row holding two words, which does not count.
        block([(700, 100, 400), (600, 100, 400), (500, 100, 400)], [],
              [(120, 690 - i * 12, 80, 10, t) for i, t in enumerate(
                  ["Head", "two words_x", "b_2", "c_3", "d_4", "e_5"])]),
        # Exactly four rows: one short of the minimum.
        block([(700, 100, 400), (600, 100, 400), (500, 100, 400)], [],
              [(120, 690 - i * 12, 80, 10, t) for i, t in enumerate(
                  ["Head", "a_1", "b_2", "c_3"])]),
        # Alignment right at the 6pt join gap, and just past it.
        block([(700, 100, 400), (600, 100, 400), (500, 100, 400)], [],
              [(120 + (6 if i == 3 else 0), 690 - i * 12, 80, 10, f"t_{i}")
               for i in range(6)]),
        block([(700, 100, 400), (600, 100, 400), (500, 100, 400)], [],
              [(120 + (7 if i == 3 else 0), 690 - i * 12, 80, 10, f"t_{i}")
               for i in range(6)]),
        # Four rules instead of three.
        block([(700, 100, 400), (640, 100, 400), (580, 100, 400), (500, 100, 400)], [],
              [(120, 690 - i * 12, 80, 10, f"tok_{i}") for i in range(6)]),
    ]

    # Booktabs shapes for the text-anchor strategy. The grid cases above all
    # space their rules evenly, which `rules_are_uniform_grid` rejects before
    # anything else runs — so without these the whole strategy is starved.
    def anchor_case(header, body, rules=None, x0=100, x1=500):
        rules = rules or [(700, x0, x1), (680, x0, x1), (560, x0, x1)]
        items = [(x, 690, w, 10, tx) for x, w, tx in header]
        for row_index, row in enumerate(body):
            for x, w, tx in row:
                items.append((x, 670 - row_index * 15, w, 10, tx))
        return block(rules, [], items)

    three = [(110, 40, "Name"), (250, 40, "Count"), (390, 40, "Share")]
    out += [
        # A plain booktabs table: uneven rules, three anchors.
        anchor_case(three, [[(110, 40, "alpha"), (250, 20, "12"), (390, 20, "5%")],
                            [(110, 40, "beta"), (250, 20, "34"), (390, 20, "9%")]]),
        # One rule only.
        anchor_case(three, [[(110, 40, "alpha"), (250, 20, "12"), (390, 20, "5%")]],
                    rules=[(700, 100, 500)]),
        # Anchors under 30pt apart end to end.
        anchor_case([(110, 10, "A"), (125, 10, "B")],
                    [[(110, 10, "a"), (125, 10, "b")], [(110, 10, "c"), (125, 10, "d")]]),
        # Twenty-six anchors.
        anchor_case([(110 + i * 14, 8, f"H{i}") for i in range(26)],
                    [[(110 + i * 14, 8, f"d{i}") for i in range(26)]] * 2),
        # A header of nothing but numbers.
        anchor_case([(110, 40, "12"), (250, 40, "34"), (390, 40, "56")],
                    [[(110, 40, "a"), (250, 20, "b"), (390, 20, "c")],
                     [(110, 40, "d"), (250, 20, "e"), (390, 20, "f")]]),
        # More than half the header numeric, but not all of it.
        anchor_case([(110, 40, "Name"), (250, 40, "2024"), (390, 40, "2025")],
                    [[(110, 40, "a"), (250, 20, "b"), (390, 20, "c")],
                     [(110, 40, "d"), (250, 20, "e"), (390, 20, "f")]]),
        # A body stub starting left of the first header anchor.
        anchor_case(three, [[(80, 20, "stub"), (110, 40, "alpha"), (250, 20, "12"),
                             (390, 20, "5%")],
                            [(110, 40, "beta"), (250, 20, "34"), (390, 20, "9%")]]),
        # Exactly two rules and an ordinary table: not a response form.
        anchor_case(three, [[(110, 40, "alpha"), (250, 20, "12"), (390, 20, "5%")],
                            [(110, 40, "beta"), (250, 20, "34"), (390, 20, "9%")]],
                    rules=[(700, 100, 500), (560, 100, 500)]),
        # Two rules and a real response form: short leading-column prompts,
        # the response column left blank.
        anchor_case([(110, 40, "Question"), (300, 40, "Answer")],
                    [[(110, 60, f"prompt {i}")] for i in range(6)],
                    rules=[(700, 100, 500), (560, 100, 500)]),
        # Three anchors inside a 40pt span: too narrow overall.
        anchor_case([(100, 8, "A"), (118, 8, "B"), (136, 8, "C")],
                    [[(100, 8, "a"), (118, 8, "b"), (136, 8, "c")],
                     [(100, 8, "d"), (118, 8, "e"), (136, 8, "f")]],
                    x0=100, x1=140),
        # Sustained prose: many rows of sentence-shaped cells under few rules.
        # Three anchors, not two — with two the prose gate above pre-empts
        # this one, which is how the first attempt at this case failed to
        # reach it. The items stay narrow so the wide-item arm stays quiet
        # and this gate is the one being exercised.
        anchor_case(three,
                    [[(110, 50, "alpha beta gamma delta"),
                      (250, 50, "one two three four"),
                      (390, 50, "five six seven eight")]
                     for _ in range(9)],
                    rules=[(700, 100, 500), (690, 100, 500), (400, 100, 500)]),
        # Items filling most of their columns: paragraph starts, not columns.
        anchor_case([(110, 40, "One"), (250, 40, "Two"), (390, 40, "Three")],
                    [[(110, 130, "wide text here"), (250, 130, "also wide"),
                      (390, 105, "wide again")] for _ in range(4)]),
        # A single cell past 240 characters.
        anchor_case(three, [[(110, 40, "x" * 250), (250, 20, "12"), (390, 20, "5%")],
                            [(110, 40, "beta"), (250, 20, "34"), (390, 20, "9%")]]),
        # Two cells past 100 characters out of ten.
        anchor_case(three, [[(110, 40, "y" * 120), (250, 20, "12"), (390, 20, "5%")],
                            [(110, 40, "z" * 120), (250, 20, "34"), (390, 20, "9%")]]),
    ]

    # Dense-row anchor shapes. Nothing above reaches this strategy: it wants
    # four or more non-uniform rules, four or more anchors spanning most of
    # the table, two rows independently reproducing the schema, and a body
    # that actually holds numbers.
    def dense_case(rules=None, verticals=(), body=None, header=None, x1=500, width=40,
                   row_gap=20):
        rules = rules if rules is not None else [
            (700, 100, x1), (685, 100, x1), (655, 100, x1), (610, 100, x1)]
        header = header if header is not None else [
            (110, "Name"), (200, "Q1"), (300, "Q2"), (400, "Q3")]
        body = body if body is not None else [
            [(110, "alpha"), (200, "10"), (300, "20"), (400, "30")],
            [(110, "beta"), (200, "11"), (300, "21"), (400, "31")],
            [(110, "gamma"), (200, "12"), (300, "22"), (400, "32")],
        ]
        items = [(x, 690, width, 10, tx) for x, tx in header]
        for row_index, row in enumerate(body):
            for x, tx in row:
                items.append((x, 670 - row_index * row_gap, width, 10, tx))
        return block(rules, list(verticals), items)

    even = [(700, 100, 500), (680, 100, 500), (660, 100, 500), (640, 100, 500),
            (620, 100, 500)]
    out += [
        # The shape it is for.
        dense_case(),
        # Accepting variants: five anchors, and a numeric body that only just
        # clears the quarter-of-filled-cells floor.
        dense_case(width=20,
                   header=[(110, "Name"), (190, "Q1"), (270, "Q2"), (350, "Q3"),
                           (430, "Q4")],
                   body=[[(110, f"r{i}"), (190, f"{i}0"), (270, f"{i}1"), (350, f"{i}2"),
                          (430, f"{i}3")] for i in range(4)]),
        dense_case(body=[[(110, "alpha"), (200, "10"), (300, "aa"), (400, "bb")],
                         [(110, "beta"), (200, "11"), (300, "cc"), (400, "dd")],
                         [(110, "gamma"), (200, "12"), (300, "ee"), (400, "ff")]]),
        # Three rules: under the minimum.
        dense_case(rules=[(700, 100, 500), (685, 100, 500), (655, 100, 500)]),
        # Five evenly spaced rules: ruled paper.
        dense_case(rules=even),
        # A gap far larger than the rest — two stacked bands, not one table.
        dense_case(rules=[(700, 100, 500), (685, 100, 500), (655, 100, 500),
                          (200, 100, 500)]),
        # Four evenly spaced levels inside an otherwise uneven band.
        dense_case(rules=[(700, 100, 500), (680, 100, 500), (660, 100, 500),
                          (640, 100, 500), (500, 100, 500)]),
        # A table under 100pt wide.
        dense_case(rules=[(700, 100, 180), (685, 100, 180), (655, 100, 180),
                          (610, 100, 180)],
                   header=[(105, "N"), (125, "A"), (145, "B"), (165, "C")],
                   body=[[(105, "a"), (125, "1"), (145, "2"), (165, "3")],
                         [(105, "b"), (125, "4"), (145, "5"), (165, "6")]]),
        # Two vertical strokes inside the band.
        dense_case(verticals=[(250, 610, 700), (350, 610, 700)]),
        # One is still allowed.
        dense_case(verticals=[(250, 610, 700)]),
        # Only one rule spans most of the width.
        dense_case(rules=[(700, 100, 500), (685, 100, 200), (655, 100, 200),
                          (610, 100, 200)]),
        # Three anchors, one short of the minimum.
        dense_case(header=[(110, "Name"), (200, "Q1"), (400, "Q2")],
                   body=[[(110, "alpha"), (200, "10"), (400, "30")],
                         [(110, "beta"), (200, "11"), (400, "31")],
                         [(110, "gamma"), (200, "12"), (400, "32")]]),
        # Four anchors crammed into less than 60% of the table width. The
        # items have to be narrow: 40pt-wide ones spaced 40pt apart touch
        # within the 6pt join gap and collapse to a single anchor, which is
        # how the first attempt at this case reached a different gate.
        dense_case(width=15,
                   header=[(110, "N"), (150, "A"), (190, "B"), (230, "C")],
                   body=[[(110, "a"), (150, "1"), (190, "2"), (230, "3")],
                         [(110, "b"), (150, "4"), (190, "5"), (230, "6")],
                         [(110, "c"), (150, "7"), (190, "8"), (230, "9")]]),
        # Only the header reproduces the schema; every body row is a stub.
        dense_case(body=[[(110, "alpha")], [(110, "beta")], [(110, "gamma")]]),
        # A body with no numbers in it at all.
        dense_case(body=[[(110, "alpha"), (200, "aa"), (300, "bb"), (400, "cc")],
                         [(110, "beta"), (200, "dd"), (300, "ee"), (400, "ff")],
                         [(110, "gamma"), (200, "gg"), (300, "hh"), (400, "ii")]]),
        # Three numbers — enough to clear the floor — but under a quarter of
        # the sixteen filled body cells.
        dense_case(body=[[(110, "alpha"), (200, "aa"), (300, "bb"), (400, "1")],
                         [(110, "beta"), (200, "dd"), (300, "ee"), (400, "2")],
                         [(110, "gamma"), (200, "gg"), (300, "hh"), (400, "3")],
                         [(110, "delta"), (200, "jj"), (300, "kk"), (400, "ll")]]),
        # More text rows than the rule levels corroborate.
        # More text rows than the rule levels corroborate. The rows have to
        # sit *inside* the band — at the default 20pt spacing ten of them fall
        # below the bottom rule and are never collected, which is how the
        # first attempt at this case quietly reached a different gate.
        dense_case(row_gap=6,
                   body=[[(110, f"r{i}"), (200, f"{i}0"), (300, f"{i}1"), (400, f"{i}2")]
                         for i in range(10)]),
    ]

    # Band-scoping shapes for the text-anchor pass. Text-anchor inference is
    # the fallback of last resort, so what matters here is what disqualifies a
    # band: dense line art, or verticals that suggest a real drawn grid.
    anchor_body = [[(110, 40, "alpha"), (250, 20, "12"), (390, 20, "5%")],
                   [(110, 40, "beta"), (250, 20, "34"), (390, 20, "9%")]]

    def band_case(verticals=(), paths=()):
        rules = [(700, 100, 500), (680, 100, 500), (560, 100, 500)]
        items = [(x, 690, w, 10, tx) for x, w, tx in three]
        for row_index, row in enumerate(anchor_body):
            for x, w, tx in row:
                items.append((x, 670 - row_index * 15, w, 10, tx))
        return block(rules, list(verticals), items, list(paths))

    out += [
        # A quiet band: nothing to disqualify it.
        band_case(),
        # Two spanning verticals — outer borders of a borderless table, still
        # allowed.
        band_case(verticals=[(100, 560, 700), (500, 560, 700)]),
        # A third spanning vertical is an interior divider: a physical grid.
        band_case(verticals=[(100, 560, 700), (300, 560, 700), (500, 560, 700)]),
        # Six short strokes inside the band: diagram evidence, even though no
        # single one spans it.
        band_case(verticals=[(120 + i * 60, 600, 620) for i in range(6)]),
        # Five of the same is under the bar.
        band_case(verticals=[(120 + i * 60, 600, 620) for i in range(5)]),
        # Two hundred path lines crossing the band: a chart or schematic.
        band_case(paths=[(110 + (i % 40), 600, 130 + (i % 40), 620) for i in range(200)]),
        # A hundred and ninety-nine is under the bar.
        band_case(paths=[(110 + (i % 40), 600, 130 + (i % 40), 620) for i in range(199)]),
        # Path lines wholly outside the band do not count.
        band_case(paths=[(110, 100, 130, 120) for _ in range(250)]),
        # Verticals outside the band's x range do not count either.
        band_case(verticals=[(600 + i * 20, 560, 700) for i in range(6)]),
    ]

    for _ in range(random_count):
        cols = rng.randint(2, 6)
        rows_n = rng.randint(1, 6)
        out.append(
            grid_case(
                cols, rows_n,
                x0=rng.choice([60, 100, 140]),
                width=rng.choice([80, 200, 400, 460]),
                row_gap=rng.choice([5, 12, 20, 30]),
                header=rng.random() < 0.8,
                vertical_span=rng.choice([0.5, 0.75, 0.85, 1.0]),
                first_header=rng.random() < 0.7,
            ))
    return out



def linetable_cases(random_count):
    """Cases for the line-table orchestrator, which takes raw strokes.

    Its own file: this entry point classifies lines itself, so the cases are
    `L x1 y1 x2 y2` strokes rather than pre-classified rules.
    """
    rng = random.Random(40_2026)

    def block(strokes, items):
        head = [f"L {a:g} {b:g} {c:g} {d:g}" for a, b, c, d in strokes]
        body = [f"{x:g} {y:g} {w:g} {s:g} {tx}" for x, y, w, s, tx in items]
        return "\n".join(head) + "\n\n" + "\n".join(body)

    def grid_strokes(rows, cols, x0=100, y0=700, cw=100, ch=25):
        strokes = []
        for r in range(rows + 1):
            y = y0 - r * ch
            strokes.append((x0, y, x0 + cols * cw, y))
        for c in range(cols + 1):
            x = x0 + c * cw
            strokes.append((x, y0, x, y0 - rows * ch))
        return strokes

    def grid_items(rows, cols, x0=100, y0=700, cw=100, ch=25, word="v"):
        return [
            (x0 + c * cw + 10, y0 - r * ch - 15, 40, 10, f"{word}{r}{c}")
            for r in range(rows) for c in range(cols)
        ]

    out = [
        # A drawn grid: the legacy endpoint path.
        block(grid_strokes(3, 3), grid_items(3, 3)),
        block(grid_strokes(5, 4), grid_items(5, 4)),
        # No lines at all.
        block([], [(110, 690, 40, 10, "a")]),
        # One horizontal rule.
        block([(100, 700, 400, 700)], [(110, 690, 40, 10, "a")]),
        # Strokes under 20pt are decoration and never classified.
        block([(100, 700, 115, 700), (100, 680, 115, 680), (100, 660, 115, 660)],
              [(105, 690, 10, 10, "a")]),
        # Diagonals are ignored outright.
        block([(100, 700, 400, 600), (100, 600, 400, 700)],
              [(110, 650, 40, 10, "a")]),
        # A stroke just inside two degrees off axis, and one just outside.
        block([(100, 700, 400, 710), (100, 660, 400, 660), (100, 620, 400, 620),
               (100, 700, 100, 620), (250, 700, 250, 620), (400, 700, 400, 620)],
              grid_items(2, 2, ch=40)),
        block([(100, 700, 400, 730), (100, 660, 400, 660), (100, 620, 400, 620),
               (100, 700, 100, 620), (250, 700, 250, 620), (400, 700, 400, 620)],
              grid_items(2, 2, ch=40)),
        # A short band with tall verticals: the rows span under 20pt even
        # though the strokes bounding them are long enough to be classified.
        block([(100, 700, 400, 700), (100, 690, 400, 690), (100, 682, 400, 682),
               (100, 710, 100, 675), (250, 710, 250, 675), (400, 710, 400, 675)],
              [(110, 695, 40, 10, "a"), (260, 695, 40, 10, "b"),
               (110, 685, 40, 10, "c"), (260, 685, 40, 10, "d")]),
        # Three horizontal rules too short to describe the table's width.
        block([(100, 700, 140, 700), (100, 640, 140, 640), (100, 580, 140, 580),
               (100, 710, 100, 570), (300, 710, 300, 570), (500, 710, 500, 570)],
              [(110, 690, 30, 10, "a"), (310, 690, 30, 10, "b"),
               (110, 630, 30, 10, "c"), (310, 630, 30, 10, "d")]),
        # Verticals present but far too short for the band's height.
        block([(100, 700, 500, 700), (100, 550, 500, 550), (100, 400, 500, 400),
               (100, 700, 100, 675), (300, 700, 300, 675), (500, 700, 500, 675)],
              [(110, 690, 30, 10, "a"), (310, 690, 30, 10, "b"),
               (110, 540, 30, 10, "c"), (310, 540, 30, 10, "d")]),
        # A bare page-spanning frame: decoration, not a table.
        # Three rules and two sides: still a bare frame by line count, which
        # is what the gate keys on rather than the page size.
        block([(50, 780, 560, 780), (50, 420, 560, 420), (50, 60, 560, 60),
               (50, 780, 50, 60), (300, 780, 300, 60), (560, 780, 560, 60)],
              [(110, 700, 40, 10, "a"), (300, 700, 40, 10, "b"),
               (110, 300, 40, 10, "c"), (300, 300, 40, 10, "d")]),
        # ...and the same paper size with internal rules, which is a ledger.
        block(grid_strokes(8, 4, x0=50, y0=780, cw=127, ch=90),
              grid_items(8, 4, x0=50, y0=780, cw=127, ch=90)),
        # Twenty-two column edges: a diagram.
        block(grid_strokes(2, 21, cw=25), grid_items(2, 21, cw=25)),
        # A grid narrower than 50pt, and one shorter than 20pt.
        block(grid_strokes(3, 2, cw=20), grid_items(3, 2, cw=20)),
        block(grid_strokes(2, 3, ch=8), grid_items(2, 3, ch=8)),
        # Evenly spaced row edges: chart gridlines.
        block(grid_strokes(6, 3, ch=30), grid_items(6, 3, ch=30)),
        # Text mostly outside the grid: a chart on a page of prose.
        block(grid_strokes(3, 3),
              grid_items(3, 3) + [(50, 200 - i * 12, 200, 10, f"prose line {i}")
                                  for i in range(40)]),
        # Only one column carries content.
        block(grid_strokes(3, 3),
              [(110, 700 - r * 25 - 15, 40, 10, f"a{r}") for r in range(3)]),
        # Booktabs: horizontal rules only, so the sparse strategies answer and
        # the orchestrator recurses on what is left.
        block([(100, 700, 500, 700), (100, 680, 500, 680), (100, 560, 500, 560)],
              [(110, 690, 40, 10, "Name"), (250, 690, 40, 10, "Count"),
               (390, 690, 40, 10, "Share"),
               (110, 670, 40, 10, "alpha"), (250, 670, 20, 10, "12"),
               (390, 670, 20, 10, "5%"),
               (110, 655, 40, 10, "beta"), (250, 655, 20, 10, "34"),
               (390, 655, 20, 10, "9%")]),
        # A booktabs band above an independent drawn grid, which is the shape
        # the recursion exists for.
        block([(100, 760, 500, 760), (100, 740, 500, 740), (100, 700, 500, 700)]
              + grid_strokes(3, 3, y0=600),
              [(110, 750, 40, 10, "Name"), (250, 750, 40, 10, "Count"),
               (390, 750, 40, 10, "Share"),
               (110, 730, 40, 10, "alpha"), (250, 730, 20, 10, "12"),
               (390, 730, 20, 10, "5%"),
               (110, 715, 40, 10, "beta"), (250, 715, 20, 10, "34"),
               (390, 715, 20, 10, "9%")]
              + grid_items(3, 3, y0=600)),
        # Segmented horizontal rules with no verticals: columns from endpoints.
        block([(100, 700 - r * 25, 200, 700 - r * 25) for r in range(4)]
              + [(210, 700 - r * 25, 310, 700 - r * 25) for r in range(4)]
              + [(320, 700 - r * 25, 420, 700 - r * 25) for r in range(4)],
              [(x + 10, 700 - r * 25 - 15, 40, 10, f"c{i}r{r}")
               for r in range(3) for i, x in enumerate([100, 210, 320])]),
    ]

    for _ in range(random_count):
        rows = rng.randint(1, 6)
        cols = rng.randint(1, 5)
        strokes = grid_strokes(
            rows, cols, x0=rng.choice([50, 100, 150]),
            cw=rng.choice([20, 60, 100, 140]), ch=rng.choice([8, 25, 40]))
        if rng.random() < 0.3:
            strokes = [s for s in strokes if rng.random() < 0.8]
        out.append(block(strokes, grid_items(rows, cols)))
    return out



def detector_cases(random_count):
    """Cases for the standalone detector helpers.

    Each case is three lines: page distribution, an OCR-reason analysis, and a
    hex byte buffer for the malformed-file page count.
    """
    rng = random.Random(41_2026)

    def block(d, a, b):
        return f"D {d[0]} {d[1]}\nA " + " ".join(str(v) for v in a) + f"\nB {b}"

    def hexed(text):
        return text.encode("latin-1").hex()

    out = []
    # Distribution edges, paired with a plain analysis and buffer.
    plain = (5, 0, 0, 9, 0, 0, 0)
    for d in [(0, 10), (1, 10), (2, 10), (3, 10), (5, 10), (10, 10), (11, 10),
              (3, 3), (3, 2), (3, 1), (1, 1), (2, 1), (4, 5), (7, 100), (2, 0),
              (1, 0), (0, 0), (50, 7), (6, 6), (4, 4)]:
        out.append(block(d, plain, hexed("/Type /Page\n")))

    # Every combination of the flags the OCR reason rule reads.
    for bits in range(64):
        analysis = (
            (bits & 1) * 5,          # text operators
            (bits >> 1) & 1,         # images
            (bits >> 2) & 1,         # template image
            ((bits >> 3) & 1) * 9,   # unique characters
            (bits >> 4) & 1,         # vector text
            (bits >> 5) & 1,         # identity-h without ToUnicode
            0,
        )
        out.append(block((3, 10), analysis, hexed("/Type/Page")))
    for type3 in (0, 1):
        out.append(block((3, 10), (0, 0, 0, 0, 0, 0, type3), hexed("")))

    # Byte-scan shapes.
    buffers = [
        "/Type /Page\n/Type /Pages\n/Type /Page\n",   # the Pages exclusion
        "/Type/Page/Type/Page",                        # no space, delimiter is /
        "/Type  \t\r\n /Page ",                        # every whitespace byte
        "/Type /Page",                                 # name runs to the end
        "/Type /Pages",                                # only the tree node
        "/Type /PageX",                                # a longer name
        "/Type/Page(",                                 # bracket delimiter
        "/Type/Page%",                                 # comment delimiter
        "/Type",                                       # truncated
        "/Typ",                                        # shorter than the needle
        "",                                            # empty
        "/Type /Font /Type /Page /Type /XObject",
        "/Type/Page" * 40,
        "no types here at all",
        "/Type\0/Page",                                # null as whitespace
    ]
    for text in buffers:
        out.append(block((3, 10), plain, hexed(text)))

    for _ in range(random_count):
        n = rng.randint(0, 30)
        total = rng.randint(0, 40)
        analysis = (rng.choice([0, 1, 7]), rng.randint(0, 1), rng.randint(0, 1),
                    rng.choice([0, 3]), rng.randint(0, 1), rng.randint(0, 1),
                    rng.randint(0, 1))
        fragments = ["/Type", " ", "/Page", "/Pages", "s", "x", "\n", "/", "(", "%"]
        text = "".join(rng.choice(fragments) for _ in range(rng.randint(0, 20)))
        out.append(block((n, total), analysis, hexed(text)))
    return out



def textquality_cases(random_count):
    """Cases for the markdown-level text-quality detectors.

    One hex-encoded UTF-8 string per line so arbitrary bytes survive, and one
    case per block. The interesting inputs are long: the cipher discriminator
    needs 200 ASCII letters before it will say anything at all.
    """
    rng = random.Random(42_2026)
    english = ("the quick brown fox jumps over the lazy dog while the "
               "committee reviewed every certificate and signed the report ")

    def shift(text, amount):
        out = []
        for ch in text:
            if "a" <= ch <= "z":
                out.append(chr((ord(ch) - 97 + amount) % 26 + 97))
            elif "A" <= ch <= "Z":
                out.append(chr((ord(ch) - 65 + amount) % 26 + 65))
            else:
                out.append(ch)
        return "".join(out)

    def straddle(text, amount):
        """Shift through the whole printable range, so lowercase lands in the
        uppercase block — which is what a broken CMap actually produces."""
        return "".join(
            chr(ord(ch) - amount) if "a" <= ch <= "z" else ch for ch in text)

    cases = [
        "",
        "clean english text without any problems at all",
        "a replacement lurks here: \ufffd",
        "\ufffd",
        # Dollar-as-space, from both trigger arms.
        "Word$Word$Word$" + "Name$Value$" * 6,
        "price $10 and $20 and $30 and $40 and $50 and $60 and $70 and $80 "
        "and $90 and $100 and $110 and $120",
        "a$b " * 25,
        english * 4,                       # long, clean
        english[:180],                     # under the 200-letter floor
        shift(english * 4, 7),             # in-alphabet substitution
        shift(english * 4, 13),
        straddle(english * 4, 30),         # case-straddling shift
        (english * 4).upper(),             # all caps, still English
        "ACGT" * 300,                      # DNA: steep profile
        "0123456789abcdef" * 60,           # hex dump
        "AAAAA" * 100,                     # single letter
        "aeiou" * 100,                     # all vowels
        "bcdfg" * 100,                     # no vowels, flat profile
        "日本語のテキストがここにあります" * 30,   # non-Latin dominant
        "naïve café résumé Ångström " * 40,      # Latin extended
        "camelCaseIdentifier " * 60,             # case shifts, legitimate
    ]

    # Span-level shapes: private-use runs, C1 controls, symbol soup and the
    # CID-as-Latin-1 mojibake that a CJK document produces when its mapping
    # fails. None of the markdown-level cases above reach these.
    pua = "\ue000\ue001\ue002"
    cases += [
        pua,                                     # a three-long private-use run
        "\ue000\ue001",                          # two: under the run bar
        "ab\ue000cd\ue001ef",                    # scattered, minority
        "a\ue000\ue001",                         # majority of a short span
        "x\ue000 y\ue001 z\ue002",                # whitespace breaks the runs
        "\ufffd\ufffd",                          # a two-long replacement run
        "\ufffd a \ufffd b \ufffd",                # three scattered
        "\ufffd a",                               # one, below every bar
        "ab\u0080\u0081cd",                      # C1 controls in one token
        "ab\u0080cd",                             # one control: not enough
        "\u0080\u0081\u0082\u0083\u0084",           # all controls
        "----1-.-.-.___  --.-. .._ I_---." * 3,  # symbol soup
        "table of contents . . . . . . . . . . 12",
        "Chapter one" + "." * 40 + "7",          # a leader run, skipped
        "#" * 60,                                # markdown syntax only
        "*|-#" * 30,
        "".join(chr(0xC0 + (i % 48)) for i in range(60)),   # high Latin-1
        "".join(chr(0xC0 + (i % 48)) for i in range(60)) + "abcdefghij" * 3,
        "2×()×",                                 # a short maths token
        "a·b·c" * 20,                            # middle dots
        "\u00b7" * 30,
        "1234567890" * 10,                       # digits only
        "ⅣⅤⅥ ½¾ ٣٤٥" * 8,                        # non-ASCII numerics
    ]

    for _ in range(random_count):
        kind = rng.randrange(6)
        if kind == 0:
            text = "".join(rng.choice("abcdefghijklmnopqrstuvwxyz ")
                           for _ in range(rng.randint(0, 400)))
        elif kind == 1:
            text = shift(english * rng.randint(1, 5), rng.randrange(26))
        elif kind == 2:
            text = straddle(english * rng.randint(1, 5), rng.randrange(20, 40))
        elif kind == 3:
            text = "".join(rng.choice("$abcXYZ 019") for _ in range(rng.randint(0, 200)))
        elif kind == 4:
            text = "".join(rng.choice("aeiouéüñ日本 \ufffd")
                           for _ in range(rng.randint(0, 300)))
        else:
            alphabet = "ab \ue000\ue001\ufffd\u0080\u0081\u00b7.-_#|" + chr(0xC5)
            text = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 120)))
        cases.append(text)

    return [text.encode("utf-8").hex() for text in cases]



def bidi_cases(random_count):
    """Cases for script classification and visual-order reversal.

    One hex-encoded UTF-8 string per case. The reversal is the interesting
    part: mixed Arabic and Latin has to keep the Latin runs running the other
    way, so most of these carry both.
    """
    rng = random.Random(44_2026)
    arabic = "\u0645\u0631\u062d\u0628\u0627"          # marhaba
    hebrew = "\u05e9\u05dc\u05d5\u05dd"                # shalom
    forms = "\ufb50\ufe70\ufdf2"                       # presentation forms
    cjk = "\u65e5\u672c\u8a9e"

    cases = [
        "",
        "plain latin text",
        arabic,
        arabic + " " + arabic,
        hebrew,
        forms,
        forms + arabic,
        "\ufeff",                                        # BOM: not a form
        "\ufefe",                                        # the last real form
        cjk,
        cjk + arabic,
        cjk + "latin",
        arabic + " 2024",
        "2024 " + arabic,
        arabic + " 3.5 " + arabic,
        arabic + " A/B " + arabic,
        arabic + " ABC " + hebrew,
        "3.5",
        ".",
        "..." + arabic,
        arabic + "!",
        "C2_0",                                          # CID font prefixes
        "C0_1",
        "C3_0",
        "Helvetica",
        arabic + " C2_0 " + arabic,
        "a" + arabic + "b",
        "\u0600\u06ff\u0700\u074f\u0750\u077f",         # block boundaries
        "\u0780\u07bf\u07c0\u07ff\u0800\u083f",
        "\u0840\u085f\u08a0\u08ff\ufb1d\ufb4f",
        "\u1100\u11ff\u3000\u303f\u3040\u309f",
        "\u30a0\u30ff\u3130\u318f\u4e00\u9fff",
        "\uac00\ud7af\uf900\ufaff\uff00\uffef",
    ]

    alphabet = list(arabic + hebrew + cjk + "abcXYZ019 ./-,!") + ["\ufb50", "\ufe70"]
    for _ in range(random_count):
        cases.append("".join(rng.choice(alphabet) for _ in range(rng.randint(0, 40))))

    return [c.encode("utf-8").hex() for c in cases]



def letterspacing_cases(random_count):
    """Cases for Canva-style letter-spacing repair.

    Each block is `x y width font_size text` item lines; tildes stand in for
    spaces so the field split stays simple.
    """
    rng = random.Random(45_2026)

    def block(items):
        return "\n".join(f"{x:g} {y:g} {w:g} {s:g} {t}" for x, y, w, s, t in items)

    def spaced(words, x0=100, size=10, gap=6):
        """Items carrying the `a~b~c` pattern."""
        out = []
        x = x0
        for word in words:
            text = "~".join(word)
            width = len(text) * size * 0.5
            out.append((x, 700, width, size, text))
            x += width + gap
        return out

    def per_char(text, x0=100, size=10, gap=6):
        """One item per character, no spaces inside them."""
        out = []
        x = x0
        for ch in text:
            width = size * 0.5
            out.append((x, 700, width, size, ch))
            x += width + gap
        return out

    cases = [
        block([]),
        block(spaced(["arib", "text", "here", "again"])),
        block(spaced(["ab"])),                       # too few substantial items
        block(spaced(["arib", "text"]) + [(400, 700, 40, 10, "normal~words~here")]),
        block(per_char("abcdefghijkl")),             # the per-character variant
        block(per_char("abcdefghijkl", gap=1)),      # gaps too small to qualify
        block(per_char("abcdefgh")),                 # under ten items
        block([(100, 700, 40, 10, "ordinary"), (150, 700, 40, 10, "words")]),
        # CJK pairs are skipped when collecting ratios.
        block([(100 + i * 30, 700, 20, 10, "\u65e5") for i in range(12)]),
        block([(100 + i * 30, 700, 20, 10, "a" if i % 2 else "\u65e5")
               for i in range(12)]),
        # Zero width and zero font size are skipped.
        block([(100 + i * 30, 700, 0, 10, "a") for i in range(12)]),
        block([(100 + i * 30, 700, 20, 0, "a") for i in range(12)]),
        # Right-to-left ordering: the gap is measured the other way.
        block([(400 - i * 30, 700, 20, 10, "a") for i in range(12)]),
        # Ratios beyond three are discarded as column jumps.
        block([(100 + i * 200, 700, 20, 10, "a") for i in range(12)]),
        # Exactly at the 0.40 floor, and just under it.
        block([(100 + i * 24, 700, 20, 10, "a") for i in range(12)]),
        block([(100 + i * 23, 700, 20, 10, "a") for i in range(12)]),
        # A three-byte CJK item, which is substantial by byte length but one
        # character long.
        block([(100 + i * 30, 700, 20, 10, "\u65e5") for i in range(4)]
              + spaced(["arib", "text", "here"], x0=500)),
    ]

    # Accepting shapes across the threshold's range, since the default is
    # otherwise almost the only answer seen.
    for gap in (5, 6, 8, 10, 12, 15, 25):
        # Per-character items at a fixed gap: ratio is gap / font_size.
        cases.append(block([(100 + i * (5 + gap), 700, 5, 10, "a") for i in range(14)]))
        # The `a~b~c` variant at the same spacing.
        cases.append(
            block(spaced(["arib", "text", "here", "again", "more"], gap=gap)))
    # A gap of 15 on a 10pt font gives a median ratio of 1.5, so the raw
    # threshold of 2.325 is cut by the upper clamp.
    cases.append(block([(100 + i * 20, 700, 5, 10, "a") for i in range(14)]))

    for _ in range(random_count):
        count = rng.randint(0, 16)
        items = []
        x = rng.choice([50.0, 100.0])
        for _ in range(count):
            size = rng.choice([0.0, 8.0, 10.0, 14.0])
            width = rng.choice([0.0, 5.0, 20.0, 40.0])
            text = rng.choice(["a", "ab", "a~b", "a~b~c", "word", "\u65e5", "~", "abc"])
            items.append((x, 700.0, width, size, text))
            x += width + rng.choice([0.0, 2.0, 6.0, 20.0, 300.0])
        cases.append(block(items))
    return cases



def join_cases(random_count):
    """Cases for the join decision.

    One line per case: `threshold prev_x prev_w prev_size prev_font prev_text
    curr_x curr_w curr_size curr_font curr_text`. Tildes stand in for spaces
    inside the texts so the field split stays simple.
    """
    rng = random.Random(46_2026)

    def case(prev_text, curr_text, gap=2.0, threshold=0.10, prev_w=20.0, size=10.0,
             font="F1", curr_w=20.0, rtl=False):
        prev_x = 100.0
        curr_x = prev_x + prev_w + gap
        if rtl:
            prev_x, curr_x = curr_x, prev_x
            prev_x, curr_x = curr_x + curr_w + gap, 100.0
        return (f"{threshold:g} {prev_x:g} {prev_w:g} {size:g} {font} {prev_text} "
                f"{curr_x:g} {curr_w:g} {size:g} F1 {curr_text}")

    out = [
        # Explicit spaces win outright.
        case("word~", "next"),
        case("word", "~next"),
        # Punctuation that never takes a leading space.
        *[case("www", p) for p in [".com", ",x", ";x", "!x", "?x", ")x", "]x", "}x", "'x"]],
        # A colon before a value.
        case("Clave:", "T9N2I6"),
        case("Clave:", "-x"),
        # Column-scale gaps and large overlaps.
        case("word", "next", gap=31),
        case("word", "next", gap=-11),
        case("word", "next", gap=-9),
        # CID fonts: a zero gap means a space.
        case("word", "next", gap=0.0, font="C2_0"),
        case("one~two~three", "next", gap=0.0, font="C2_0"),
        case("one~two~three", "next", gap=1.6, font="C2_0"),
        case("word", "next", gap=0.0, font="F1"),
        case("\u65e5", "\u672c", gap=0.0, font="C2_0"),
        # Numeric continuity.
        case("34,20", "8", gap=2),
        case("34,20", "8", gap=4),
        case("+13.", "0", gap=2),
        case("-13", "0", gap=2),
        case("13", "%", gap=2),
        # Letter-spaced pages.
        case("a", "b", gap=5, threshold=0.8, prev_w=5),
        case("a", "b", gap=7, threshold=0.8, prev_w=5),
        case("abc", "d", gap=5, threshold=0.8, prev_w=15),
        case("abc", "def", gap=5, threshold=0.8, prev_w=15),
        # Single against multi.
        case("b", "illion", gap=1),
        case("b", "illion", gap=3),
        case("illion", "b", gap=1),
        # Both single.
        case("a", "b", gap=0.5),
        case("a", "b", gap=2),
        case("1", "2", gap=2),
        case(",", "5", gap=2),
        # Multi against multi, by case.
        case("enterta", "inment", gap=1.7),
        case("enterta", "inment", gap=1.9),
        case("LCOE", "WITH", gap=1.4),
        case("LCOE", "WITH", gap=1.6),
        # Right-to-left ordering.
        case("word", "next", gap=2, rtl=True),
        # The fallback path: no measured width.
        case("CONST", "ANCIA", gap=2, prev_w=0),
        case("presente", "CONSTANCIA", gap=0.1, prev_w=0),
        case("REGISTRO", "para", gap=1, prev_w=0),
        case("REGISTRO", "para", gap=2, prev_w=0),
        case("word", "next", gap=100, prev_w=0),
        case("\u65e5", "\u672c", gap=2, prev_w=0),
        case("1", "2", gap=1, prev_w=0),
    ]

    texts = ["word", "next", "a", "b", "1", "2", ",", ".", "%", "+", ":", "www", ".com",
             "\u65e5", "ABC", "abc", "Abc", "enterta", "inment", "~x", "x~", "one~two~three"]
    fonts = ["F1", "C2_0", "C0_1"]
    for _ in range(random_count):
        out.append(case(
            rng.choice(texts), rng.choice(texts),
            gap=rng.choice([-12.0, -5.0, 0.0, 0.5, 1.0, 1.6, 2.0, 3.0, 5.0, 31.0]),
            threshold=rng.choice([0.10, 0.25, 0.8, 1.5]),
            prev_w=rng.choice([0.0, 5.0, 20.0]),
            size=rng.choice([8.0, 10.0]),
            font=rng.choice(fonts),
            curr_w=rng.choice([5.0, 20.0])))
    return out



def structname_cases(random_count):
    """Cases for the bare-struct-name repair. One hex buffer per case."""
    rng = random.Random(47_2026)
    root = "/StructTreeRoot"
    names = ["Document", "Part", "H", "H1", "H6", "P", "L", "LI", "Lbl", "LBody",
             "Table", "TR", "TH", "TD", "Span", "Code", "Figure", "Formula", "WP"]

    cases = [
        "",
        "no struct tree here /S Code",              # the quick check bails
        root + " /S /Code",                          # already correct
        root + " /S Code",                           # the motivating case
        root + " /S Code\n/S P\n",
        root + " /S H1 /S H /S H6",                  # the H prefix trap
        root + " /S LI /S L /S LBody",               # and the L one
        root + " /S Unknown",                        # not a struct type
        root + " /S Codex",                          # a longer word
        root + " /S Code>",                          # each delimiter
        root + " /S Code/",
        root + " /S Code\r",
        root + " /S Code",                           # ends the buffer
        root + " /S ",                               # nothing after
        root + " /S",                                # no trailing space
        root + " /S  Code",                          # two spaces
        root + " /S Code /S Code /S Code",           # repeated repairs
        root + " /S /Code /S Table",                 # mixed
        root,
        "/S Code" + root,                            # the marker after the fault
    ]

    fragments = ["/S ", "/S /", root, " ", "\n", "Code", "P", "H", "H1", "x", ">", "/"]
    for _ in range(random_count):
        cases.append("".join(rng.choice(fragments) for _ in range(rng.randint(0, 24))))

    return [c.encode("utf-8").hex() for c in cases]



def structtree_cases(random_count):
    """Cases for the structure-tree walks.

    A case is `depth role mcids alt` lines in document order; mcids are
    `id:page` pairs, and a page of 0 means the element declared no page.
    """
    rng = random.Random(48_2026)

    def line(depth, role, mcids="-", alt="-"):
        return f"{depth} {role} {mcids} {alt}"

    cases = [
        "",
        line(0, "P"),
        # A proper two-row table.
        "\n".join([
            line(0, "Table"),
            line(1, "TR"), line(2, "TH", "1:1"), line(2, "TH", "2:1"),
            line(1, "TR"), line(2, "TD", "3:1"), line(2, "TD", "4:1"),
        ]),
        # One row only: not a table.
        "\n".join([line(0, "Table"), line(1, "TR"), line(2, "TD", "1:1")]),
        # Two rows but no cells at all.
        "\n".join([line(0, "Table"), line(1, "TR"), line(1, "TR")]),
        # Rows behind THead/TBody/TFoot grouping.
        "\n".join([
            line(0, "Table"),
            line(1, "THead"), line(2, "TR"), line(3, "TH", "1:1"),
            line(1, "TBody"), line(2, "TR"), line(3, "TD", "2:1"),
            line(1, "TFoot"), line(2, "TR"), line(3, "TD", "3:1"),
        ]),
        # A table nested inside another: the outer one owns the descent.
        "\n".join([
            line(0, "Table"),
            line(1, "TR"), line(2, "TD", "1:1"),
            line(2, "TD"), line(3, "Table"),
            line(4, "TR"), line(5, "TD", "2:1"),
            line(4, "TR"), line(5, "TD", "3:1"),
            line(1, "TR"), line(2, "TD", "4:1"),
        ]),
        # A table buried under containers.
        "\n".join([
            line(0, "Document"), line(1, "Sect"), line(2, "Div"),
            line(3, "Table"),
            line(4, "TR"), line(5, "TD", "1:1"),
            line(4, "TR"), line(5, "TD", "2:1"),
        ]),
        # Two tables side by side.
        "\n".join([
            line(0, "Table"), line(1, "TR"), line(2, "TD", "1:1"),
            line(1, "TR"), line(2, "TD", "2:1"),
            line(0, "Table"), line(1, "TR"), line(2, "TD", "3:2"),
            line(1, "TR"), line(2, "TD", "4:2"),
        ]),
        # MCIDs gathered from descendants of a cell.
        "\n".join([
            line(0, "Table"),
            line(1, "TR"), line(2, "TD", "1:1"), line(3, "Span", "2:1"),
            line(4, "Span", "3:1"),
            line(1, "TR"), line(2, "TD", "4:1"),
        ]),
        # A reference with no page is dropped.
        "\n".join([
            line(0, "Table"),
            line(1, "TR"), line(2, "TD", "1:0,2:1"),
            line(1, "TR"), line(2, "TD", "3:0"),
        ]),
        # Non-cell children of a row are ignored.
        "\n".join([
            line(0, "Table"),
            line(1, "TR"), line(2, "Span", "1:1"), line(2, "TD", "2:1"),
            line(1, "TR"), line(2, "TD", "3:1"),
        ]),
        # Deep nesting for the flattened view.
        "\n".join([
            line(0, "Document", "-", "cover"),
            line(1, "Sect"), line(2, "H1", "1:1"), line(2, "P", "2:1"),
            line(1, "Figure", "3:1", "a-seal"),
        ]),
        # Every non-heading role at the top level.
        "\n".join(line(0, r) for r in
                   ["L", "LI", "Lbl", "LBody", "BlockQuote", "Quote", "Caption", "TOC",
                    "TOCI", "Index", "Note", "Reference", "BibEntry", "Code", "Formula",
                    "Form", "Table", "TR", "TH", "TD", "THead", "TBody", "TFoot"]),
        # And the roles that are deliberately not in that set.
        "\n".join(line(0, r) for r in
                   ["Figure", "H", "H1", "P", "Div", "Sect", "Span", "Link", "Annot",
                    "Custom"]),
    ]

    roles = ["Document", "Sect", "Div", "Table", "TR", "TD", "TH", "THead", "TBody",
             "TFoot", "P", "H1", "Span", "Figure", "L", "LI", "Weird"]
    for _ in range(random_count):
        lines = []
        depth = 0
        for _ in range(rng.randint(0, 14)):
            depth = max(0, min(depth + rng.choice([-1, 0, 0, 1, 1]), 5))
            mcids = "-" if rng.random() < 0.5 else ",".join(
                f"{rng.randint(0, 5)}:{rng.randint(0, 3)}"
                for _ in range(rng.randint(1, 3)))
            lines.append(line(depth, rng.choice(roles), mcids))
        cases.append("\n".join(lines))
    return cases



def structcol_cases(random_count):
    """Cases for column inference and the DP alignment."""
    rng = random.Random(49_2026)

    def block(rows, fallback, num_cols, alignments):
        lines = [f"R {','.join(rows_i)}" for rows_i in rows]
        lines.append("F " + ",".join(f"{v:g}" for v in fallback))
        lines.append(f"N {num_cols}")
        for cells, cols in alignments:
            lines.append("A " + ",".join(f"{v:g}" for v in cells) + " | "
                         + ",".join(f"{v:g}" for v in cols))
        return "\n".join(lines)

    cases = [
        # No rows at all: the fallback is the whole answer.
        block([], [100, 200, 300], 3, []),
        block([], [], 3, []),
        # A full row supplies every anchor.
        block([["100", "200", "300"]], [], 3, []),
        # A ragged row plus a full one: the widest wins.
        block([["100", "-", "300"], ["100", "200", "300"]], [], 3, []),
        # Two rows tie on width — the later one wins.
        block([["100", "200"], ["150", "250"]], [], 2, []),
        # More anchors than columns: truncated.
        block([["100", "200", "300", "400"]], [], 2, []),
        # Filling from other rows, then the fallback.
        block([["100", "-", "-"], ["-", "200", "-"]], [400], 4, []),
        block([["100"]], [200, 300], 3, []),
        # Positions inside the 18pt tolerance do not add a column.
        block([["100"], ["110"], ["117"], ["119"]], [], 3, []),
        # Padding by repeating the last anchor.
        block([["100", "200"]], [], 5, []),
        # Alignments: trivially the identity when cells outnumber columns.
        block([], [], 0, [([100, 200, 300], [100, 200])]),
        block([], [], 0, [([100, 200], [100, 200])]),
        # A short row against wide columns.
        block([], [], 0, [([100, 300], [100, 200, 300, 400])]),
        block([], [], 0, [([210, 310], [100, 200, 300, 400])]),
        block([], [], 0, [([405], [100, 200, 300, 400])]),
        block([], [], 0, [([100], [100, 200, 300, 400])]),
        # Equidistant, which the tie rule biases left.
        block([], [], 0, [([150], [100, 200])]),
        # Empty inputs.
        block([], [], 0, [([], [100, 200])]),
        block([], [], 0, [([100], [])]),
    ]

    for _ in range(random_count):
        rows = []
        for _ in range(rng.randint(0, 4)):
            rows.append([
                "-" if rng.random() < 0.3 else f"{rng.randrange(50, 500)}"
                for _ in range(rng.randint(0, 5))
            ])
        fallback = [float(rng.randrange(50, 500)) for _ in range(rng.randint(0, 4))]
        alignments = []
        for _ in range(rng.randint(0, 3)):
            cells = sorted(float(rng.randrange(50, 500)) for _ in range(rng.randint(0, 5)))
            cols = sorted(float(rng.randrange(50, 500)) for _ in range(rng.randint(0, 6)))
            alignments.append((cells, cols))
        cases.append(block(rows, fallback, rng.randint(0, 6), alignments))
    return cases



def structrow_cases(random_count):
    """Cases for the two row-alignment strategies."""
    rng = random.Random(50_2026)

    def cell(text="-", items="-", x="-", y="-"):
        return f"{text}:{items}:{x}:{y}"

    def block(columns, num_cols, rows):
        lines = ["C " + ",".join(f"{v:g}" for v in columns), f"N {num_cols}"]
        lines += ["R " + " ".join(r) for r in rows]
        return "\n".join(lines)

    cases = [
        block([], 0, []),
        block([100, 200, 300], 3, []),
        # Every cell positioned: the DP places them.
        block([100, 200, 300], 3, [[cell("a", "0", "100", "700"),
                                    cell("b", "1", "300", "700")]]),
        # A cell with no position: the whole row falls back to left-filling.
        block([100, 200, 300], 3, [[cell("a", "0", "100", "700"),
                                    cell("b", "1", "-", "700")]]),
        # Empty but positioned cells still occupy a column.
        block([100, 200, 300], 3, [[cell("-", "-", "100", "700"),
                                    cell("b", "1", "300", "700")]]),
        # A wholly absent cell is skipped.
        block([100, 200, 300], 3, [[cell(), cell("b", "1", "300", "700")]]),
        # Two cells landing in one column are joined with a space.
        block([100, 300], 2, [[cell("a", "0", "100", "700"),
                               cell("b", "1", "105", "700")]]),
        # More cells than columns: the tail is dropped along with its items.
        block([100], 1, [[cell("a", "0", "100", "700"), cell("b", "1", "200", "700"),
                          cell("c", "2", "300", "700")]]),
        # Left-align truncates and pads.
        block([], 2, [[cell("a", "0"), cell("b", "1"), cell("c", "2")]]),
        block([], 4, [[cell("a", "0"), cell("b", "1")]]),
        # Row baselines take the highest y present.
        block([100, 200], 2, [[cell("a", "0", "100", "690"),
                               cell("b", "1", "200", "700")]]),
        block([100, 200], 2, [[cell("a", "0", "100", "-"), cell("b", "1", "200", "-")]]),
        # No columns at all.
        block([], 0, [[cell("a", "0", "100", "700")]]),
        # Text carrying a space.
        block([100, 200], 2, [[cell("two~words", "0", "100", "700")]]),
    ]

    for _ in range(random_count):
        columns = sorted(float(rng.randrange(50, 500)) for _ in range(rng.randint(0, 4)))
        rows = []
        for _ in range(rng.randint(0, 4)):
            row = []
            for index in range(rng.randint(0, 5)):
                row.append(cell(
                    rng.choice(["-", "a", "b", "two~words"]),
                    rng.choice(["-", str(index), f"{index}.{index + 10}"]),
                    rng.choice(["-", str(rng.randrange(50, 500))]),
                    rng.choice(["-", str(rng.randrange(600, 750))])))
            rows.append(row)
        cases.append(block(columns, rng.randint(0, 5), rows))
    return cases



def structheader_cases(random_count):
    """Cases for unclaimed-header recovery."""
    rng = random.Random(51_2026)

    def block(columns, rows, cells, claimed, items, ragged=True):
        lines = [f"G {1 if ragged else 0}",
                 "C " + ",".join(f"{v:g}" for v in columns),
                 "Y " + ",".join(f"{v:g}" for v in rows),
                 "X " + ",".join(str(v) for v in claimed)]
        for row in cells:
            lines.append("E " + "\t".join(row))
        for x, y, text in items:
            lines.append(f"I {x:g} {y:g} {text}")
        return "\n".join(lines)

    cols = [100.0, 200.0, 300.0]
    body = [["a", "b", "c"], ["d", "e", "f"]]
    body_rows = [700.0, 680.0]
    body_claimed = [0, 1, 2, 3, 4, 5]

    def body_items():
        return [(100.0, 700.0, "a"), (200.0, 700.0, "b"), (300.0, 700.0, "c"),
                (100.0, 680.0, "d"), (200.0, 680.0, "e"), (300.0, 680.0, "f")]

    header = [(100.0, 715.0, "H0"), (200.0, 715.0, "H1"), (300.0, 715.0, "H2")]

    cases = [
        # The shape it is for.
        block(cols, body_rows, body, body_claimed, body_items() + header),
        # Not ragged: leave it alone.
        block(cols, body_rows, body, body_claimed, body_items() + header, ragged=False),
        # Two columns only.
        block([100.0, 200.0], body_rows, [["a", "b"], ["c", "d"]], [0, 1, 2, 3],
              [(100.0, 700.0, "a"), (200.0, 700.0, "b"), (100.0, 680.0, "c"),
               (200.0, 680.0, "d"), (100.0, 715.0, "H0"), (200.0, 715.0, "H1")]),
        # No rows.
        block(cols, [], [], [], header),
        # Header too far above the table.
        block(cols, body_rows, body, body_claimed,
              body_items() + [(x, 745.0, t) for x, _, t in header]),
        # Beyond the 90pt search window entirely.
        block(cols, body_rows, body, body_claimed,
              body_items() + [(x, 800.0, t) for x, _, t in header]),
        # Two header lines, close enough to join.
        block(cols, body_rows, body, body_claimed,
              body_items() + header + [(x, 735.0, "T" + t) for x, _, t in header]),
        # Two lines too far apart.
        block(cols, body_rows, body, body_claimed,
              body_items() + header + [(x, 745.0, "T" + t) for x, _, t in header]),
        # Four lines: only three are taken.
        block(cols, body_rows, body, body_claimed,
              body_items() + header
              + [(x, 730.0, "P" + t) for x, _, t in header]
              + [(x, 745.0, "Q" + t) for x, _, t in header]
              + [(x, 760.0, "R" + t) for x, _, t in header]),
        # Only one column populated on the closest line.
        block(cols, body_rows, body, body_claimed,
              body_items() + [(100.0, 715.0, "H0")]),
        # Two of three columns: under the requirement for a narrow table.
        block(cols, body_rows, body, body_claimed,
              body_items() + [(100.0, 715.0, "H0"), (200.0, 715.0, "H1")]),
        # Five columns with one unlabelled, which is allowed.
        block([100.0, 200.0, 300.0, 400.0, 500.0], body_rows,
              [["a", "b", "c", "d", "e"], ["f", "g", "h", "i", "j"]],
              list(range(10)),
              [(100.0 + i * 100, 700.0, "x") for i in range(5)]
              + [(100.0 + i * 100, 680.0, "y") for i in range(5)]
              + [(100.0 + i * 100, 715.0, f"H{i}") for i in range(4)]),
        # More items on a line than there are columns.
        block(cols, body_rows, body, body_claimed,
              body_items() + [(100.0, 715.0, "H0"), (150.0, 715.0, "H1"),
                              (200.0, 715.0, "H2"), (300.0, 715.0, "H3")]),
        # Already-claimed items above the table are ignored.
        block(cols, body_rows, body, body_claimed + [6, 7, 8],
              body_items() + header),
        # Text outside the x window.
        block(cols, body_rows, body, body_claimed,
              body_items() + [(20.0, 715.0, "H0"), (200.0, 715.0, "H1"),
                              (300.0, 715.0, "H2")]),
        # ...and inside the generous right-hand margin.
        block(cols, body_rows, body, body_claimed,
              body_items() + [(100.0, 715.0, "H0"), (200.0, 715.0, "H1"),
                              (415.0, 715.0, "H2")]),
        # Blank text above the table.
        block(cols, body_rows, body, body_claimed,
              body_items() + [(100.0, 715.0, "~"), (200.0, 715.0, "H1"),
                              (300.0, 715.0, "H2")]),
    ]

    # Well-formed headers across column counts and line counts, since the
    # randomised cases below almost never happen to line up with the columns.
    for n in (3, 4, 5, 6):
        columns = [100.0 + i * 100 for i in range(n)]
        cells = [["x"] * n, ["y"] * n]
        claimed = list(range(2 * n))
        base = ([(100.0 + i * 100, 700.0, "x") for i in range(n)]
                + [(100.0 + i * 100, 680.0, "y") for i in range(n)])
        for lines in (1, 2, 3):
            extra = []
            for line_index in range(lines):
                y = 715.0 + line_index * 15
                extra += [(100.0 + i * 100, y, f"H{line_index}{i}") for i in range(n)]
            cases.append(block(columns, [700.0, 680.0], cells, claimed, base + extra))
        # A header offset slightly from the column positions still aligns.
        cases.append(block(columns, [700.0, 680.0], cells, claimed,
                           base + [(104.0 + i * 100, 715.0, f"H{i}") for i in range(n)]))
        # ...and one column short, which a wide table tolerates.
        cases.append(block(columns, [700.0, 680.0], cells, claimed,
                           base + [(100.0 + i * 100, 715.0, f"H{i}")
                                   for i in range(n - 1)]))

    for _ in range(random_count):
        n = rng.randint(2, 5)
        columns = [100.0 + i * 100 for i in range(n)]
        rows_y = [700.0, 680.0]
        cells = [["x"] * n, ["y"] * n]
        claimed = list(range(2 * n))
        items = [(100.0 + i * 100, 700.0, "x") for i in range(n)]
        items += [(100.0 + i * 100, 680.0, "y") for i in range(n)]
        for _ in range(rng.randint(0, 6)):
            items.append((float(rng.randrange(50, 550)), float(rng.randrange(690, 800)),
                          rng.choice(["H", "Head", "~", "long~label"])))
        cases.append(block(columns, rows_y, cells, claimed, items,
                           ragged=rng.random() < 0.8))
    return cases



def structtable_cases(random_count):
    """Cases for the struct-tree table orchestrator."""
    rng = random.Random(52_2026)

    def build(rows, items):
        lines = ["T"]
        for row in rows:
            lines.append("R")
            for header, mcids in row:
                lines.append(f"D {1 if header else 0} {mcids}")
        for x, y, mcid, text in items:
            lines.append(f"I {x:g} {y:g} {mcid} {text}")
        return "\n".join(lines)

    def grid(cols, row_count, page=1, header_first=False, start=0):
        rows = []
        mcid = start
        for r in range(row_count):
            row = []
            for _ in range(cols):
                row.append((header_first and r == 0, f"{mcid}:{page}"))
                mcid += 1
            rows.append(row)
        return rows

    def grid_items(cols, row_count, start=0, x0=100.0, y0=700.0, skip=()):
        out = []
        mcid = start
        for r in range(row_count):
            for c in range(cols):
                if mcid not in skip:
                    out.append((x0 + c * 100, y0 - r * 20, mcid, f"v{r}{c}"))
                mcid += 1
        return out

    cases = [
        # Nothing at all.
        "I 100 700 0 x",
        # A clean tagged table.
        build(grid(3, 3), grid_items(3, 3)),
        # A tagged header row, so no recovery is attempted.
        build(grid(3, 3, header_first=True), grid_items(3, 3)),
        # One row on this page only.
        build(grid(3, 1), grid_items(3, 1)),
        # One column.
        build(grid(1, 3), grid_items(1, 3)),
        # Rows on another page are filtered out.
        build(grid(3, 3, page=2), grid_items(3, 3)),
        # Stale tree: under a third of cells resolve.
        build(grid(3, 3), grid_items(3, 3, skip=set(range(1, 9)))),
        # Just over the coverage line.
        build(grid(3, 3), grid_items(3, 3, skip={0, 1, 2, 3, 4})),
        # Ragged rows with a header above: the recovery path.
        build(grid(3, 3), grid_items(3, 3, skip={4})
              + [(100.0, 715.0, 99, "H0"), (200.0, 715.0, 98, "H1"),
                 (300.0, 715.0, 97, "H2")]),
        # Ragged, but the first row is tagged as a header already.
        build(grid(3, 3, header_first=True), grid_items(3, 3, skip={4})
              + [(100.0, 715.0, 99, "H0"), (200.0, 715.0, 98, "H1"),
                 (300.0, 715.0, 97, "H2")]),
        # Two cells sharing one mcid.
        build([[(False, "0:1"), (False, "0:1")], [(False, "1:1"), (False, "2:1")]],
              [(100.0, 700.0, 0, "a"), (200.0, 680.0, 1, "b"), (300.0, 680.0, 2, "c")]),
        # A cell with several mcids, ordered down then across.
        build([[(False, "0:1,1:1"), (False, "2:1")], [(False, "3:1"), (False, "4:1")]],
              [(100.0, 700.0, 0, "top"), (100.0, 690.0, 1, "bottom"),
               (200.0, 700.0, 2, "b"), (100.0, 680.0, 3, "c"), (200.0, 680.0, 4, "d")]),
        # Rows of differing width.
        build([[(False, "0:1"), (False, "1:1"), (False, "2:1")],
               [(False, "3:1"), (False, "4:1")]],
              grid_items(3, 2)),
        # An item with no mcid at all.
        build(grid(2, 2), [(100.0, 700.0, -1, "x")] + grid_items(2, 2)),
    ]

    for _ in range(random_count):
        cols = rng.randint(1, 4)
        row_count = rng.randint(1, 4)
        skip = {i for i in range(cols * row_count) if rng.random() < 0.3}
        extra = []
        if rng.random() < 0.4:
            for c in range(cols):
                extra.append((100.0 + c * 100, 715.0, 90 + c, f"H{c}"))
        cases.append(build(grid(cols, row_count, header_first=rng.random() < 0.3),
                           grid_items(cols, row_count, skip=skip) + extra))
    return cases



def ligature_cases(random_count):
    """Cases for ligature expansion."""
    rng = random.Random(55_2026)
    arabic = "\u0645\u0631\u062d\u0628\u0627"
    forms = "\ufb50\ufe70\ufdf2\ufefb"

    cases = [
        "",
        "plain text",
        # Every explicit ligature.
        "\ufb00\ufb01\ufb02\ufb03\ufb04\ufb05\ufb06",
        "of\ufb01ce",
        # Invisible characters.
        "a\u00adb", "a\u200bb", "a\ufeffb", "a\u200cb", "a\u200db", "a\u2060b",
        # Typographic spaces, and the non-breaking space that is exempt.
        "a\u2000b\u2009c\u200ad",
        "a\u00a0b",
        # Control characters, stripped; tab, newline and return kept.
        "a\u0000b\u0001c",
        "a\tb\nc\rd",
        # Arabic presentation forms: normalised, then reversed.
        forms,
        forms + " 2024",
        arabic,                      # no forms, so untouched
        forms + arabic,
        "abc " + forms + " def",
        # A ligature inside Arabic, so both paths run.
        forms + "\ufb01",
        # Non-breaking space inside Arabic, which normalisation would fold.
        forms + "\u00a0" + forms,
    ]

    alphabet = list("ab \u00a0\u2000\u200b\ufb01\ufb03\u00ad\t\n") + [
        "\ufb50", "\ufe70", "\u0645", "\u0031", "\u0000"]
    for _ in range(random_count):
        cases.append("".join(rng.choice(alphabet) for _ in range(rng.randint(0, 30))))

    return [c.encode("utf-8").hex() for c in cases]



def glyphname_cases(source):
    """Every name in the reference's table, plus the fallback forms."""
    import re
    entry = re.compile(r'''m\.insert\("([^"]+)"''')
    names = []
    with open(source, encoding="utf-8") as handle:
        for line in handle:
            match = entry.search(line)
            if match:
                names.append(match.group(1))

    # Dot suffixes, both on a known base and on an unknown one.
    names += ["zero.tf", "a.ss01", "hyphen.case", "A.alt", "notaglyph.tf", ".notdef",
              "a.", ".", "..", "A.a.b"]
    # uniXXXX, including the private-use offset Windows Symbol fonts use.
    names += ["uni0041", "uni00E9", "uniF041", "uniF000", "uniF0FF", "uniF100",
              "uni0041FF", "uniZZZZ", "uni041", "uni", "uni0000"]
    # uXXXX through uXXXXXX, where the whole remainder is the number.
    names += ["u0041", "u00E9", "u1F600", "u10FFFF", "u110000", "uZZZZ", "u041",
              "u0041.alt"]
    # Surrogates and other values that are not scalars.
    names += ["uniD800", "uD800", "uniFFFF", "u0000"]
    # Names that resolve through neither path.
    names += ["", "A", "notaglyph", "Uni0041", "U0041"]
    return names



def difference_cases(random_count):
    """Cases for the /Differences array."""
    rng = random.Random(58_2026)

    cases = [
        # Empty, and a single run.
        "",
        "65 /A /B /C",
        # A second number restarts the numbering.
        "65 /A /B 200 /eacute /egrave",
        # Names before any number start at zero.
        "/A /B",
        # A code past a byte is truncated rather than rejected.
        "256 /A",
        "300 /A /B",
        "-1 /A",
        # A name at 255 wraps to zero.
        "255 /A /B",
        # Unresolvable names are left out of the map but still advance.
        "65 /notaglyph /B",
        # The uni and u fallbacks reach through.
        "65 /uni0041 /u00E9 /zero.tf",
        # Raw glyph ids are recorded rather than mapped.
        "65 /gid00053 /gid1 /gidX /gid",
        "65 /gid00053 /A /gid7",
        # Ligature names, which the reference counts but does not act on.
        "65 /fi /fl /ffi",
        # The private Aptos mapping, which is font-scoped.
        "@Aptos 65 /g431",
        "@ABCDEF+Aptos 65 /g431",
        "@aptos 65 /g431",
        "@Helvetica 65 /g431",
        "65 /g431",
        # A stray value that is neither number nor name.
        "65 /A null /B",
        # Repeated codes: the last name wins.
        "65 /A 65 /B",
    ]

    names = ["/A", "/eacute", "/notaglyph", "/gid0012", "/uni0041", "/u00E9", "/zero.tf",
             "/fi", "/g431", "null"]
    fonts = ["", "@Aptos ", "@ABCDEF+Aptos ", "@Helvetica "]
    for _ in range(random_count):
        tokens = [rng.choice(fonts).strip()] if rng.random() < 0.4 else []
        for _ in range(rng.randint(0, 10)):
            if rng.random() < 0.3:
                tokens.append(str(rng.choice([0, 1, 65, 200, 255, 256, 300, -1])))
            else:
                tokens.append(rng.choice(names))
        cases.append(" ".join(t for t in tokens if t))
    return cases



def wrapped_cases(random_count):
    """Cases for the wrapped-bold cluster."""
    rng = random.Random(84_2026)
    lines = []

    # --- starts_with_section_number (the convert.rs one) ---
    for text in ("9.5. Title Here", "9.5 Title Here", "1. Title Here", "1.2.3. Deep Title",
                 "1.2.3.4.5.6. Very Deep", "1.2", "1.2 ", "1.2  Title", "1.2\tTitle",
                 "  9.5. Indented Title", "1.2. 42 numbers", "1.2. (bracket)",
                 "1000.2. Big Group", "999.2. Fine Group", "1.2.a. Mixed",
                 "a.b. Letters", "", "   ", "12.34.56.78. Four Groups",
                 "1..2. Double Dot", ".1.2. Leading Dot"):
        lines.append("N " + text.replace(" ", "~"))

    def spec(page, y, x, size, bold, text, append=False):
        return "{}{},{},{},{},{},{}".format(
            "+" if append else "", page, y, x, size, bold, text.replace(" ", "~"))

    # --- is_body_size_all_bold_line ---
    for size in (9, 9.4, 9.5, 10, 11, 11.9, 12, 14):
        lines.append("A 10 ; " + spec(1, 700, 20, size, 1, "bold line"))
    # Every run must be bold and the same size.
    lines.append("A 10 ; " + spec(1, 700, 20, 10, 1, "bold") + " "
                 + spec(1, 700, 80, 10, 0, "plain", append=True))
    lines.append("A 10 ; " + spec(1, 700, 20, 10, 1, "bold") + " "
                 + spec(1, 700, 80, 10.4, 1, "bigger", append=True))
    lines.append("A 10 ; " + spec(1, 700, 20, 10, 1, "bold") + " "
                 + spec(1, 700, 80, 10.6, 1, "bigger", append=True))
    lines.append("A 10 ; ")

    # --- is_wrapped_same_style_line ---
    for gap in (0, 1, 14, 19, 20, 21, 40):
        lines.append("W 20 ; " + spec(1, 700, 20, 10, 1, "one") + " "
                     + spec(1, 700 - gap, 20, 10, 1, "two"))
    for dx in (0, 20, 39, 40, 41, 100):
        lines.append("W 20 ; " + spec(1, 700, 20, 10, 1, "one") + " "
                     + spec(1, 690, 20 + dx, 10, 1, "two"))
    # Across a page boundary.
    lines.append("W 20 ; " + spec(1, 700, 20, 10, 1, "one") + " "
                 + spec(2, 690, 20, 10, 1, "two"))
    # Upward gaps are not wraps.
    lines.append("W 20 ; " + spec(1, 690, 20, 10, 1, "one") + " "
                 + spec(1, 700, 20, 10, 1, "two"))

    # --- find_wrapped_bold_paragraph_lines ---
    long_words = "a bold paragraph line carrying quite a few words indeed"
    def run(count, words=long_words, size=10, bold=1, gap=14):
        return " ".join(spec(1, 700 - index * gap, 20, size, bold, words)
                        for index in range(count))
    for count in (1, 2, 3, 4, 8):
        lines.append("F 10 20 ; " + run(count))
    # Word count either side of twenty.
    for words in ("one two three four five six seven",
                  "one two three four five six seven eight",
                  "one two"):
        lines.append("F 10 20 ; " + run(3, words=words))
    # A gap too large breaks the run.
    for gap in (14, 20, 21, 30):
        lines.append("F 10 20 ; " + run(4, gap=gap))
    # Not bold, or not body size.
    lines.append("F 10 20 ; " + run(4, bold=0))
    lines.append("F 10 20 ; " + run(4, size=14))
    # Two separate runs on one page.
    lines.append("F 10 20 ; " + run(3) + " "
                 + spec(1, 500, 20, 10, 0, "plain break") + " "
                 + " ".join(spec(1, 400 - i * 14, 20, 10, 1, long_words) for i in range(3)))
    lines.append("F 10 20 ; ")

    # --- struct_role_heading_level ---
    for role in ("H", "H1", "H2", "H3", "H4", "H5", "H6", "H7", "P", "Div",
                 "Table", "Figure", "Unknown", ""):
        lines.append("R " + role)

    # --- merge_wrapped_bold_heading_groups ---
    short = "A Short Bold Heading"
    def brun(count, words=short, size=10, bold=1, gap=14, x=20, y0=700, page=1):
        return " ".join(spec(page, y0 - index * gap, x, size, bold, words)
                        for index in range(count))
    # Run length: only two or three lines merge.
    for count in (1, 2, 3, 4):
        lines.append("M 10 20 ; " + brun(count))
    # Word count either side of fifteen, over two lines.
    for words in ("one two three four five six seven",
                  "one two three four five six seven eight",
                  "one two three four five six seven eight nine"):
        lines.append("M 10 20 ; " + brun(2, words=words))
    # A neighbour inside the threshold breaks the isolation, above or below.
    for y in (760, 721, 720, 714, 713, 672, 671, 666, 665, 600):
        lines.append("M 10 20 ; " + brun(2) + " " + spec(1, y, 20, 10, 0, "plain neighbour"))
    # ...but only when it overlaps in x. The group spans 20..60.
    for x in (0, 19, 20, 55, 60, 61, 200):
        lines.append("M 10 20 ; " + brun(2) + " " + spec(1, 714, x, 10, 0, "plain"))
    # A neighbour on another page never blocks.
    lines.append("M 10 20 ; " + brun(2) + " " + spec(2, 714, 20, 10, 0, "plain"))
    # A section number merges even when the isolation fails.
    lines.append("M 10 20 ; " + brun(2, words="9.5. Numbered Heading") + " "
                 + spec(1, 714, 20, 10, 0, "plain neighbour"))
    lines.append("M 10 20 ; " + brun(2, words="1. Numbered Heading") + " "
                 + spec(1, 714, 20, 10, 0, "plain neighbour"))
    # A long numbered run is still too long to merge.
    lines.append("M 10 20 ; " + brun(4, words="9.5. Numbered Heading"))
    # Non-bold and off-size lines pass straight through.
    lines.append("M 10 20 ; " + brun(2, bold=0))
    lines.append("M 10 20 ; " + brun(2, size=14))
    # Two groups on one page, and a group between ordinary lines.
    lines.append("M 10 20 ; " + spec(1, 800, 20, 10, 0, "plain top") + " "
                 + brun(2, y0=700) + " " + spec(1, 500, 20, 10, 0, "plain middle") + " "
                 + brun(2, y0=400))
    lines.append("M 10 20 ; ")

    # --- count_table_columns ---
    for table in ("|~a~|~b~|^|~---~|~---~|^|~1~|~2~|",
                  "|~a~|^|~---~|",
                  "|~a~|~b~|~c~|^|~---~|~---~|~---~|",
                  "|~a~|~b~|^|~x~|~y~|",
                  "|~a~|~b~|",
                  "",
                  "^|~---~|~---~|",
                  "|~a~|~b~|^---",
                  "|~a~|~b~|^|~---~|~---~|~---~|",
                  "|~a~|~b~|^~---~",
                  "|~a~|~b~|^|---|"):
        lines.append("C " + table)

    return lines


def complexity_cases(random_count):
    """Cases for layout complexity and the band filters."""
    rng = random.Random(93_2026)
    lines = []

    # --- filter_rects_to_band: band 100..300, so 200 wide ---
    rects = []
    for x, w in ((50, 20), (95, 20), (99, 20), (100, 20), (290, 20), (300, 20),
                 (310, 20), (0, 400), (0, 200), (50, 200), (90, 200), (150, 100),
                 (100, 140), (100, 139), (0, 141), (200, -50), (350, -100)):
        rects.append("{},10,{},10".format(x, w))
    lines.append("R 100 300 ; " + " ".join(rects))
    lines.append("R 100 300 ; ")
    # A zero-width band, where every proportional test divides by zero.
    lines.append("R 100 100 ; " + " ".join(rects))

    # --- filter_lines_to_band ---
    segs = []
    for x1, x2 in ((50, 90), (50, 100), (50, 101), (100, 200), (299, 400),
                   (300, 400), (301, 400), (400, 50), (150, 150)):
        segs.append("{},10,{},20".format(x1, x2))
    lines.append("S 100 300 ; " + " ".join(segs))
    lines.append("S 100 300 ; ")

    # --- compute_layout_complexity ---
    def grid(page, rows, cols, x0=50, y0=700, dx=90, dy=20, text="cell~%d%d"):
        return [
            "{},{},{},10,{}".format(page, x0 + c * dx, y0 - r * dy,
                                    (text % (r, c)) if "%" in text else text)
            for r in range(rows) for c in range(cols)
        ]

    def prose(page, rows, x0=50, y0=700):
        return ["{},{},{},10,a~line~of~ordinary~running~prose~here~%d".format(
            page, x0, y0 - r * 14) % r for r in range(rows)]

    # Plain prose: neither tables nor columns.
    lines.append("C ; " + " ".join(prose(1, 10)))
    # A grid that should read as a table.
    lines.append("C ; " + " ".join(grid(1, 6, 4)))
    # Two columns of prose far apart.
    two = prose(1, 12) + prose(1, 12, x0=400)
    lines.append("C ; " + " ".join(two))
    # A table on page two only.
    lines.append("C ; " + " ".join(prose(1, 10) + grid(2, 6, 4)))
    # Several pages, mixed.
    lines.append("C ; " + " ".join(prose(1, 10) + grid(2, 6, 4) + prose(3, 12)
                                   + prose(3, 12, x0=400)))
    # Side-by-side bands, each with its own small grid.
    side = grid(1, 5, 2, x0=40, dx=60) + grid(1, 5, 2, x0=400, dx=60)
    lines.append("C ; " + " ".join(side))
    # Too few items for any detector.
    lines.append("C ; " + " ".join(grid(1, 2, 2)))
    lines.append("C ; ")

    # Random pages.
    for _ in range(random_count):
        items = []
        for page in range(1, rng.randint(2, 4)):
            shape = rng.choice(["prose", "grid", "two"])
            if shape == "prose":
                items += prose(page, rng.randint(3, 12))
            elif shape == "grid":
                items += grid(page, rng.randint(3, 7), rng.randint(2, 5))
            else:
                items += prose(page, 10) + prose(page, 10, x0=rng.choice([350, 400, 450]))
        lines.append("C ; " + " ".join(items))

    return lines


def writer_cases(random_count):
    """Cases for the whole line-to-Markdown conversion."""
    rng = random.Random(91_2026)
    lines = []

    def spec(page, y, x, size, bold, italic, font, text, append=False):
        return "{}{},{},{},{},{},{},{},{}".format(
            "+" if append else "", page, y, x, size, bold, italic, font,
            text.replace(" ", "~") or "x")

    def case(items, flags="d", base="-", roles="!", tables="-", images="-", bands="-"):
        return "W {} {} {} {} {} {} ; ".format(
            flags, base, roles, tables, images, bands) + " ".join(items)

    def prose(page, y, text, size=10, bold=0, italic=0, x=20, font="F1"):
        return spec(page, y, x, size, bold, italic, font, text)

    body = [prose(1, 700 - r * 14, "body line %d of ordinary running prose here" % r)
            for r in range(6)]

    # The plainest possible document, then one with a title.
    lines.append(case(body))
    lines.append(case([prose(1, 760, "Document Title Here", size=20)] + body))
    # A paragraph break from a large gap, and a backward jump.
    lines.append(case([prose(1, 700, "first paragraph line here"),
                       prose(1, 600, "second paragraph line here")]))
    lines.append(case([prose(1, 600, "first paragraph line here"),
                       prose(1, 700, "second paragraph line here")]))
    # Emphasis on and off.
    for flags in ("d", "1110001110", "1111111110"):
        lines.append(case([prose(1, 700, "bold words here", bold=1),
                           prose(1, 686, "italic words here", italic=1)], flags=flags))
    # Lists: a marker, a continuation, and a line that ends the list.
    lines.append(case([prose(1, 700, "- first bullet item"),
                       prose(1, 686, "continues the bullet here", x=24),
                       prose(1, 600, "a separate paragraph now")]))
    lines.append(case([prose(1, 700, "1. numbered item here"),
                       prose(1, 686, "2. second numbered item")]))
    # A dot-leader row, which must not run together with its neighbour.
    lines.append(case([prose(1, 700, "Chapter One .......... 5"),
                       prose(1, 686, "Chapter Two .......... 9")]))
    # Captions.
    lines.append(case([prose(1, 700, "Figure 1: a caption line"),
                       prose(1, 686, "body text following the caption")]))
    # Code, by monospace font, opened and closed.
    lines.append(case([prose(1, 700, "let x = 1", font="Courier"),
                       prose(1, 686, "let y = 2", font="Courier"),
                       prose(1, 600, "ordinary prose after the code")]))
    # A code block still open at a page break.
    lines.append(case([prose(1, 700, "let x = 1", font="Courier"),
                       prose(2, 700, "ordinary prose on the next page")]))
    # Page numbering markers.
    lines.append(case([prose(1, 700, "page one text here"),
                       prose(2, 700, "page two text here")], flags="1111111110"))
    lines.append(case([prose(1, 700, "page one text here"),
                       prose(2, 700, "page two text here")]))
    # Struct roles: heading, caption, list item, quote, code.
    for role in ("H1", "H2", "Caption", "LI", "BlockQuote", "Code", "P", "Figure"):
        lines.append(case([prose(1, 760, "A Tagged Line Of Text"), ] + body,
                          roles="0:" + role))
    # A tagged non-heading role must not be promoted by the heuristic.
    lines.append(case([prose(1, 760, "SHORT BOLD LINE", size=10, bold=1)] + body,
                      roles="0:LI"))
    lines.append(case([prose(1, 760, "SHORT BOLD LINE", size=10, bold=1)] + body))
    # Tables and images interleaved.
    lines.append(case(body, tables="1:650:20:|~a~|~b~|^|~---~|~---~|"))
    lines.append(case(body, images="1:650:20:![Image](image)"))
    lines.append(case(body, tables="1:650:20:|~a~|~b~|^|~---~|~---~|",
                      images="1:640:20:![Image](image)"))
    # A table-only page after the last text line.
    lines.append(case(body, tables="3:650:20:|~a~|~b~|^|~---~|~---~|"))
    # A band-split page.
    lines.append(case([prose(1, 700, "left band line here", x=20),
                       prose(1, 700, "right band line here", x=300)], bands="1"))
    lines.append(case([prose(1, 700, "left band line here", x=20),
                       prose(1, 700, "right band line here", x=300)]))
    # A base size override.
    lines.append(case(body, base="14"))
    # A wrapped bold paragraph followed by ordinary prose.
    bold_run = [prose(1, 760 - i * 14,
                      "a bold paragraph line carrying quite a few words indeed", bold=1)
                for i in range(3)]
    lines.append(case(bold_run + [prose(1, 760 - 3 * 14 - 13, "ordinary prose follows")]))
    # A table-of-contents marker heading, suppressing headings on its page.
    lines.append(case([prose(1, 760, "Table of Contents", size=20),
                       prose(1, 700, "Chapter One .......... 5"),
                       prose(1, 686, "ANOTHER BOLD LINE", bold=1)]))
    lines.append(case([]))

    # --- to_markdown_from_lines: the same documents through the plain
    # entry point, which is a separate implementation ---
    simple = [c for c in lines if c.startswith("W ")]
    lines.extend("L" + c[1:] for c in simple)

    # Cases aimed at where the two implementations disagree.
    # Two monospace lines: one fenced block in the big writer, two here.
    both = [prose(1, 700, "let x = 1", font="Courier"),
            prose(1, 686, "let y = 2", font="Courier")]
    lines.append(case(both))
    lines.append("L" + case(both)[1:])
    # A list open across a page break, which the plain writer closes.
    across = [prose(1, 700, "- a bullet item here"),
              prose(2, 700, "continuation on the next page", x=24)]
    lines.append(case(across))
    lines.append("L" + case(across)[1:])
    # A bullet-marker line at heading size: the big writer's gate rejects it,
    # the plain one has no bullet test.
    bullet = [prose(1, 760, "- A Bulleted Heading Line", size=20)] + body
    lines.append(case(bullet))
    lines.append("L" + case(bullet)[1:])
    # A single bold word, standalone but not isolated.
    word = [prose(1, 760, "CONTENTS", bold=1)] + body
    lines.append(case(word))
    lines.append("L" + case(word)[1:])
    # A wrapped bold heading, which only the big writer merges.
    wrapped = [prose(1, 760, "A Short Bold Heading", bold=1),
               prose(1, 746, "continuing here", bold=1)] + body
    lines.append(case(wrapped))
    lines.append("L" + case(wrapped)[1:])

    # Random small documents.
    texts = ["Acknowledgements", "a line of ordinary running prose that continues",
             "- a bullet item here", "Figure 1: a caption", "1. numbered item",
             "SHORT BOLD", "Chapter One .......... 5"]
    for _ in range(random_count):
        count = rng.randint(1, 8)
        items = []
        y = 800
        for _ in range(count):
            y -= rng.choice([14, 20, 60, 120])
            items.append(prose(rng.choice([1, 1, 2]), y, rng.choice(texts),
                               size=rng.choice([10, 12, 20]),
                               bold=rng.choice([0, 1]),
                               x=rng.choice([20, 24, 60]),
                               font=rng.choice(["F1", "F1", "Courier"])))
        lines.append(case(items))
        lines.append("L" + case(items)[1:])

    return lines


def prologue_cases(random_count):
    """Cases for the analysis prologue."""
    rng = random.Random(90_2026)
    lines = []

    def spec(page, y, x, size, bold, mcid, text, append=False):
        return "{}{},{},{},{},{},{},{}".format(
            "+" if append else "", page, y, x, size, bold, mcid,
            text.replace(" ", "~") or "x")

    def case(items, base="-", roles="!", charts="-"):
        return "P {} {} {} ; ".format(base, roles, charts) + " ".join(items)

    body = [spec(1, 700 - r * 20, 20, 10, 0, "-",
                 "body line %d of ordinary running prose here" % r)
            for r in range(8)]

    # A plain document, and one with the base size forced.
    lines.append(case(body))
    lines.append(case(body, base="14"))
    lines.append(case(body, base="0"))
    # A title above body text, at each of several sizes.
    for size in (10, 12, 14, 20, 24):
        lines.append(case([spec(1, 760, 20, size, 0, "-", "Document Title Here")] + body))
    # A wrapped title, which the heading merge should join.
    lines.append(case([spec(1, 780, 20, 20, 0, "-", "About Glenair the"),
                       spec(1, 760, 20, 20, 0, "-", "Interconnect Company")] + body))
    # A drop cap, which is merged before the tiers are computed — so it must
    # not create a tier of its own.
    lines.append(case([spec(1, 760, 20, 10, 0, "-", "Chapter One"),
                       spec(1, 740, 20, 10, 0, "-", "nce upon a time there was"),
                       spec(1, 730, 10, 30, 0, "-", "O")] + body))
    # A short bold run that merges, and a long one that is suppressed.
    short_bold = [spec(1, 760 - i * 14, 20, 10, 1, "-", "A Short Bold Heading")
                  for i in range(2)]
    long_bold = [spec(1, 760 - i * 14, 20, 10, 1, "-",
                      "a bold paragraph line carrying quite a few words indeed")
                 for i in range(3)]
    lines.append(case(short_bold + body))
    lines.append(case(long_bold + body))
    # An isolated body-size line between paragraphs.
    lines.append(case(body[:3]
                      + [spec(1, 700 - 3 * 20 - 60, 20, 10, 0, "-", "Acknowledgements")]
                      + [spec(1, 700 - 4 * 20 - 120, 20, 10, 0, "-",
                              "body line %d of ordinary running prose here" % r)
                         for r in range(4, 8)]))
    # Struct roles: a tagged heading, and a tagged non-heading that is
    # excluded from the sequence pass.
    lines.append(case([spec(1, 760, 20, 10, 0, 5, "Tagged Heading Line")] + body,
                      roles="1:5:H2"))
    lines.append(case([spec(1, 760, 20, 10, 0, 5, "Tagged Caption Line")] + body,
                      roles="1:5:Caption"))
    # Enough tagged lines to trip the overuse audit.
    many = [spec(1, 760 - i * 20, 20, 10, 0, i, "tagged line %d of the document" % i)
            for i in range(30)]
    lines.append(case(many, roles=",".join("1:%d:H2" % i for i in range(30))))
    lines.append(case(many, roles=",".join("1:%d:P" % i for i in range(30))))
    # A chart region, whose lines are excluded from the sequence pass.
    lines.append(case([spec(1, 500, 300, 10, 0, "-", "Chart Label Text Here")] + body,
                      charts="1:280:480:600:520"))
    # Several pages.
    multi = []
    for page in range(1, 4):
        multi.append(spec(page, 780, 20, 18, 0, "-", "Section %d Heading" % page))
        for r in range(6):
            multi.append(spec(page, 700 - r * 20, 20, 10, 0, "-",
                              "body line %d on page %d of prose" % (r, page)))
    lines.append(case(multi))
    lines.append(case([]))

    # Random documents, to shake the interactions between the stages.
    texts = ["Acknowledgements", "Section Heading Here", "1.2 Numbered Section",
             "a line of ordinary running prose that continues",
             "Figure 1: a caption line", "short", "A Short Bold Heading"]
    for _ in range(random_count):
        count = rng.randint(1, 12)
        items = []
        y = 800
        for _ in range(count):
            y -= rng.choice([14, 20, 40, 80])
            items.append(spec(rng.choice([1, 1, 2]), y, rng.choice([20, 40]),
                              rng.choice([10, 12, 14, 20]), rng.choice([0, 1]), "-",
                              rng.choice(texts)))
        lines.append(case(items))

    return lines


def preprocess_cases(random_count):
    """Cases for the preprocess merge pair and comparison helpers."""
    rng = random.Random(88_2026)
    lines = []

    def spec(page, y, x, size, bold, mcid, text, append=False):
        return "{}{},{},{},{},{},{},{}".format(
            "+" if append else "", page, y, x, size, bold, mcid,
            text.replace(" ", "~") or "x")

    tiers = "14 12"

    # --- effective_heading_level ---
    # A struct role outranks the font heuristic, including when the role says
    # a *different* level than the size would.
    for role, size in (("H1", 10), ("H2", 20), ("H", 10), ("P", 20), ("Figure", 20)):
        lines.append("E 10 1:5:{} {} ; ".format(role, tiers)
                     + spec(1, 700, 20, size, 0, 5, "Heading"))
    # No roles at all, and roles that do not cover this line.
    for size in (10, 12, 14, 20, 9):
        lines.append("E 10 ! {} ; ".format(tiers) + spec(1, 700, 20, size, 0, "-", "Heading"))
    # An untagged item is skipped and a later tagged one still answers.
    lines.append("E 10 1:6:H3 {} ; ".format(tiers)
                 + spec(1, 700, 20, 10, 0, "-", "one") + " "
                 + spec(1, 700, 60, 10, 0, 6, "two", append=True))
    # A line with no items reads the base size.
    lines.append("E 10 ! {} ; ".format(tiers))
    # Boldness feeds the fallback, so a bold body-size line can reach a tier.
    for bold in (0, 1):
        lines.append("E 10 ! {} ; ".format(tiers)
                     + spec(1, 700, 20, 10.6, bold, "-", "Bold Heading"))

    # --- merge_heading_lines ---
    def hcase(items, base=10, roles="!"):
        return "H {} {} {} ; ".format(base, roles, tiers) + " ".join(items)

    # Two heading fragments at one tier, at gaps either side of 2x the font.
    for gap in (10, 27, 28, 29, 40):
        lines.append(hcase([spec(1, 700, 20, 14, 0, "-", "About Glenair the"),
                            spec(1, 700 - gap, 20, 14, 0, "-", "Interconnect Company")]))
    # Upward and zero gaps never merge.
    lines.append(hcase([spec(1, 700, 20, 14, 0, "-", "About Glenair"),
                        spec(1, 700, 20, 14, 0, "-", "Interconnect")]))
    lines.append(hcase([spec(1, 700, 20, 14, 0, "-", "About Glenair"),
                        spec(1, 710, 20, 14, 0, "-", "Interconnect")]))
    # Different pages, and different levels.
    lines.append(hcase([spec(1, 700, 20, 14, 0, "-", "About Glenair"),
                        spec(2, 690, 20, 14, 0, "-", "Interconnect")]))
    lines.append(hcase([spec(1, 700, 20, 14, 0, "-", "About Glenair"),
                        spec(1, 690, 20, 12, 0, "-", "Interconnect")]))
    # The twenty-word ceiling on the combined heading.
    long_words = " ".join("word%d" % i for i in range(11))
    lines.append(hcase([spec(1, 700, 20, 14, 0, "-", long_words),
                        spec(1, 690, 20, 14, 0, "-", "and more here")]))
    for count in (10, 11):
        lines.append(hcase([spec(1, 700, 20, 14, 0, "-", " ".join("w%d" % i for i in range(10))),
                            spec(1, 690, 20, 14, 0, "-",
                                 " ".join("v%d" % i for i in range(count)))]))
    # Three fragments in a row.
    lines.append(hcase([spec(1, 700, 20, 14, 0, "-", "One Two"),
                        spec(1, 690, 20, 14, 0, "-", "Three Four"),
                        spec(1, 680, 20, 14, 0, "-", "Five Six")]))
    # Struct-tagged headings merge on the same rules.
    lines.append("H 10 1:5:H2,1:6:H2 {} ; ".format(tiers)
                 + spec(1, 700, 20, 10, 0, 5, "Tagged Heading") + " "
                 + spec(1, 690, 20, 10, 0, 6, "Continues Here"))

    # The bold-wrap merge: both tier-less, both fully bold, continuation
    # starts lowercase, previous has no terminal punctuation.
    def bold_pair(prev="of wood pellets and cost", curr="structure in Japan",
                  gap=10, size=10, prev_bold=1, curr_bold=1):
        return [spec(1, 700, 20, size, prev_bold, "-", prev),
                spec(1, 700 - gap, 20, size, curr_bold, "-", curr)]
    lines.append(hcase(bold_pair()))
    # Gap either side of 1.6x the font size.
    for gap in (15, 16, 17):
        lines.append(hcase(bold_pair(gap=gap)))
    # An uppercase continuation, and terminal punctuation on the previous.
    lines.append(hcase(bold_pair(curr="Structure in Japan")))
    for tail in (".", ":", ";", "!", "?", ",", ")"):
        lines.append(hcase(bold_pair(prev="of wood pellets and cost" + tail)))
    # Either line not fully bold.
    lines.append(hcase(bold_pair(prev_bold=0)))
    lines.append(hcase(bold_pair(curr_bold=0)))
    # A mixed-bold previous line.
    lines.append(hcase([spec(1, 700, 20, 10, 1, "-", "of wood pellets") + " "
                        + spec(1, 700, 90, 10, 0, "-", "and cost", append=True),
                        spec(1, 690, 20, 10, 1, "-", "structure in Japan")]))
    # A tiered line must not absorb bold body text. At the same size both
    # reach a tier and the ordinary same-level path merges them instead, so
    # only the mixed pair isolates the tier-less requirement.
    lines.append(hcase([spec(1, 700, 20, 14, 1, "-", "A Real Heading"),
                        spec(1, 690, 20, 10, 1, "-", "continues lowercase")]))
    lines.append(hcase([spec(1, 700, 20, 14, 1, "-", "A Real Heading"),
                        spec(1, 690, 20, 14, 1, "-", "continues lowercase")]))
    lines.append(hcase([]))

    # --- merge_drop_caps ---
    def dcase(items, base=10):
        return "D {} ; ".format(base) + " ".join(items)

    # The classic shape: a huge capital emitted after the paragraph it opens.
    body = [spec(1, 700, 20, 10, 0, "-", "Chapter One"),
            spec(1, 690, 20, 10, 0, "-", "nce upon a time there"),
            spec(1, 680, 20, 10, 0, "-", "was a document")]
    lines.append(dcase(body + [spec(1, 690, 10, 30, 0, "-", "O")]))
    # Size either side of 2.5x the base.
    for size in (24, 25, 26, 30):
        lines.append(dcase(body + [spec(1, 690, 10, size, 0, "-", "O")]))
    # Two characters is still a drop cap; three is not.
    for text in ("O", "O~", "Oh", "Ohh", "o", "1", "É"):
        lines.append(dcase(body + [spec(1, 690, 10, 30, 0, "-", text)]))
    # No lowercase-starting line to attach to, and a drop cap on another page.
    lines.append(dcase([spec(1, 700, 20, 10, 0, "-", "Chapter One"),
                        spec(1, 690, 10, 30, 0, "-", "O")]))
    lines.append(dcase(body + [spec(2, 690, 10, 30, 0, "-", "O")]))
    # The first lowercase line wins, and only if it opens a paragraph.
    lines.append(dcase([spec(1, 700, 20, 10, 0, "-", "already lowercase here"),
                        spec(1, 690, 20, 10, 0, "-", "and continues lowercase"),
                        spec(1, 680, 10, 30, 0, "-", "O")]))
    lines.append(dcase([]))

    # --- normalize_for_comparison / is_structural_line / is_decorative_separator ---
    for text in ("Chapter 3 — Page 5", "  spaced   out  text ", "123 leading",
                 "trailing 456", "42", "   ", "", "1a2", "9 Chapter 9",
                 "Page~5~of~10"):
        lines.append("N " + text.replace(" ", "~"))
    for text in ("# Heading", "- bullet", "* star", "• dot", "1. numbered",
                 "2) paren", "1.no space", "12 plain", "a. letter", "  # indented",
                 "plain text", "", "3", "1. "):
        lines.append("S " + text.replace(" ", "~"))
    for text in ("----------", "**********", "=", "", "-a-", "aaa", "ab",
                 "~~~~", "  "):
        lines.append("X " + text.replace(" ", "~"))

    # --- strip_repeated_lines ---
    HEADER = "Annual Report of the Commission"
    FOOTER = "Confidential Working Draft"

    def doc(pages, body_rows=12, header=HEADER, footer=FOOTER,
            header_y=800, footer_y=40, skip_header=(), skip_footer=(),
            header_drift=0, page_count=None):
        """A document of `pages` pages, each with a header, a footer and
        `body_rows` rows of ordinary prose well away from the margins."""
        specs = []
        for page in range(1, pages + 1):
            if header and page not in skip_header:
                y = header_y + (header_drift if page % 2 == 0 else 0)
                specs.append("{},{},{}".format(page, y, header.replace(" ", "~")))
            for row in range(body_rows):
                specs.append("{},{},{}".format(
                    page, 700 - row * 40,
                    ("body line %d on page %d with plenty of text" % (row, page))
                    .replace(" ", "~")))
            if footer and page not in skip_footer:
                specs.append("{},{},{}".format(page, footer_y, footer.replace(" ", "~")))
        return "R {} ; ".format(page_count if page_count is not None else pages) + " ".join(specs)

    # The page-count floor: under three pages nothing is stripped at all.
    for pages in (2, 3, 4, 6):
        lines.append(doc(pages))
    # The threshold is max(3, 30% of pages) using integer division, so a
    # header on exactly that many pages is stripped and one fewer is not.
    for pages, present in ((10, 3), (10, 2), (20, 6), (20, 5)):
        skip = tuple(range(present + 1, pages + 1))
        lines.append(doc(pages, skip_header=skip, footer=None))
    # A drifting header fails the Y-consistency test; a steady one passes.
    for drift in (0, 2, 20, 100):
        lines.append(doc(6, header_drift=drift, footer=None))
    # Short and decorative texts are never candidates.
    for header in ("Page 1", "---------------", "aaaaaaaaaaaaaaa", "Report 2024"):
        lines.append(doc(6, header=header, footer=None))
    # A structural-looking header is exempt.
    for header in ("# Annual Report Heading", "1. Annual Report Section",
                   "- Annual Report Bullet"):
        lines.append(doc(6, header=header, footer=None))
    # A header in the middle of the page is not at an edge.
    lines.append(doc(6, header_y=500, footer=None))
    # Sparse pages: with ten or fewer distinct Y values everything counts as
    # an edge, so a mid-page repeat is stripped after all.
    lines.append(doc(6, body_rows=4, header_y=500, footer=None))
    lines.append(doc(6, body_rows=12, header_y=500, footer=None))
    # A page_count larger than the pages actually present raises the bar.
    lines.append(doc(6, footer=None, page_count=30))

    # Y-band coalescing: two fragments at one Y, each too short alone.
    def banded(pages, left="Column One", right="Column Two", y=800):
        specs = []
        for page in range(1, pages + 1):
            specs.append("{},{},{}".format(page, y, left.replace(" ", "~")))
            specs.append("{},{},{}".format(page, y, right.replace(" ", "~")))
            for row in range(12):
                specs.append("{},{},{}".format(
                    page, 700 - row * 40,
                    ("body line %d on page %d with plenty of text" % (row, page))
                    .replace(" ", "~")))
        return "R {} ; ".format(pages) + " ".join(specs)

    lines.append(banded(6))
    # One fragment long enough on its own, so sibling propagation takes the
    # other with it.
    lines.append(banded(6, left="A Very Long Column Header Indeed", right="x"))
    lines.append(banded(6, y=500))

    # Lines given out of page order, which the individual first-occurrence
    # pass reads in array order rather than by page number.
    shuffled = []
    for page in (3, 1, 2, 4, 5, 6):
        shuffled.append("{},800,{}".format(page, HEADER.replace(" ", "~")))
        for row in range(12):
            shuffled.append("{},{},{}".format(
                page, 700 - row * 40,
                ("body line %d on page %d with plenty of text" % (row, page))
                .replace(" ", "~")))
    lines.append("R 6 ; " + " ".join(shuffled))
    lines.append("R 6 ; ")

    return lines


def positioned_cases(random_count):
    """Cases for the positioned-block cluster."""
    rng = random.Random(87_2026)
    lines = []
    # A chart band spanning y 300..400, prose split at x 300. The pad is 8,
    # so the zone runs 292..408.
    order = "300:0:300:600:400"

    # --- chart_stream_position ---
    for y in (500, 409, 408, 400, 350, 300, 292, 291, 200):
        for x in (0, 299, 300, 301, 600):
            lines.append("Z {} {} 0 {}".format(y, x, order))
    # Claimed by the chart overrides the geometry entirely.
    for y in (500, 200):
        for x in (0, 600):
            lines.append("Z {} {} 1 {}".format(y, x, order))
    # A band given upside down: the min/max normalise it.
    lines.append("Z 350 0 0 300:0:400:600:300")

    # --- positioned_block_precedes_line ---
    # Without a chart order the comparison is bare y.
    for by, ly in ((700, 600), (600, 700), (700, 700)):
        lines.append("P {} 20 - ; {} 20".format(by, ly))
    # With one, the stream position leads and y only breaks ties.
    for by, bx, ly, lx in ((500, 20, 200, 20), (200, 20, 500, 20),
                           (500, 400, 500, 20), (500, 20, 500, 400),
                           (350, 20, 500, 20), (500, 20, 350, 20),
                           (700, 20, 700, 20), (700, 20, 701, 20)):
        lines.append("P {} {} {} ; {} {}".format(by, bx, order, ly, lx))
    # A line with an item inside the chart region is claimed by it, which
    # moves the whole line into the chart zone whatever its own y says.
    lines.append("P 500 20 {} ; 200 20 350".format(order))
    lines.append("P 500 20 {} ; 200 20 700".format(order))
    # A line with no items at all reads x as zero.
    lines.append("P 500 400 {} ; 500".format(order))

    # --- positioned_blocks_for_page ---
    # Ordinary pages keep the legacy order: tables first, then images, each
    # in input order, whatever the geometry says.
    lines.append("S ; T:100:20:- T:700:20:- I:400:20:- I:900:20:-")
    lines.append("S ; I:900:20:- T:100:20:-")
    # A chart page orders by stream position, then descending y, then x.
    lines.append("S ; T:200:20:{o} T:500:20:{o} I:350:20:{o}".format(o=order))
    lines.append("S ; T:500:400:{o} T:500:20:{o}".format(o=order))
    # One block without a chart order drops the whole comparison back to the
    # legacy branch.
    lines.append("S ; T:200:20:{o} I:500:20:-".format(o=order))
    lines.append("S ; ")

    # Random blocks, to shake the tie-breaks.
    for _ in range(random_count):
        count = rng.randint(1, 6)
        specs = []
        for _ in range(count):
            kind = rng.choice(["T", "I"])
            y = rng.choice([150, 200, 350, 400, 500, 700])
            x = rng.choice([20, 299, 300, 400])
            specs.append("{}:{}:{}:{}".format(kind, y, x, order))
        lines.append("S ; " + " ".join(specs))

    return lines


def isolated_cases(random_count):
    """Cases for the isolation cluster: struct roles and isolated lines."""
    rng = random.Random(85_2026)
    lines = []

    def spec(page, y, x, size, mcid, text, append=False):
        return "{}{},{},{},{},{},{}".format(
            "+" if append else "", page, y, x, size, mcid,
            text.replace(" ", "~") or "x")

    # --- resolve_line_struct_role ---
    containers = ("Document", "Part", "Art", "Sect", "Div", "NonStruct", "Span",
                  "Private")
    for name in containers + ("P", "H1", "H", "TD", "Figure", "Unknown"):
        lines.append("S 1:5:{} ; ".format(name) + spec(1, 700, 20, 10, 5, "text"))
    # A container on the first item does not stop the search.
    lines.append("S 1:5:Div,1:6:H2 ; " + spec(1, 700, 20, 10, 5, "one") + " "
                 + spec(1, 700, 60, 10, 6, "two", append=True))
    # ...and an untagged item is skipped without ending it either.
    lines.append("S 1:6:H3 ; " + spec(1, 700, 20, 10, "-", "one") + " "
                 + spec(1, 700, 60, 10, 6, "two", append=True))
    # Every item a container.
    lines.append("S 1:5:Div,1:6:Span ; " + spec(1, 700, 20, 10, 5, "one") + " "
                 + spec(1, 700, 60, 10, 6, "two", append=True))
    # The page has no entry at all; the mcid is not on the page it is on.
    lines.append("S 2:5:H1 ; " + spec(1, 700, 20, 10, 5, "text"))
    lines.append("S 1:9:H1 ; " + spec(1, 700, 20, 10, 5, "text"))
    lines.append("S . ; " + spec(1, 700, 20, 10, 5, "text"))
    # Order is item order, not mcid order.
    lines.append("S 1:5:H1,1:6:H2 ; " + spec(1, 700, 60, 10, 6, "two") + " "
                 + spec(1, 700, 20, 10, 5, "one", append=True))

    # --- detect_overused_struct_heading_levels ---
    def tagged(count, role, start=0, page=1):
        return " ".join(spec(page, 700 - index * 30, 20, 10, start + index, "word")
                        for index in range(count))

    def role_map(count, role, start=0, page=1):
        return ",".join("{}:{}:{}".format(page, start + index, role)
                        for index in range(count))

    # No map at all is not the same as an empty one.
    lines.append("O ! ; " + tagged(30, "H2"))
    lines.append("O . ; " + tagged(30, "H2"))
    # The twenty-line floor.
    for count in (5, 19, 20, 21):
        lines.append("O " + role_map(count, "H2") + " ; " + tagged(count, "H2"))
    # Ratio either side of 0.15, with the remainder tagged P so they count
    # toward the total but not toward any level.
    for headings in (2, 3, 4, 5, 6, 7):
        total = 40
        spec_roles = (role_map(headings, "H2")
                      + "," + role_map(total - headings, "P", start=headings))
        lines.append("O " + spec_roles + " ; " + tagged(total, "x"))
    # Two levels, both over.
    lines.append("O " + role_map(10, "H1") + "," + role_map(10, "H2", start=10)
                 + "," + role_map(20, "P", start=20) + " ; " + tagged(40, "x"))
    # Untagged lines do not count toward the total.
    lines.append("O " + role_map(19, "H2") + " ; " + tagged(19, "x") + " "
                 + " ".join(spec(1, 100 - i * 10, 20, 10, "-", "word") for i in range(30)))
    # A generic H folds into level 1 alongside H1.
    lines.append("O " + role_map(4, "H") + "," + role_map(4, "H1", start=4)
                 + "," + role_map(32, "P", start=8) + " ; " + tagged(40, "x"))

    # --- find_isolated_lines ---
    def page_of(specs):
        return "I 10 20 ; " + " ".join(specs)

    def line(y, text, size=10, page=1, x=20):
        return spec(page, y, x, size, "-", text)

    # Word count and byte length at their boundaries. A lone line is isolated
    # on both sides, so only the content gates can reject it.
    for text in ("one", "one two", "one two three four five six",
                 "one two three four five six seven", "abc", "abcd", "ab c",
                 "ééé", "éé", "a b"):
        lines.append(page_of([line(700, text)]))
    # Font size against 95% of the base.
    for size in (9, 9.4, 9.5, 9.6, 10, 20):
        lines.append(page_of([line(700, "Acknowledgements", size=size)]))
    # List items and captions are never isolated headings.
    for text in ("Acknowledgements", "1. Introduction", "- bullet point",
                 "Figure 1: A caption", "Table 2. Results", "B.3 Prompt Engineering"):
        lines.append(page_of([line(700, text)]))
    # Trailing characters that mark wrapped prose.
    for tail in ("-", ",", ";", ".", ":", "?", ")", ""):
        lines.append(page_of([line(700, "Some heading" + tail)]))
    # Continuation words, and the case-folding of them.
    for last in ("the", "The", "THE", "not", "Not", "and", "heading", "thes",
                 "is", "their"):
        lines.append(page_of([line(700, "A short " + last)]))

    # Paragraph breaks either side, at the threshold.
    for gap in (10, 19, 20, 21, 40):
        lines.append(page_of([line(700, "First line here"),
                              line(700 - gap, "Middle Heading"),
                              line(700 - gap * 2, "Third line here")]))
    # A page change stands in for a gap in both directions.
    lines.append(page_of([line(700, "First line here"),
                          line(695, "Middle Heading", page=2),
                          line(690, "Third line here", page=3)]))
    # Upward gaps are absolute, so a line above its predecessor still breaks.
    lines.append(page_of([line(700, "First line here"),
                          line(760, "Middle Heading"),
                          line(600, "Third line here")]))

    # The density guard. Nine isolated lines survive; ten do not.
    def scattered(count, page=1, start=1000):
        return [line(start - index * 100, "Heading Number %s" % index, page=page)
                for index in range(count)]

    def block(count, page=1, start=200):
        return [line(start - index * 5, "block line %s of prose" % index, page=page)
                for index in range(count)]

    for count in (9, 10, 11):
        lines.append(page_of(scattered(count)))
    # Exactly a quarter of the page, and just over.
    lines.append(page_of(scattered(3) + block(9)))
    lines.append(page_of(scattered(4) + block(8)))
    lines.append(page_of(scattered(5) + block(15)))
    # The guard is per page: a dense page loses its isolated lines while a
    # sparse one beside it keeps them.
    lines.append(page_of(scattered(11, page=1)
                         + scattered(2, page=2, start=900)
                         + block(9, page=2, start=300)))
    lines.append(page_of([]))

    # Random pages, to shake the combinations the hand cases fix.
    words = ["Acknowledgements", "Results", "one two three", "B.3 Prompt Engineering",
             "a line of ordinary prose that runs on", "Figure 1: caption",
             "1. list item", "short and", "Method-", "Discussion"]
    for _ in range(random_count):
        count = rng.randint(1, 14)
        specs = []
        y = 800
        for _ in range(count):
            y -= rng.choice([4, 12, 19, 20, 21, 60])
            specs.append(line(y, rng.choice(words), size=rng.choice([9, 9.5, 10, 14]),
                              page=rng.choice([1, 1, 1, 2])))
        lines.append(page_of(specs))

    return lines


def chart_text_cases(random_count):
    """Cases for the small chart-prose predicates."""
    rng = random.Random(82_2026)
    lines = []

    # --- is_cross_row_prose_continuation ---
    previous_texts = ["an open clause", "a sentence.", "a question?", "shout!",
                      "a colon:", "a semicolon;", 'he said."', "quoted'", "bracket)",
                      "square]", '".)]', "", "   ", "trailing~closers.)]",
                      "open~clause)", "MiXeD"]
    current_texts = ["continues here", "Continues Here", "42 then words", "(then words",
                     "", "   ", "\u00e9clair", "\u00c9clair", "1. item"]
    for previous in previous_texts:
        for current in current_texts:
            lines.append("P {}|{}".format(previous.replace(" ", "~"),
                                          current.replace(" ", "~")))

    # --- looks_like_numbered_section_heading ---
    for text in ("1. Introduction To The Topic", "1 Introduction To The Topic",
                 "1.2. Method And Materials", "1.2.3.4. Deep Section Heading Here",
                 "1.2.3.4.5. Too Deep Here Now", "1. Two Words", "1. one two three",
                 "1. Three Words Here", "1000. Big Number Section Here",
                 "999. Fine Number Section Here", "a. Not A Number Section",
                 "1.a. Mixed Prefix Section Here", "1.. Double Dot Section Here",
                 ".1. Leading Dot Section", "1", "", "   ", "1.\tTabbed Section Here",
                 "12.34. Section Heading Here", "1. 42 numbers first here"):
        lines.append("H " + text.replace(" ", "~"))

    # --- chart_spans_prose_split ---
    for region in ("100,0,400,200", "400,0,100,200", "100,0,150,200", "300,0,400,200"):
        for split in (60, 100, 139, 140, 200, 260, 360, 361, 400, 440):
            lines.append("R {} {}".format(region, split))

    # --- merged_retry_skips_body_font ---
    for a in (0, 1):
        for b in (0, 1):
            lines.append("M {} {}".format(a, b))

    for _ in range(random_count // 2):
        previous = "".join(rng.choice(["a", " ", ".", ")", '"', "!", ";", "x"])
                           for _ in range(rng.randrange(0, 8)))
        current = "".join(rng.choice(["a", "A", " ", "1", "(", "z"])
                          for _ in range(rng.randrange(0, 6)))
        lines.append("P {}|{}".format(previous.replace(" ", "~"),
                                      current.replace(" ", "~")))

    return lines


def chart_cases(random_count):
    """Cases for the chart-region trio."""
    rng = random.Random(81_2026)
    lines = []

    def emit(tag, regions, items):
        lines.append("{} {} ; {}".format(
            tag,
            " ".join("{},{},{},{}".format(*r) for r in regions) or "-",
            " ".join("{},{},{},{},{},{}".format(x, y, w, h, sz, t.replace(" ", "~"))
                     for x, y, w, h, sz, t in items)))

    chart = (100.0, 400.0, 400.0, 600.0)

    # A spread of runs around one chart: inside, just outside, far outside.
    around = []
    for y in (620, 610, 601, 600, 500, 400, 399, 390, 380, 379):
        around.append((150, y, 60, 10, 10, "Label"))
    for tag in ("L", "I", "O"):
        emit(tag, [chart], around)

    # The three ways to qualify, isolated.
    #   compact: narrow run, far from the edge but inside the 20pt pad
    for width in (100, 185, 186, 190, 250):
        emit("L", [chart], [(150, 615, width, 10, 10, "A~label~here")])
    #   caption: recognised however wide
    for text in ("Figure~1:~A~caption", "Table~2.~Results", "Plain~words"):
        emit("L", [chart], [(150, 615, 400, 10, 10, text)])
    #   category: mostly inside the width, close to the edge, narrow
    for gap in (0, 5, 18, 19, 20, 21, 30):
        emit("L", [chart], [(150, 600 + gap, 250, 10, 10, "a~much~longer~run~of~label~text")])
    # Overlap fraction, walked across the chart's left edge.
    for x in (0, 40, 60, 80, 100, 150):
        emit("L", [chart], [(x, 605, 100, 10, 10, "a~much~longer~run~of~label~text")])
    # Bullets and list items never qualify.
    for text in ("\u2022", "\u25cf", "-", "*", "1.~item", "\u2022~item", "text"):
        emit("L", [chart], [(150, 605, 60, 10, 10, text)])
    # Type size drives both the compact bar and the category band.
    for size in (4, 6, 8, 10, 14, 20, 40):
        emit("L", [chart], [(150, 608, 120, 0, size, "a~label")])
    # An explicit height above the font size wins.
    for height in (0, 5, 10, 20, 40):
        emit("L", [chart], [(150, 608, 120, height, 10, "a~label")])
    # Negative widths and reversed regions.
    emit("L", [chart], [(300, 605, -100, 10, 10, "backwards")])
    emit("L", [(400.0, 600.0, 100.0, 400.0)], [(150, 605, 60, 10, 10, "reversed~region")])
    emit("I", [(400.0, 600.0, 100.0, 400.0)], [(150, 500, 60, 10, 10, "reversed~region")])

    # Membership: the centre decides horizontally.
    for x in (60, 79, 80, 100, 390, 400, 419, 420, 440):
        emit("I", [chart], [(x, 500, 20, 10, 10, "mid")])
    # Several regions, and none.
    two = [chart, (450.0, 100.0, 700.0, 300.0)]
    spread = [(150, 500, 40, 10, 10, "a"), (500, 200, 40, 10, 10, "b"),
              (800, 700, 40, 10, 10, "c")]
    for tag in ("I", "O"):
        emit(tag, two, spread)
        emit(tag, [], spread)
    emit("O", [chart], [])

    # --- split_side_by_side ---
    def two_tables(rows=12, left_x=40, left_w=120, right_x=340, right_w=120,
                   left_text="Label~text", right_text="Other~text", gap_rows=0):
        out = []
        for row in range(rows):
            y = 700 - row * 14
            for column in range(2):
                out.append((left_x + column * 60, y, left_w // 2, 10, 10, left_text))
                out.append((right_x + column * 60, y, right_w // 2, 10, 10, right_text))
        return out
    emit("B", [], two_tables())
    # The forty-item floor.
    for rows in (8, 9, 10, 11, 20):
        emit("B", [], two_tables(rows=rows))
    # The gap between the tables, walked around 30pt.
    for right_x in (180, 189, 190, 200, 260, 340):
        emit("B", [], two_tables(right_x=right_x))
    # A run crossing the split: allowed up to a twentieth of the page.
    for spanning in (0, 1, 2, 3, 5, 10):
        out = two_tables()
        for index in range(spanning):
            out.append((100, 720 + index * 14, 400, 10, 10, "a~spanning~header~here"))
        emit("B", [], out)
    # Labels on the left and figures on the right at matching baselines:
    # one table, not two.
    emit("B", [], two_tables(right_text="1,234.56"))
    emit("B", [], two_tables(right_text="1,234.56", left_text="99.5"))
    # ... and the same figures at *different* baselines, which is two.
    out = []
    for row in range(12):
        y = 700 - row * 14
        for column in range(2):
            out.append((40 + column * 60, y, 60, 10, 10, "Label~text"))
            out.append((340 + column * 60, y - 7, 60, 10, 10, "1,234.56"))
    emit("B", [], out)
    # Three columns of equal spacing: one wide table, not two regions.
    out = []
    for row in range(14):
        y = 700 - row * 14
        for x in (40, 240, 440):
            out.append((x, y, 60, 10, 10, "Label~text"))
    emit("B", [], out)
    # Everything on one side, so no balanced candidate exists.
    out = []
    for row in range(24):
        y = 700 - row * 14
        out.append((40, y, 60, 10, 10, "Label~text"))
        out.append((100, y, 60, 10, 10, "Label~text"))
    emit("B", [], out)
    emit("B", [], [])

    # --- chart_page_prose_column_split ---
    def two_columns(rows=8, left_x=60, right_x=320, width=200, top=700, step=14,
                    text="a line of running prose text here"):
        out = []
        for row in range(rows):
            y = top - row * step
            out.append((left_x, y, width, 10, 10, text))
            out.append((right_x, y, width, 10, 10, text))
        return out
    emit("S", [], two_columns())
    # Row counts either side of the six-per-column floor.
    for rows in (4, 5, 6, 7, 12):
        emit("S", [], two_columns(rows=rows))
    # Anchor separation, walked around 120pt.
    for right_x in (140, 179, 180, 181, 220, 400):
        emit("S", [], two_columns(right_x=right_x))
    # Vertical span, walked around 60pt.
    for step in (4, 8, 8.5, 9, 14):
        emit("S", [], two_columns(step=step))
    # Vertical overlap: the right column slid down the page.
    for offset in (0, 40, 60, 70, 80, 120):
        out = two_columns()
        out = [r if index % 2 == 0 else (r[0], r[1] - offset, r[2], r[3], r[4], r[5])
               for index, r in enumerate(out)]
        emit("S", [], out)
    # Runs that are not substantial prose cannot form a column.
    for text in ("a line of running prose text here", "one two three", "12 34 56 78",
                 "a b c d"):
        emit("S", [], two_columns(text=text))
    for width in (40, 79, 80, 120, 200):
        emit("S", [], two_columns(width=width))
    # Three columns, and one.
    three = []
    for row in range(8):
        y = 700 - row * 14
        for x in (60, 260, 460):
            three.append((x, y, 150, 10, 10, "a line of running prose text here"))
    emit("S", [], three)
    emit("S", [], [(60, 700 - r * 14, 200, 10, 10, "a line of running prose text here")
                   for r in range(12)])
    emit("S", [], [])
    # Drifting left edges within the 12pt tolerance.
    for drift in (0, 3, 6, 12, 20):
        out = []
        for row in range(8):
            y = 700 - row * 14
            out.append((60 + row * drift, y, 200, 10, 10,
                        "a line of running prose text here"))
            out.append((320 + row * drift, y, 200, 10, 10,
                        "a line of running prose text here"))
        emit("S", [], out)

    for _ in range(random_count):
        regions = [(rng.randrange(0, 400) * 1.0, rng.randrange(0, 400) * 1.0,
                    rng.randrange(0, 700) * 1.0, rng.randrange(0, 700) * 1.0)
                   for _ in range(rng.randrange(0, 3))]
        items = [(rng.randrange(0, 700) * 1.0, rng.randrange(0, 700) * 1.0,
                  rng.choice([-50, 0, 20, 60, 200, 400]) * 1.0,
                  rng.choice([0, 10, 20]) * 1.0, rng.choice([6, 10, 14]) * 1.0,
                  rng.choice(["label", "Figure~1:~x", "\u2022", "a~much~longer~run~here",
                              "1.~item", ""]))
                 for _ in range(rng.randrange(0, 5))]
        emit(rng.choice(["L", "I", "O"]), regions, items)

    return lines


def numbering_cases(random_count):
    """Cases for the section-numbering parser."""
    rng = random.Random(76_2026)
    lines = []

    def emit(tag, text):
        lines.append("{} {}".format(tag, text.replace(" ", "~")))

    # --- roman_value ---
    for token in ("I", "II", "III", "IV", "V", "VI", "IX", "X", "XI", "XIV",
                  "XL", "L", "XC", "C", "CC", "CXLV", "MMXX", "D", "M", "DIX",
                  "", "IIII", "IIIIIIII", "IIIIIIIII", "IIX", "VX", "IC",
                  "i", "iv", "x", "A", "IA", "1", "I1", "IVX", "XXXXXXXX",
                  "XXXXXXXXX", "CCCCCCCC"):
        emit("R", token)

    # --- parse_numbering ---
    for text in ("1. Introduction", "2.1 Method", "2.1. Method", "1) First",
                 "1: First", "1 Introduction", "Introduction", "",
                 "1.. Weird", "1... Weird", "1.2.3. Deep", "1.2.3.4. Deeper",
                 "999. Big", "1000. Too big", "0. Zero", "01. Padded",
                 "I. Roman", "IV. Roman", "iv. lower", "X) Roman",
                 "IX: Roman", "M. Roman", "1.a. Mixed", "a.1. Mixed",
                 ".", "..", ".1.", "1.", ")", ":", "1.2", "  3.  spaced",
                 "12.34.56. deep", "1.2.  gap", "\t4. tabbed"):
        emit("N", text)

    # --- has_additional_decimal_numbering ---
    for text in ("1. Introduction", "1. See section 2.3 for details",
                 "1. Version 1.2.3 released", "2.1 Method", "1. In 2024 we",
                 "1. Figure 2 shows", "1. (2.3)", "1. 2.3,", "1. a.b",
                 "1. 2.", "1. .2", "1. 2..3", "single", "", "1. x2.3y",
                 "1. 2.3.4.5", "1. price 1.50 each"):
        emit("A", text)

    # --- numbering_forms_hierarchy ---
    for pair in ("1|1,1", "1,1|1", "1|2", "1|1", "1,1|1,2", "1,1|1,1,1",
                 "|1", "1|", "|", "1,2,3|1,2", "1,2|1,3", "2|1,1"):
        emit("H", pair)

    # --- classify_heading_sequences ---
    def CH(specs, base=10, excluded=None, tiers=()):
        lines.append("CH {} {} | {} ; {}".format(
            base, ",".join(str(e) for e in excluded) if excluded else "-",
            " ".join(str(t) for t in tiers), " ".join(specs)))

    def body_line(y, x=20, size=10, font="Body"):
        return "1,{},{},{},0,{},a~long~line~of~body~text~here".format(y, x, size, font)

    def head_line(y, text, x=20, size=12, bold=1, font="Head", page=1):
        return "{},{},{},{},{},{},{}".format(page, y, x, size, bold, font, text)

    # A numbered hierarchy, and the ways it fails.
    def hierarchy(gap=4, second="1.1.~Method", size=12, bold=1, font="Head", x=20):
        out = [head_line(760, "1.~Introduction", x=x, size=size, bold=bold, font=font)]
        y = 740
        for _ in range(max(gap - 1, 0)):
            out.append(body_line(y))
            y -= 14
        out.append(head_line(y, second, x=x, size=size, bold=bold, font=font))
        return out
    for gap in (1, 2, 3, 4, 6):
        CH(hierarchy(gap=gap))
    for second in ("1.1.~Method", "2.~Method", "1.1.1.~Deep", "I.~Roman", "Method"):
        CH(hierarchy(second=second))
    # The numbering must be set apart by size or by a distinct bold face.
    for size in (10, 10.4, 10.5, 11, 12):
        CH(hierarchy(size=size))
    for bold, font in ((0, "Head"), (1, "Body"), (0, "Body"), (1, "Head")):
        CH(hierarchy(bold=bold, font=font))
    # A page boundary settles separation whatever the gap.
    CH([head_line(760, "1.~Introduction"),
        head_line(700, "1.1.~Method", page=2)])

    # A displaced sidebar, and each guard walked.
    def sidebar(labels=("Alpha", "Beta", "Gamma"), x=200, size=8, bold=1,
                font="Side", blocks=4, page=1):
        out = []
        y = 700
        label_index = 0
        for _ in range(3):
            for _ in range(blocks):
                out.append(body_line(y))
                y -= 14
            if label_index < len(labels):
                out.append("{},{},{},{},{},{},{}".format(
                    page if label_index else 1, y + 7, x, size, bold, font,
                    labels[label_index]))
                label_index += 1
        return out
    CH(sidebar())
    for x in (20, 60, 100, 116, 140, 200, 400):
        CH(sidebar(x=x))
    for size in (7, 8, 9, 9.4, 9.5, 10, 12):
        CH(sidebar(size=size))
    for labels in (("Alpha", "Beta", "Gamma"), ("Alpha", "Alpha", "Alpha"),
                   ("Alpha", "Alpha", "Beta"), ("Alpha", "Beta"),
                   ("Alpha~with-", "Beta", "Gamma"), ("A~1", "Beta", "Gamma"),
                   ("ends~with~the", "Beta", "Gamma")):
        CH(sidebar(labels=labels))
    for blocks in (1, 2, 3, 4, 6):
        CH(sidebar(blocks=blocks))
    for bold, font in ((0, "Side"), (1, "Body"), (1, "Side")):
        CH(sidebar(bold=bold, font=font))
    # Spread across two pages, which the same-page guard refuses.
    CH(sidebar(page=2))
    # Varying sizes give the span evidence instead of the fixed-size one.
    out = sidebar()
    out[4] = out[4].replace(",8,1,Side,", ",8.6,1,Side,")
    CH(out)

    # Degenerate documents.
    CH([])
    CH([body_line(700)])
    CH([body_line(700 - i * 14) for i in range(20)])
    # Excluded lines cannot support a sequence.
    CH(hierarchy(), excluded=[0])
    CH(hierarchy(), excluded=[4])
    CH(hierarchy(), excluded=[0, 4])
    CH(sidebar(), excluded=[4, 9])
    # Tiers change the level a non-numbered promotion receives.
    for tiers in ((), (24,), (24, 16), (24, 16, 13, 11)):
        CH(sidebar(), tiers=tiers)
    # A dense document, where the candidates exceed the density ceiling.
    dense = []
    for index in range(12):
        dense.append(head_line(700 - index * 14, "Alpha~{}".format(index), x=200, size=8))
    CH(dense)

    # --- has_displaced_baseline_peer ---
    def D(target, specs):
        lines.append("D {} ; {}".format(target, " ".join(specs)))

    # One line, one run: nothing to be displaced from.
    D(0, ["1,700,20,100,alone"])
    D(0, [])
    D(5, ["1,700,20,100,alone"])
    # A void inside the line, walked around the 24pt bucket.
    for gap in (10, 20, 23, 24, 25, 40, 100):
        D(0, ["1,700,20,100,left", "+1,700,{},100,right".format(120 + gap)])
    # Runs given out of order, so the sort matters.
    D(0, ["1,700,200,100,right", "+1,700,20,100,left"])
    D(0, ["1,700,200,100,right", "+1,700,20,60,left"])
    # A negative width, floored at zero before the gap is measured.
    D(0, ["1,700,20,-50,left", "+1,700,60,100,right"])
    # A peer line at the same baseline and a displaced indent.
    for x in (20, 30, 43, 44, 45, 60, 200):
        D(0, ["1,700,20,100,first", "1,700,{},100,peer".format(x)])
    # The baseline tolerance, walked.
    for y in (700, 701, 702, 703, 705):
        D(0, ["1,700,20,100,first", "1,{},200,100,peer".format(y)])
    # A peer on another page does not count.
    D(0, ["1,700,20,100,first", "2,700,200,100,peer"])
    # Several lines, only one of which is a peer.
    D(1, ["1,720,20,100,above", "1,700,20,100,target", "1,700,200,100,peer",
          "1,680,20,100,below"])
    D(3, ["1,720,20,100,above", "1,700,20,100,target", "1,700,200,100,peer",
          "1,680,20,100,below"])
    # An empty line among them.
    D(0, ["1,700,20,100,first", "1,700,200,0,"])

    # --- sequence_level ---
    def SL(size, base, bold, depth, tiers):
        lines.append("SL {} {} {} {} | {}".format(
            size, base, bold, depth, " ".join(str(t) for t in tiers)))

    # Numbering wins outright, clamped to one through six.
    for depth in (0, 1, 2, 3, 6, 7, 12):
        SL(12, 10, 0, depth, [24, 16])
        SL(24, 10, 0, depth, [24, 16])
    # Without numbering, size decides — and the bold fallback catches what
    # size rejects, so this never refuses.
    for size in (10, 11, 12, 13, 16, 24, 40):
        for bold in (0, 1):
            SL(size, 10, bold, 0, [24, 16])
            SL(size, 10, bold, 0, [])
            SL(size, 10, bold, 0, [11])

    # --- numbering_has_section_separation ---
    def SS(left, right, pages):
        lines.append("SS {} {} ; {}".format(left, right, " ".join(str(p) for p in pages)))

    same = [1, 1, 1, 1, 1, 1]
    for left, right in ((0, 0), (0, 1), (0, 2), (0, 3), (0, 5), (3, 0), (5, 2)):
        SS(left, right, same)
    # A page boundary settles it outright, however close the lines.
    SS(0, 1, [1, 2, 2, 2, 2, 2])
    SS(1, 2, [1, 2, 2, 2, 2, 2])
    SS(0, 1, [1, 1, 2, 2, 2, 2])
    # Out-of-range indices.
    SS(0, 9, same)
    SS(9, 0, same)

    # --- visual style: dominant font, size, body font, body indent ---
    def V(mode, runs):
        lines.append("V {} ; {}".format(
            mode, " ".join("{},{},{},{},{}".format(f, sz, b, x, t.replace(" ", "~"))
                           for f, sz, b, x, t in runs)))

    shapes = [
        [],
        [("Body", 10, 0, 20, "a line of text")],
        [("Body", 10, 0, 20, "short"), ("Bold", 10, 1, 60, "a much longer run here")],
        [("Bold", 10, 1, 20, "a much longer run here"), ("Body", 10, 0, 60, "short")],
        # Equal weights, so the tie-breaks decide — and they differ per
        # function: font prefers the smaller name, size the larger bucket.
        [("Aaa", 10, 0, 20, "abcd"), ("Bbb", 10, 0, 60, "efgh")],
        [("Bbb", 10, 0, 20, "abcd"), ("Aaa", 10, 0, 60, "efgh")],
        [("Body", 10, 0, 20, "abcd"), ("Body", 14, 0, 60, "efgh")],
        [("Body", 14, 0, 20, "abcd"), ("Body", 10, 0, 60, "efgh")],
        # A small section number beside a larger title.
        [("Body", 8, 0, 20, "1."), ("Body", 16, 0, 40, "A Heading Title Here")],
        [("Body", 16, 0, 20, "A Heading Title Here"), ("Body", 8, 0, 200, "1.")],
        # Empty runs, which still weigh one for the per-line votes and
        # nothing for the document-level one.
        [("Body", 10, 0, 20, ""), ("Other", 10, 0, 60, "")],
        [("Body", 10, 0, 20, ""), ("Other", 10, 0, 60, "abc")],
        [("Body", 10, 0, 20, "   "), ("Other", 10, 0, 60, "ab")],
        # All bold, which the body-font vote skips entirely.
        [("Bold", 10, 1, 20, "all bold here")],
        [("Bold", 10, 1, 20, "bold"), ("Body", 10, 0, 60, "plain")],
        # Indent buckets, rounded at 24pt.
        [("Body", 10, 0, 0, "at zero")],
        [("Body", 10, 0, 11, "just under half")],
        [("Body", 10, 0, 12, "exactly half")],
        [("Body", 10, 0, 13, "just over half")],
        [("Body", 10, 0, 36, "one and a half")],
        [("Body", 10, 0, 240, "ten buckets")],
        [("Body", 10, 0, -20, "negative")],
        # Size buckets rounded to a tenth.
        [("Body", 10.04, 0, 20, "a")],
        [("Body", 10.05, 0, 20, "a")],
        [("Body", 10.06, 0, 20, "a")],
        # A mixed document: mostly one font, some bold headings.
        [("Body", 10, 0, 20, "a long line of body text here"),
         ("Body", 10, 0, 20, "another long line of body"),
         ("Head", 16, 1, 20, "A Heading")],
        [("Head", 16, 1, 20, "A Heading"),
         ("Head", 16, 1, 20, "Another Heading"),
         ("Body", 10, 0, 20, "short")],
        # Two indents competing, one bold.
        [("Body", 10, 0, 20, "a long line of body text here"),
         ("Body", 10, 1, 100, "an even longer bold line of text here now")],
    ]
    for runs in shapes:
        for mode in range(5):
            V(mode, runs)

    fonts = ["Body", "Bold", "Aaa", "Zzz"]
    for _ in range(random_count // 2):
        runs = []
        for _ in range(rng.randrange(0, 5)):
            runs.append((rng.choice(fonts), rng.choice([8, 10, 10.5, 12, 16]),
                         rng.choice([0, 1]), rng.choice([0, 20, 36, 100]),
                         rng.choice(["a", "abc", "a longer run", "", "  "])))
        V(rng.randrange(0, 5), runs)

    # --- title_like and complete_sidebar_label ---
    titles = [
        "Introduction", "The Quick Brown Fox", "a lowercase heading",
        "Mixed Case Heading Here", "ALL CAPS HEADING", "Ends with period.",
        "Ends with comma,", "Ends with semicolon;", "Ends with colon:",
        "abc", "abcd", "x y", "1. Numbered Heading", "- bullet item",
        "* star item", "\u2022 dot item", "Figure 1: A caption here",
        "Table 2. Results", "Section ... 42", "or inversely",
        "S = kB ln W, (2)", "a b c d e f g h i j k l", "a b c d e f g h i j k l m",
        "The", "1234", "!!!!", "iPhone Settings Page", "the of and",
        "A Title With Twelve Words Here To Test The Upper Bound Now",
        "x" * 139, "x" * 140, "x" * 141, "", "   ",
    ]
    for text in titles:
        for numbered in (0, 1):
            for bold in (0, 1):
                lines.append("T {} {} {}".format(numbered, bold, text.replace(" ", "~")))

    sidebars = [
        "Complete Label", "Wrapped label-", "ends with the", "ends with of",
        "ends with THE", "ends with Of", "G 02", "G 2", "GG 02", "G 0a",
        "G", "02", "a 1", "\u00c5 02", "label with and", "label with android",
        "", "   ", "-", "one", "two words",
    ]
    for text in sidebars:
        lines.append("S " + text.replace(" ", "~"))

    # Random tokens and lines.
    letters = "IVXLCDM"
    for _ in range(random_count // 2):
        token = "".join(rng.choice(letters) for _ in range(rng.randrange(0, 10)))
        emit("R", token)
    parts = ["1", "2", "12", "999", "1000", "I", "IV", "x", "a", ".", ")", ":", ""]
    for _ in range(random_count):
        token = "".join(rng.choice(parts) for _ in range(rng.randrange(1, 5)))
        emit("N", token + " " + rng.choice(["Heading", "text here", "2.3", ""]))
        emit("A", token + " " + rng.choice(["Heading", "see 2.3", "1.2.3", "x"]))

    return lines


def postprocess_cases(random_count):
    """Cases auditing the markdown cleanup helpers."""
    rng = random.Random(75_2026)
    lines = []

    def emit(tag, text):
        lines.append("{} {}".format(tag, text.replace(" ", "~").replace("\n", "^")))

    corpus = [
        "", " ", "  ", "a", "a b", "a  b", "a   b", "  indented  text",
        "| a | b |", "|  a  |  b  |", "  | a | b |",
        "a  b  c  d", "trailing  ", "  leading", "\n", "a\nb", "a\n\nb",
        "a\n\n\nb", "a\n\n\n\nb", "  \n  \n  ",
        "Vice  President", "- item  one", "1.  numbered",
        "text ( a )", "text (a )", "text ( a)", "[ link ]", "{ x }",
        "a )", "a ]", "a }", "a  )", "((( )))",
        "word .", "word ,", "word !", "word ?", "word ;", "word :",
        "word . next", "a . b . c", "end .", "3 . 14",
        "Section ....... 42", "Section .... 42", "Section ... 42",
        "Section .. 42", "a....b", "....", "..........",
        "hyphen-\nated", "hyphen- \nated", "hyphen-\n ated",
        "well-known", "well-\nknown word", "end-\n", "-\nstart",
        "a-\nb-\nc", "co-\noperate and re-\nuse",
        "7", "42", "  7  ", "page 7", "Page 7", "- 7 -", "[7]", "vii",
        "VII", "iv", "1234", "12345", "7.", "7 of 9", "Chapter 7",
        "a\n7\nb", "a\n\n7\n\nb", "text\n42\ntext",
        "See https://example.com now", "http://x.y", "https://example.com/a?b=c",
        "(https://example.com)", "https://example.com.", "https://example.com,",
        "[already](https://example.com)", "www.example.com",
        "visit https://a.b/c) and https://d.e/f.",
        "mixed  https://x.y  spaces", "https://",
        "# Heading  with  spaces", "## H2 .", "> quote  text",
        "```\ncode  block\n```", "a\n\n\n\n\n\nb",
    ]

    tags = ["SP", "BR", "PU", "DL", "HY", "PN", "IP", "UR", "CM", "CC"]
    for text in corpus:
        for tag in tags:
            emit(tag, text)

    # Random markdown-ish strings.
    pieces = ["a", "b", " ", "  ", "\n", "\n\n", ".", ",", ")", "]", "-",
              "...", "....", "7", "42", "https://x.y", "|", "#", "word"]
    for _ in range(random_count):
        text = "".join(rng.choice(pieces) for _ in range(rng.randrange(0, 14)))
        emit(rng.choice(tags), text)

    return lines


def heading_cases(random_count):
    """Cases for the heading-tier and heading-level pair."""
    rng = random.Random(72_2026)
    lines = []

    def L(font, base, tiers, bold=0):
        lines.append("L {} {} | {} | {}".format(
            font, base, " ".join(str(t) for t in tiers), bold))

    def T(base, entries):
        lines.append("T {} ; {}".format(
            base, " ".join("{},{},{}".format(size, bold, text)
                           for size, bold, text in entries)))

    def B(runs):
        lines.append("B ; " + " ".join("{},{}".format(b, t) for b, t in runs))

    # --- detect_header_level ---
    tiers = [24.0, 16.0, 13.0]
    # The 1.2 gate, and tier matching either side of it.
    for font in (10, 11.9, 12, 12.1, 13, 13.4, 13.6, 16, 24, 30, 40):
        for bold in (0, 1):
            L(font, 10, tiers, bold)
    # The bold sub-gate between 1.05 and 1.2, which only bold lines reach.
    for font in (10.4, 10.5, 10.6, 11, 11.5, 11.9, 12.0):
        for bold in (0, 1):
            L(font, 10, [11.0, 10.6], bold)
            L(font, 10, [], bold)
    # Tier tolerance is half a point, exclusive.
    for font in (15.4, 15.5, 15.6, 16.4, 16.5, 16.6):
        L(font, 10, tiers)
    # Large ratios with no matching tier: placed after the last tier, capped.
    for count in (0, 1, 2, 3, 4, 5, 6):
        L(40, 10, [100.0] * count)
    # No tiers at all -- the ratio decides alone and never returns nothing.
    for ratio in (1.2, 1.24, 1.25, 1.3, 1.49, 1.5, 1.9, 2.0, 2.5, 10.0):
        L(round(10 * ratio, 3), 10, [])
    # A zero or negative base size.
    for base in (0, -1):
        L(12, base, tiers)
    # Random combinations.
    for _ in range(random_count):
        base = rng.choice([8.0, 10.0, 12.0])
        font = round(base * rng.uniform(0.8, 3.0), 2)
        count = rng.randrange(0, 5)
        ts = sorted((round(base * rng.uniform(1.0, 3.0), 2) for _ in range(count)),
                    reverse=True)
        L(font, base, ts, rng.choice([0, 1]))

    # --- compute_heading_tiers ---
    # Ordinary documents: a few heading sizes over body text.
    T(10, [(24, 0, "Title"), (16, 0, "Section"), (10, 0, "body~text~here")])
    T(10, [(24, 0, "Title"), (24, 0, "Another"), (16, 0, "Section")])
    # Sizes clustering within half a point.
    T(10, [(16.0, 0, "A"), (16.4, 0, "B"), (16.6, 0, "C"), (17.2, 0, "D")])
    # Digit-only lines must not define a tier.
    T(10, [(24, 0, "7"), (16, 0, "Section~heading")])
    T(10, [(24, 0, "7"), (24, 0, "8"), (16, 0, "Section~heading")])
    T(10, [(24, 0, "Chapter~7"), (16, 0, "Section~heading")])
    T(10, [(24, 0, "-~7~-"), (16, 0, "Section")])
    # More than four tiers, which are capped.
    T(10, [(40 - i * 3, 0, "H{}".format(i)) for i in range(8)])
    # Nothing clears the 1.2 gate: the bold fallback supplies the tiers.
    for size in (10.4, 10.5, 10.6, 11, 11.9):
        T(10, [(size, 1, "Bold~section~heading"), (10, 0, "body~text")])
        T(10, [(size, 0, "Plain~section~heading"), (10, 0, "body~text")])
    # ... and the fallback's own digit-only exclusion.
    T(10, [(11, 1, "7"), (10, 0, "body~text")])
    T(10, [(11, 1, "7"), (11, 1, "Real~heading"), (10, 0, "body")])
    # Several bold sizes in the fallback, clustered and capped.
    T(10, [(11 + i * 0.3, 1, "H{}".format(i)) for i in range(10)])
    # Empty input, and lines with no items' worth of text.
    T(10, [])
    T(0, [(24, 0, "Title")])
    for _ in range(random_count // 2):
        base = rng.choice([9.0, 10.0, 11.0])
        entries = []
        for _ in range(rng.randrange(0, 8)):
            entries.append((round(base * rng.uniform(0.9, 3.0), 2),
                            rng.choice([0, 1]),
                            rng.choice(["heading", "7", "12.4", "a~heading~here", "-"])))
        T(base, entries)

    # --- line_is_mostly_bold ---
    B([(1, "bold")])
    B([(0, "plain")])
    B([])
    # Half the characters is the bar, and it is inclusive.
    B([(1, "abcd"), (0, "efgh")])
    B([(1, "abcd"), (0, "efghi")])
    B([(1, "abcde"), (0, "efgh")])
    # A section-number prefix that is not bold.
    B([(0, "4.~"), (1, "A~bold~section~title")])
    B([(0, "4.~a~rather~long~unbold~prefix"), (1, "bold")])
    # Whitespace is trimmed per run before counting.
    B([(1, "~~a~~"), (0, "bcd")])
    B([(0, "~~~~~~"), (1, "ab")])
    for _ in range(random_count // 2):
        runs = [(rng.choice([0, 1]), rng.choice(["a", "abc", "abcdef", "~", "a~b"]))
                for _ in range(rng.randrange(0, 5))]
        B(runs)

    def F(text):
        lines.append("F " + text.replace(" ", "~"))

    # --- has_dot_leaders ---
    for text in ("Section .... 42", "Section ... 42", "Section ... ... 42",
                 "a.b.c", "....", "...", "..", ".", "", "a...b...c",
                 "Chapter one. Then two. Then three.",
                 "an ellipsis ... alone", "two ... groups ... here",
                 "....leading", "trailing....", "a....b"):
        F(text)

    # --- is_toc_entry_line ---
    for text in ("Measurement Lab worksheet ... 3", "Worksheet .... 42",
                 "Worksheet ..12", "Worksheet ...12345", "Worksheet ...1234",
                 "Worksheet ... ", "Worksheet 3", "Worksheet...3",
                 "Worksheet ..3", "Worksheet ...3   ", "...3", "3", "...",
                 "Worksheet ... 0", "Worksheet ....... 3"):
        F(text)

    # --- is_toc_marker_heading ---
    for text in ("Contents", "contents", "CONTENTS", " Contents ", "Contents:",
                 "Contents::", "Contents :", "Table of Contents",
                 "table of contents", "TABLE OF CONTENTS", "Table Of Contents:",
                 "Table  of  Contents", "Contents of the Book", "Content",
                 "Contents page", ":"):
        F(text)

    # --- is_heading_fragment ---
    # The short-lowercase rule.
    for text in ("or inversely", "and therefore", "Or Inversely", "inversely",
                 "a", "A", "or inversely then", "the quick brown",
                 "3 or", "(2) or", "  or inversely  ", "42", "(2)"):
        F(text)
    # Equation-number suffix needing corroboration.
    for text in ("S = kB ln W, (2)", "Nicaea (325)", "Appendix A (3)",
                 "Some Heading (12)", "Total mass, (4)", "Total mass: (4)",
                 "Total mass (4)", "E = mc2 (5)", "Rate ≤ limit (6)",
                 "Value ± error (7)", "Sum ∑ terms (8)", "Plain words (9)",
                 "Heading (1234)", "Heading ()", "Heading (a)", "Heading (12"):
        F(text)
    # Page-of-total running headers.
    for text in ("LIVSMEDELSVERKET PM 2 (10)", "PM 10 (2)", "PM 2 (2)",
                 "PM 0 (0)", "PM -1 (5)", "PM 2x (10)", "Report 3 (12)"):
        F(text)
    # Lead-ins ending with a colon.
    for text in ("Rearranging Equation (8) gives:", "Procedure:",
                 "Steps for Using the Microscope:", "See (12) below:",
                 "Equation (8):", "Equation 8 gives:", "(8):"):
        F(text)
    # Tabs rather than spaces, which the space-only split treats differently.
    F("S = kB ln W,\t(2)")
    F("PM 2\t(10)")

    for _ in range(random_count // 2):
        pieces = []
        for _ in range(rng.randrange(1, 6)):
            pieces.append(rng.choice([
                "Heading", "value", "=", "mass,", "mass:", "(2)", "(12)", "(1234)",
                "...", "....", "3", "42", "Contents", "of", "≤", "±", ":"]))
        F(" ".join(pieces))

    def S(entries, per_item=0):
        lines.append("S {} ; {}".format(
            per_item, " ".join("{},{}".format(size, text) for size, text in entries)))

    def BL(n):
        lines.append("BL {}".format(n))

    # --- calculate_font_stats / from_items ---
    # An ordinary document: mostly body, a few headings.
    body = [(10, "body~line")] * 20 + [(24, "Title")] + [(16, "Section")] * 3
    S(body)
    S(body, per_item=1)
    # Nothing at all.
    S([])
    S([], per_item=1)
    # Everything under the nine-point floor, so no size votes.
    S([(8, "tiny")] * 10)
    S([(8.9, "tiny")] * 10)
    S([(9.0, "small")] * 10)
    # Ties, which go to the smaller size.
    S([(10, "a")] * 5 + [(12, "b")] * 5)
    S([(12, "a")] * 5 + [(10, "b")] * 5)
    S([(10, "a")] * 5 + [(12, "b")] * 5 + [(11, "c")] * 5)
    # Truncation rather than rounding at the tenth boundary: 12.19 and 12.11
    # share a key, 12.2 does not.
    for size in (12.0, 12.09, 12.1, 12.11, 12.19, 12.2, 12.25, 12.29, 12.3):
        S([(size, "x")] * 3 + [(20, "y")])
    S([(12.11, "a")] * 3 + [(12.19, "b")] * 3)
    S([(12.19, "a")] * 3 + [(12.2, "b")] * 3)
    # A single size, and a wide spread.
    S([(11, "only")])
    S([(9 + i, "size{}".format(i)) for i in range(12)])
    # Sizes just under and over the floor mixed together.
    S([(8.5, "a")] * 10 + [(10, "b")] * 3)
    # Fractional sizes that truncate to the same key.
    S([(10.04, "a"), (10.05, "b"), (10.09, "c"), (10.1, "d")])
    for _ in range(random_count // 2):
        entries = [(round(rng.uniform(6.0, 30.0), 2), "t")
                   for _ in range(rng.randrange(0, 15))]
        S(entries, per_item=rng.choice([0, 1]))

    # --- bold_heading_level ---
    for n in range(0, 9):
        BL(n)

    def PT(base, entries):
        lines.append("PT {} ; {}".format(
            base, " ".join("{},{}".format(page, y) for page, y in entries)))

    # --- compute_paragraph_threshold ---
    # Evenly spaced lines on one page.
    PT(10, [(1, 700 - r * 14) for r in range(12)])
    # Too few gaps to trust a median.
    for count in (1, 3, 5, 6, 7):
        PT(10, [(1, 700 - r * 14) for r in range(count)])
    # Double-spaced text, where a fixed multiple of the base would fail.
    PT(10, [(1, 700 - r * 28) for r in range(12)])
    # Gaps at and past the ten-times-base ceiling, which are dropped.
    for gap in (50, 99, 100, 101, 150):
        entries = [(1, 700 - r * 14) for r in range(8)]
        entries.append((1, entries[-1][1] - gap))
        entries += [(1, entries[-1][1] - 14 * (r + 1)) for r in range(4)]
        PT(10, entries)
    # A page break: the same lines split across two pages, where the gap
    # between them must not count.
    for split in (0, 3, 6, 12):
        entries = [(1 if r < split else 2, 700 - r * 14) for r in range(12)]
        PT(10, entries)
    # A page break that produces a *positive* gap under the ceiling, which is
    # the only case where the page check changes the answer.
    entries = [(1, 700 - r * 14) for r in range(6)]
    entries += [(2, 600 - r * 40) for r in range(6)]
    PT(10, entries)
    # The floor at 1.5x base beats a tiny median.
    for step in (2, 6, 11, 12, 13, 20, 40):
        PT(10, [(1, 700 - r * step) for r in range(12)])
    # Negative and zero gaps are skipped.
    PT(10, [(1, 700 + r * 14) for r in range(12)])
    PT(10, [(1, 700) for _ in range(12)])
    # A different base size scales both the ceiling and the floor.
    for base in (6, 8, 12, 20):
        PT(base, [(1, 700 - r * 14) for r in range(12)])
    PT(0, [(1, 700 - r * 14) for r in range(12)])
    for _ in range(random_count // 3):
        entries = []
        y = 700.0
        page = 1
        for _ in range(rng.randrange(0, 20)):
            entries.append((page, round(y, 1)))
            y -= rng.choice([0, 5, 12, 14, 30, 120, -20])
            if rng.random() < 0.15:
                page += 1
                y = 700.0
        PT(rng.choice([8.0, 10.0, 12.0]), entries)

    return lines


def reading_cases(random_count):
    """Cases for the leaves of image-anchored reading order."""
    rng = random.Random(67_2026)
    lines = []

    def spec(items):
        return " ".join("{},{},{},{}".format(x, y, w, t) for x, y, w, t in items)

    prose = "a~sentence~of~genuine~running~prose"
    short = "ab~cd"

    # page_x_bounds: text only, images only, both, and the degenerate cases.
    def B(images, items):
        lines.append("B | {} ; {}".format(
            " ".join("{},{},{},{}".format(*r) for r in images) or "-", spec(items)))
    B([], [(20, 700, 100, "a"), (300, 690, 100, "b")])
    B([(400, 0, 500, 100)], [(20, 700, 100, "a")])
    B([(500, 0, 400, 100)], [(20, 700, 100, "a")])   # corners reversed
    B([(-50, 0, 50, 100)], [(20, 700, 100, "a")])
    B([], [])                                         # nothing at all
    B([(100, 0, 200, 50)], [])                        # images only
    B([], [(20, 700, 0, "a")])                        # single zero-width item
    B([], [(20, 700, 0, "")])                         # degenerate extent
    B([], [(20, 700, 100, "a"), (20, 690, 100, "b")])
    for count in (1, 2, 5):
        B([(i * 100, 0, i * 100 + 50, 50) for i in range(count)],
          [(20, 700, 100, "a")])

    # group_rows: the moving mean baseline is the point of these.
    def G(items):
        lines.append("G ; " + spec(items))
    G([(20, 700, 50, "a"), (100, 700, 50, "b"), (200, 700, 50, "c")])
    G([(20, 700 - r * 14, 50, "a") for r in range(6)])
    # Gently rising text: each step is under the tolerance but the mean
    # moves, so the row can chain further than a fixed baseline would allow.
    for step in (0.5, 1.0, 1.5, 2.0, 2.9, 3.0, 3.1):
        G([(20 + i * 40, 700 - i * step, 30, "x") for i in range(8)])
    # Same baselines out of stream order.
    G([(200, 700, 50, "c"), (20, 700, 50, "a"), (100, 700, 50, "b")])
    G([(20, 690, 50, "b"), (20, 700, 50, "a")])
    # Items sharing x, so the stable sort inside a row shows.
    G([(20, 700, 50, "a"), (20, 700, 50, "b"), (20, 700, 50, "c")])
    G([])
    for _ in range(random_count // 2):
        count = rng.randrange(0, 10)
        G([(rng.randrange(0, 400), 700 - rng.randrange(0, 40),
            rng.choice([0, 30, 60]), "x") for _ in range(count)])

    # side_is_prose: the word, letter and CJK bars.
    def W(items):
        lines.append("W ; " + spec(items))
    W([(0, 0, 0, prose)])
    W([(0, 0, 0, short)])
    W([])
    for text in ("a~b~c", "abc~def~ghi", "abcd~defg~hij", "one~two", "one~two~three",
                 "abcdefghij", "abcdefghij~k~l"):
        W([(0, 0, 0, text)])
    # Split across several runs, which are joined with a space first.
    W([(0, 0, 0, "abcd"), (0, 0, 0, "defg"), (0, 0, 0, "hij")])
    W([(0, 0, 0, "abcdefghij"), (0, 0, 0, "k")])
    # CJK: ten characters is the alternative to three words, but the ten
    # letters still have to come from somewhere.
    cjk = "\u65e5\u672c\u8a9e" * 4
    W([(0, 0, 0, cjk)])
    W([(0, 0, 0, cjk + "~abcdefghij")])
    W([(0, 0, 0, "\u65e5\u672c" + "~abcdefghij")])

    # aligned_row_split: the gutter, the middle-half rule and the prose test.
    def A(items, x_min=0.0, x_max=600.0):
        lines.append("A {} {} ; {}".format(x_min, x_max, spec(items)))
    for gap in (2, 6, 8, 10, 40, 100):
        A([(100, 700, 100, prose), (200 + gap, 700, 100, prose)])
    # The split must land between 25% and 75% of the page.
    for left_x in (0, 40, 100, 200, 300, 400, 460):
        A([(left_x, 700, 60, prose), (left_x + 100, 700, 60, prose)])
    # One side not prose.
    A([(100, 700, 100, prose), (240, 700, 100, short)])
    A([(100, 700, 100, short), (240, 700, 100, prose)])
    # Four runs splitting two-and-two, judged on all four.
    A([(20, 700, 80, prose), (110, 700, 80, prose),
       (320, 700, 80, prose), (410, 700, 80, prose)])
    # Two candidate gaps of different widths -- the wider wins.
    A([(20, 700, 60, prose), (150, 700, 60, prose), (400, 700, 60, prose)])
    # Two candidate gaps of equal width -- the later one wins.
    A([(20, 700, 60, prose), (160, 700, 60, prose), (300, 700, 60, prose)])
    # A single run, and none.
    A([(100, 700, 100, prose)])
    A([])
    for _ in range(random_count // 2):
        count = rng.randrange(0, 5)
        A([(rng.randrange(0, 500), 700, rng.choice([0, 40, 80]),
            rng.choice([prose, short, "x"])) for _ in range(count)])

    # local_flow_below_full_width_image: a square hero image with two
    # columns of caption prose beneath it.
    def L(images, items, x_min=0.0, x_max=600.0):
        lines.append("L {} {} | {} ; {}".format(
            x_min, x_max,
            " ".join("{},{},{},{}".format(*r) for r in images) or "-", spec(items)))

    def caption(rows=6, top=430, step=14, left_x=20, left_w=200, right_x=320, right_w=200,
                text=None):
        body = text or prose
        out = []
        for r in range(rows):
            y = top - r * step
            out.append((left_x, y, left_w, body))
            out.append((right_x, y, right_w, body))
        return out

    # A 510x500 image from y=1000 down to y=500 on a 600pt page.
    hero = (45, 500, 555, 1000)
    L([hero], caption())
    # The image-gap band: 60..120 points below the image bottom.
    for top in (500, 460, 441, 440, 439, 400, 381, 380, 379, 340):
        L([hero], caption(top=top))
    # Aspect ratio: near-square only.
    for height in (300, 420, 433, 434, 510, 611, 612, 700):
        L([(45, 1000 - height, 555, 1000)], caption(top=1000 - height - 65))
    # Width against the page: 0.65 to be counted, 0.85 to be the anchor.
    for width in (300, 389, 390, 400, 500, 509, 510, 560):
        L([(45, 500, 45 + width, 1000)], caption())
    # Height floor for counting as full width at all.
    for height in (40, 59, 60, 61, 100):
        L([(45, 1000 - height, 555, 1000)], caption(top=1000 - height - 65))
    # Exactly one full-width image, never two.
    L([hero, (45, 1100, 555, 1600)], caption())
    L([hero, (45, 200, 100, 260)], caption())
    L([], caption())
    # Four rows must agree.
    for rows in (2, 3, 4, 5, 8):
        L([hero], caption(rows=rows))
    # Rows whose splits disagree, so no cluster reaches four.
    out = []
    for r in range(8):
        y = 430 - r * 14
        offset = (r % 4) * 60
        out.append((20 + offset, y, 150, prose))
        out.append((260 + offset, y, 150, prose))
    L([hero], out)
    # Splits within the 20pt tolerance still cluster together.
    out = []
    for r in range(6):
        y = 430 - r * 14
        offset = (r % 3) * 6
        out.append((20, y, 200 + offset, prose))
        out.append((320 + offset, y, 200, prose))
    L([hero], out)
    # The band must be short: rows spread over more than 130 points.
    for step in (14, 20, 25, 26, 30):
        L([hero], caption(rows=6, step=step))
    # Text below the 220pt window is not considered.
    for top in (430, 350, 290, 281, 280, 270):
        L([hero], caption(top=top))
    # Non-prose sides, so no row splits at all.
    L([hero], caption(text="ab~cd"))

    # paired_column_images: a page built from stacked panels either side of
    # a known split, with unbalanced text around them.
    def P2(images, items, split=300.0, x_min=0.0, x_max=600.0):
        lines.append("P2 {} {} {} | {} ; {}".format(
            split, x_min, x_max,
            " ".join("{},{},{},{}".format(*r) for r in images) or "-", spec(items)))

    def panels(left_n=2, right_n=2, width=230, height=150, top=900, step=200):
        out = []
        for i in range(left_n):
            out.append((20, top - i * step - height, 20 + width, top - i * step))
        for i in range(right_n):
            out.append((320, top - i * step - height, 320 + width, top - i * step))
        return out

    def sides(left_rows=10, right_rows=5, top=430, step=14):
        out = [(20, top - r * step, 200, prose) for r in range(left_rows)]
        out += [(320, top - r * step, 200, prose) for r in range(right_rows)]
        return out

    P2(panels(), sides())
    # The split must sit in the middle fifth of the page.
    for split in (200, 239, 240, 300, 360, 361, 400):
        P2(panels(), sides(), split=split)
    # Three qualifying and three wide images are both needed.
    for left_n, right_n in ((1, 1), (2, 1), (1, 2), (2, 2), (3, 3)):
        P2(panels(left_n=left_n, right_n=right_n), sides())
    # Narrow or short images do not qualify.
    for width in (40, 59, 60, 100, 209, 210, 230):
        P2(panels(width=width), sides())
    for height in (20, 39, 40, 80, 150):
        P2(panels(height=height), sides())
    # An image straddling the split belongs to neither column.
    P2(panels() + [(250, 100, 400, 260)], sides())
    # Images all on one side.
    P2(panels(left_n=4, right_n=0), sides())
    P2(panels(left_n=0, right_n=4), sides())
    # The vertical stack: panels side by side in one row must not qualify.
    for step in (0, 60, 100, 150, 200, 300, 400):
        P2(panels(step=step), sides())
    # The images must span 45% of the page width vertically.
    for step in (100, 130, 135, 140, 200):
        P2(panels(step=step, height=100), sides())
    # Row counts and the balance bar.
    for left_rows, right_rows in ((3, 3), (5, 4), (4, 5), (5, 5), (10, 4),
                                  (10, 5), (10, 6), (12, 6), (12, 7), (20, 4)):
        P2(panels(), sides(left_rows=left_rows, right_rows=right_rows))
    # Rows within 3pt collapse into one.
    for step in (2, 3, 4, 14):
        P2(panels(), sides(step=step))
    # No text at all below the panels.
    P2(panels(), [])
    # Text only in the middle, confined to neither column.
    P2(panels(), [(250, 430 - r * 14, 100, prose) for r in range(10)])

    # infer_image_anchored_flow + build_region_graph, end to end.
    def I(images, items, split=None, ):
        lines.append("I {} | {} ; {}".format(
            "-" if split is None else split,
            " ".join("{},{},{},{}".format(*r) for r in images) or "-", spec(items)))

    # The reference's own doc-test shape: a hero image with a caption below.
    hero_items = [(55, 230, 430, "A~full~width~caption"),
                  (55, 80, 430, "A~trailing~full~width~heading")]
    for index in range(5):
        y = 170 - index * 14
        hero_items.append((55, y, 210, "left~column~prose~words"))
        hero_items.append((280, y, 210, "right~column~prose~words"))
    I([(55, 250, 490, 680)], hero_items)
    # ... and with a split supplied, which sends it down the paired path
    # first -- which declines here, so the hero path answers anyway.
    for split in (200, 272, 300, 400):
        I([(55, 250, 490, 680)], hero_items, split=split)

    # The paired-panel page, with and without a split.
    paired_items = sides()
    I(panels(), paired_items)
    for split in (240, 300, 360):
        I(panels(), paired_items, split=split)

    # Nothing to work with.
    I([], hero_items)
    I([(55, 250, 490, 680)], [])
    I([], [])

    # Region graph shapes: material above, below, both and neither.
    def band_page(above=2, below=2, left=5, right=5, top=380, step=14):
        out = []
        for i in range(above):
            out.append((55, 700 + i * 20, 430, "heading~above~the~band"))
        for i in range(below):
            out.append((55, 60 - i * 20, 430, "heading~below~the~band"))
        for i in range(left):
            out.append((55, top - i * step, 210, "left~column~prose~words"))
        for i in range(right):
            out.append((280, top - i * step, 210, "right~column~prose~words"))
        return out
    for above, below in ((0, 0), (1, 0), (0, 1), (2, 2), (3, 1)):
        I([(55, 450, 490, 880)], band_page(above=above, below=below))
    # A right-to-left page, where the columns swap order. Four words a side,
    # since the prose test wants three and Arabic has no CJK exemption.
    arabic_left = "\u0645\u0631\u062d\u0628\u0627~\u0628\u0627\u0644\u0639\u0627\u0644\u0645~\u0627\u0644\u064a\u0648\u0645~\u062c\u0645\u064a\u0644"
    arabic_right = "\u0627\u0644\u0633\u0644\u0627\u0645~\u0639\u0644\u064a\u0643\u0645~\u0648\u0631\u062d\u0645\u0629~\u0627\u0644\u0644\u0647"
    rtl = []
    for i in range(2):
        rtl.append((55, 700 + i * 20, 430, "heading"))
    for i in range(5):
        y = 380 - i * 14
        rtl.append((55, y, 210, arabic_left))
        rtl.append((280, y, 210, arabic_right))
    I([(55, 450, 490, 880)], rtl)
    # The same page in English, so the pair differs only in direction.
    ltr = []
    for i in range(2):
        ltr.append((55, 700 + i * 20, 430, "heading"))
    for i in range(5):
        y = 380 - i * 14
        ltr.append((55, y, 210, "left~column~prose~words"))
        ltr.append((280, y, 210, "right~column~prose~words"))
    I([(55, 450, 490, 880)], ltr)
    # Items exactly on the band's edges, which belong to the columns.
    edge = band_page(above=0, below=0)
    edge.append((55, 383, 210, "on~the~top~edge"))
    edge.append((55, 325, 210, "on~the~bottom~edge"))
    I([(55, 450, 490, 880)], edge)

    # The layout assembly for one page: columns, regions, ordering.
    # A local name: `prose` is already taken in this generator.
    gl_prose = "a~sentence~of~genuine~running~prose~text"

    def GL(items, threshold=0.10, table=0, filter_numbers=1, charts=(), imgs=()):
        regions = " ".join("{},{},{},{}".format(*r) for r in charts)
        if imgs:
            regions = (regions + " / " if regions else "/ ") + " ".join(
                "{},{},{},{}".format(*r) for r in imgs)
        lines.append("GL {} {} {} | {} ; {}".format(
            threshold, table, filter_numbers, regions or "-", spec(items)))

    def two_col(rows=12, left_x=20, left_w=200, right_x=340, right_w=200, top=700, step=14,
                text=None):
        body = text or gl_prose
        out = []
        for r in range(rows):
            y = top - r * step
            out.append((left_x, y, left_w, body))
            out.append((right_x, y, right_w, body))
        return out

    def one_col(rows=12, top=700, step=14):
        return [(20, top - r * step, 560, gl_prose) for r in range(rows)]

    # Single column, and a page too small to have columns at all.
    GL(one_col())
    GL(one_col(rows=3))
    GL([])
    # Two columns: tabular (balanced) and newspaper (unbalanced) orderings.
    GL(two_col())
    GL(two_col(rows=30))
    out = two_col(rows=30)
    out += [(20, 700 - r * 14, 200, gl_prose) for r in range(30, 45)]
    GL(out)
    # A full-width title above two columns, which must not be split.
    GL([(20, 760, 560, "A~full~width~title~across~the~page")] + two_col())
    GL([(20, 760, 260, "A~full~width~title"), (300, 760, 280, "across~the~page")] + two_col())
    # A footer below the columns.
    GL(two_col() + [(20, 300, 560, "a~full~width~footer~line~here")])
    # Page numbers, filtered or preserved.
    numbered = two_col() + [(300, 60, 20, "7"), (300, 780, 20, "3")]
    GL(numbered, filter_numbers=1)
    GL(numbered, filter_numbers=0)
    # A page declared to have a table, which blocks the column fallbacks.
    GL(two_col(rows=30), table=1)
    GL(two_col(rows=30), table=0)
    # Adaptive thresholds are carried onto the lines rather than used here.
    for threshold in (0.10, 0.55, 1.20):
        GL(two_col(), threshold=threshold)
    # Chart regions blind the histogram to chart-internal text only.
    chart = [(240, 400, 400, 700)]
    scattered = two_col()
    scattered += [(260 + (r % 3) * 40, 690 - r * 20, 30, "12") for r in range(12)]
    GL(scattered, charts=chart)
    GL(scattered)
    # Image regions send the page down the region-graph path -- but only
    # when there are no charts.
    hero = [(55, 450, 490, 880)]
    hero_page = [(55, 700, 430, "heading~above~the~band")]
    for r in range(5):
        y = 380 - r * 14
        hero_page.append((55, y, 210, "left~column~prose~words"))
        hero_page.append((280, y, 210, "right~column~prose~words"))
    GL(hero_page, imgs=hero)
    GL(hero_page, imgs=hero, charts=chart)
    GL(hero_page)
    # Three and four column pages.
    def n_col(n, rows=12, width=None):
        w = width or (560 // n - 20)
        return [(20 + c * (w + 20), 700 - r * 14, w, gl_prose)
                for r in range(rows) for c in range(n)]
    for n in (3, 4):
        GL(n_col(n))
        GL(n_col(n, rows=30))
    # Columns of very different lengths, which drives newspaper detection.
    for right_rows in (5, 8, 12, 20, 28):
        out = [(20, 700 - r * 14, 200, gl_prose) for r in range(30)]
        out += [(340, 700 - r * 14, 200, gl_prose) for r in range(right_rows)]
        GL(out)
    # Stragglers: a cluster far below the column body.
    out = two_col(rows=20)
    out += [(20, 200 - r * 14, 200, gl_prose) for r in range(3)]
    GL(out)
    # Random pages, biased toward two-column shapes.
    rng5 = random.Random(71_2026)
    for _ in range(30):
        rows = rng5.randrange(3, 35)
        gap = rng5.choice([0, 10, 40, 120])
        lw = rng5.choice([150, 200, 280])
        out = []
        for r in range(rows):
            y = 700 - r * rng5.choice([12, 14, 18])
            out.append((20, y, lw, rng5.choice([gl_prose, "short", "12"])))
            if rng5.random() < 0.85:
                out.append((20 + lw + gap, y, rng5.choice([150, 200]), gl_prose))
        GL(out, table=rng5.choice([0, 0, 0, 1]),
           filter_numbers=rng5.choice([0, 1, 1]))

    # A page of nothing but page numbers, which the filter empties.
    GL([(300, 60, 20, "7"), (300, 780, 20, "3")], filter_numbers=1)
    GL([(300, 60, 20, "7"), (300, 780, 20, "3")], filter_numbers=0)
    # Newspaper pages carrying full-width material above and below, so the
    # spanning lines reach the newspaper ordering rather than the tabular one.
    for above, below in ((1, 0), (0, 1), (2, 2), (3, 0)):
        out = []
        for i in range(above):
            out.append((20, 780 + i * 20, 560, "a~full~width~heading~above~the~columns"))
        for i in range(below):
            out.append((20, 200 - i * 20, 560, "a~full~width~footer~below~the~columns"))
        out += [(20, 700 - r * 14, 200, gl_prose) for r in range(30)]
        out += [(340, 700 - r * 14, 200, gl_prose) for r in range(12)]
        GL(out)
    # ... and the same with the full-width material written as two runs.
    for above in (1, 2):
        out = []
        for i in range(above):
            out.append((20, 780 + i * 20, 250, "a~full~width~heading"))
            out.append((300, 780 + i * 20, 260, "above~the~columns~here"))
        out += [(20, 700 - r * 14, 200, gl_prose) for r in range(30)]
        out += [(340, 700 - r * 14, 200, gl_prose) for r in range(12)]
        GL(out)
    # More chart-blinded pages, with the chart in each column and spanning.
    for region in ((240, 400, 400, 700), (20, 400, 220, 700), (100, 300, 500, 700)):
        GL(scattered, charts=[region])
    # More region-graph pages: hero images of several sizes.
    for height in (430, 460, 500):
        img = [(55, 880 - height, 490, 880)]
        page = [(55, 700, 430, "heading~above~the~band")]
        for r in range(5):
            y = 880 - height - 70 - r * 14
            page.append((55, y, 210, "left~column~prose~words"))
            page.append((280, y, 210, "right~column~prose~words"))
        GL(page, imgs=img)

    # Dense *balanced* columns are what reads as newspaper, so the spanning
    # material only reaches that ordering on a page shaped like this.
    for above, below in ((1, 0), (0, 1), (2, 2), (3, 1)):
        out = []
        for i in range(above):
            out.append((20, 780 + i * 20, 560, "a~full~width~heading~above~the~columns"))
        for i in range(below):
            out.append((20, 200 - i * 20, 560, "a~full~width~footer~below~the~columns"))
        out += [(20, 700 - r * 14, 200, gl_prose) for r in range(30)]
        out += [(340, 700 - r * 14, 200, gl_prose) for r in range(26)]
        GL(out)
    # ... and with a straggler cluster far below one column, so stragglers
    # and spanning lines are ordered together.
    out = []
    out.append((20, 780, 560, "a~full~width~heading~above~the~columns"))
    out += [(20, 700 - r * 14, 200, gl_prose) for r in range(30)]
    out += [(340, 700 - r * 14, 200, gl_prose) for r in range(26)]
    out += [(20, 120 - r * 14, 200, gl_prose) for r in range(3)]
    GL(out)

    return lines


def valley_cases(random_count):
    """Cases for the leaf tests of column detection.

    The valley finder has eight consecutive gates, so the histograms are
    built to fail each one in turn: too few bins, an empty margin, a
    non-minimum, a short peak, unbalanced peaks, insufficient contrast, and a
    dip inside the page margin. Random histograms alone reach almost none of
    them.
    """
    rng = random.Random(61_2026)
    lines = []

    def hist(values, bin_width=2.0, page_width=612.0, margin=50.0):
        lines.append("V {} {} {} | {}".format(
            bin_width, page_width, margin, " ".join(str(int(v)) for v in values)))

    def two_columns(bins=160, gutter_at=80, gutter_width=5, peak=60, floor=0):
        """A justified two-column page: high on both sides, a dip between."""
        out = []
        for i in range(bins):
            if abs(i - gutter_at) <= gutter_width // 2:
                out.append(floor)
            else:
                out.append(peak)
        return out

    # Too few bins to consider at all.
    for n in (0, 1, 9, 10, 11):
        hist([30] * n)

    # The canonical shape, and the floor swept from empty to no-contrast.
    for floor in (0, 1, 2, 5, 10, 20, 30, 35, 36, 40, 59, 60):
        hist(two_columns(floor=floor))

    # Peak height at the 20 bar, from both sides.
    for peak in (5, 15, 19, 20, 21, 25, 100):
        hist(two_columns(peak=peak, floor=0))

    # Unbalanced peaks: the 0.40 balance gate. The left side is held at 100
    # and the right swept down through the bar.
    for right in (100, 60, 41, 40, 39, 20, 10):
        values = two_columns(peak=100, floor=0)
        for i in range(85, 160):
            values[i] = right
        hist(values)

    # The dip's position against the margin, including either side of it.
    for at in (5, 24, 25, 26, 30, 80, 130, 135, 136, 155):
        hist(two_columns(gutter_at=at), margin=50.0)
    for margin in (0.0, 10.0, 49.0, 50.0, 51.0, 200.0, 306.0, 400.0):
        hist(two_columns(), margin=margin)

    # Bin width changes where the margin test lands without changing shape.
    for bin_width in (0.5, 1.0, 2.0, 4.0, 8.0):
        hist(two_columns(), bin_width=bin_width)

    # Several gutters: the grouping and the single-best selection.
    values = two_columns(bins=240, gutter_at=60, floor=0)
    for i in range(118, 123):
        values[i] = 5
    for i in range(178, 183):
        values[i] = 2
    hist(values)
    # Two dips of equal contrast -- which one wins is the tie the reference
    # settles by taking the first.
    values = two_columns(bins=240, gutter_at=60, floor=3)
    for i in range(178, 183):
        values[i] = 3
    hist(values)
    # Adjacent candidates that must group into one valley rather than two.
    values = two_columns(bins=200, gutter_at=100, gutter_width=11, floor=4)
    hist(values)

    # A ragged single column: high in the middle, falling away at both
    # margins, which must not read as a gutter.
    values = [max(0, 60 - abs(i - 80)) for i in range(160)]
    hist(values)
    # A flat page, and a page with one spike.
    hist([40] * 160)
    values = [40] * 160
    values[80] = 0
    hist(values)

    # A narrow page: the scan window is wider than the histogram.
    for bins in (12, 24, 49, 50, 51, 60):
        hist(two_columns(bins=bins, gutter_at=bins // 2))

    # Random histograms, biased toward the ranges the gates care about.
    for _ in range(random_count):
        n = rng.choice([0, 5, 12, 60, 120, 160, 240])
        top = rng.choice([3, 25, 60, 200])
        hist([rng.randrange(0, top) for _ in range(n)],
             bin_width=rng.choice([0.5, 1.0, 2.0, 4.0]),
             margin=rng.choice([0.0, 20.0, 50.0, 150.0]))

    # One clean gutter and nothing else, at a range of widths and depths --
    # the single-valley return, which the multi-gutter cases above bypass.
    for width in (1, 3, 5, 7, 9, 11):
        for floor in (0, 2, 6, 12):
            hist(two_columns(bins=180, gutter_at=90, gutter_width=width, floor=floor))
    # A gutter with a sloped floor, so several adjacent bins qualify and have
    # to be grouped rather than each closing a group.
    for depth in (2, 4, 8):
        values = [60] * 180
        for offset, value in enumerate([depth * 3, depth * 2, depth, depth * 2, depth * 3]):
            values[88 + offset] = value
        hist(values)
    # Two candidates exactly five bins apart (same group) and exactly six
    # apart (a new one) -- the grouping boundary.
    for spacing in (2, 4, 5, 6, 7, 12):
        values = [60] * 200
        values[90] = 0
        values[90 + spacing] = 0
        hist(values)

    # spans_multiple_columns with items wide enough to actually span. A
    # full-width heading is the shape this test exists to catch.
    for width in (300, 320, 400, 612, 800):
        lines.append(f"S 0 {width} 12 Heading | 0 300 320 612")
        lines.append(f"S 0 {width} 12 Heading | 0 200 210 400 410 612")
        lines.append(f"S 0 {width} 12 Heading | 0 150 160 300 310 450 460 612")
    # Straddling the gutter by a walked amount: the 10%-of-width rule at a
    # 300pt column is 30pt, so the 20pt absolute rule decides below that.
    for overlap in (5, 15, 19, 20, 21, 25, 29, 30, 31, 50, 100):
        lines.append(f"S {280 - overlap} {overlap + 60} 12 T | 0 280 300 612")
    # The same walk against a narrow column, where 10% is under 20pt and the
    # percentage rule is the one that fires first.
    for overlap in (1, 2, 3, 5, 9, 10, 11, 21, 40):
        lines.append(f"S {100 - overlap} {overlap + 30} 12 T | 0 100 110 210")
    # No measured width, so the estimate from text length decides.
    for text in ("T", "Short", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"):
        for x in (0, 140, 280, 400):
            lines.append(f"S {x} 0 12 {text} | 0 300 320 612")
            lines.append(f"S {x} 0 40 {text} | 0 300 320 612")

    # --- validate_and_build_columns and columns_have_prose ---

    def items_spec(items):
        return " ".join("{},{},{},{}".format(x, y, w, t) for x, y, w, t in items)

    def emit_build(valleys, items, center=1, min_items=10, min_span=0.5,
                   x_min=0.0, bin_width=2.0, x_max=612.0):
        lines.append("C {} {} {} {} {} {} | {} ; {}".format(
            center, min_items, min_span, x_min, bin_width, x_max,
            " ".join("{}:{}".format(a, b) for a, b in valleys) or "-",
            items_spec(items)))

    def two_column_items(rows=14, left_x=40, right_x=330, width=220, text="word"):
        out = []
        for row in range(rows):
            y = 700 - row * 14
            out.append((left_x, y, width, text))
            out.append((right_x, y, width, text))
        return out

    # A clean two-column page, by centre and by edge assignment.
    for center in (0, 1):
        emit_build([(150, 155)], two_column_items(), center=center)
    # The minimum-items gate, walked.
    for rows in (2, 3, 4, 5, 9, 10, 11, 20):
        emit_build([(150, 155)], two_column_items(rows=rows))
    # An asymmetric sidebar: the dominant side is dense, the other thin.
    for small in (0, 1, 2, 3, 4, 10):
        items = [(40, 700 - r * 14, 220, "word") for r in range(14)]
        items += [(330, 700 - r * 14, 220, "word") for r in range(small)]
        emit_build([(150, 155)], items)
    # The smaller side is a column of bullets, which must be rejected.
    for markers in (0, 5, 8, 9, 10):
        items = [(330, 700 - r * 14, 220, "word") for r in range(14)]
        items += [(40, 700 - r * 14, 6,
                   "\u2022" if r < markers else "text") for r in range(10)]
        emit_build([(150, 155)], items)
    # Vertical overlap: text above a figure versus text beside it.
    for offset in (0, 100, 200, 300, 400):
        items = [(40, 700 - r * 14, 220, "word") for r in range(14)]
        items += [(330, 700 - offset - r * 14, 220, "word") for r in range(14)]
        emit_build([(150, 155)], items)
    for span in (0.0, 0.1, 0.3, 0.5, 0.7, 0.9, 1.0):
        items = [(40, 700 - r * 14, 220, "word") for r in range(14)]
        items += [(330, 500 - r * 14, 220, "word") for r in range(14)]
        emit_build([(150, 155)], items, min_span=span)
    # A full-width title, which must not stretch the page's vertical extent.
    items = two_column_items()
    items.append((0, 760, 612, "Title~across~the~page"))
    emit_build([(150, 155)], items)
    # Every item full-width, so no narrow ones remain and the range is
    # negatively infinite -- the overlap check is skipped entirely.
    emit_build([(150, 155)], [(0, 700 - r * 14, 612, "wide") for r in range(14)])
    # No valleys at all, and valleys that all fail.
    emit_build([], two_column_items())
    emit_build([(1, 2)], two_column_items())
    # More than three gutters: the scoring, the truncation and the re-sort.
    for count in (2, 3, 4, 5, 6):
        items = []
        for col in range(count + 1):
            for r in range(12):
                items.append((20 + col * 85, 700 - r * 14, 60, "word"))
        valleys = [(int((20 + c * 85 + 75) / 2), int((20 + c * 85 + 85) / 2))
                   for c in range(count)]
        emit_build(valleys, items, min_items=5)
    # Gutters of differing width, so the width term of the score decides.
    items = []
    for col in range(5):
        for r in range(12):
            items.append((20 + col * 110, 700 - r * 14, 80, "word"))
    emit_build([(50, 52), (105, 112), (160, 162), (215, 224)], items, min_items=5)
    # x_min shifting the gutter centres, and a bin width that moves them.
    for x_min in (0.0, 40.0, -20.0):
        for bin_width in (1.0, 2.0, 3.5):
            emit_build([(150, 155)], two_column_items(),
                       x_min=x_min, bin_width=bin_width)

    def emit_prose(columns, items):
        lines.append("R | {} ; {}".format(
            " ".join("{},{}".format(a, b) for a, b in columns) or "-",
            items_spec(items)))

    # Prose in both columns, and each way of failing.
    prose_left = [(40, 700 - r * 14, 220, "a~line~of~running~prose") for r in range(12)]
    prose_right = [(330, 700 - r * 14, 220, "a~line~of~running~prose") for r in range(12)]
    emit_prose([(20, 280), (300, 580)], prose_left + prose_right)
    # A narrow column is rejected outright.
    for width in (60, 119, 120, 121, 200):
        emit_prose([(20, 20 + width), (300, 580)], prose_left + prose_right)
    # Too few items, and too few lines despite enough items.
    for rows in (4, 7, 8, 9, 12):
        items = [(40, 700 - r * 14, 220, "prose~line") for r in range(rows)]
        items += [(330, 700 - r * 14, 220, "prose~line") for r in range(rows)]
        emit_prose([(20, 280), (300, 580)], items)
    # Twenty items all on one baseline: enough items, one line.
    items = [(40 + i * 10, 700, 8, "x") for i in range(20)]
    emit_prose([(20, 280)], items)
    # Line fill: short lines that do not reach 45% across.
    for width in (20, 60, 110, 117, 126, 200, 260):
        items = [(40, 700 - r * 14, width, "text") for r in range(12)]
        emit_prose([(20, 280)], items)
    # The full-line ratio, walked by mixing long and short lines.
    for full in range(0, 13, 2):
        items = [(40, 700 - r * 14, 220 if r < full else 20, "t") for r in range(12)]
        emit_prose([(20, 280)], items)
    # Items per line: a table has one item per cell.
    for per_line in (1, 2, 3, 4, 5, 8):
        items = []
        for r in range(12):
            for c in range(per_line):
                items.append((40 + c * 60, 700 - r * 14, 55, "cell"))
        emit_prose([(20, 280)], items)
    # Baseline tolerance: drifting text must not chain into one line.
    for drift in (0, 1, 2, 3, 4, 10):
        items = [(40, 700 - r * drift, 220, "text") for r in range(12)]
        emit_prose([(20, 280)], items)
    # Items overhanging the column, whose span must be clipped.
    items = [(-100, 700 - r * 14, 500, "over") for r in range(12)]
    emit_prose([(20, 280)], items)
    # No columns at all is vacuously prose.
    emit_prose([], prose_left)

    # Three-column pages, which the outcome spread was thin on.
    for cols in (3, 4):
        items = []
        for col in range(cols):
            for r in range(12):
                items.append((20 + col * 190, 700 - r * 14, 150, "word"))
        valleys = [(int((20 + c * 190 + 175) / 2), int((20 + c * 190 + 185) / 2))
                   for c in range(cols - 1)]
        emit_build(valleys, items, min_items=5)
    # More truncation shapes: many valleys of varied width and density, so
    # the score ordering and the re-sort by position both matter.
    for count in (4, 5, 7, 9):
        items = []
        for col in range(count + 1):
            for r in range(6 + col):
                items.append((15 + col * 62, 700 - r * 14, 40, "word"))
        valleys = [(int((15 + c * 62 + 56) / 2), int((15 + c * 62 + 62 + c) / 2))
                   for c in range(count)]
        emit_build(valleys, items, min_items=4)
    # Every item full-width in more shapes, so the narrow set stays empty.
    for width in (612, 500, 400):
        emit_build([(150, 155)],
                   [(0, 700 - r * 14, width, "wide") for r in range(14)])
        emit_build([(150, 155)],
                   [(0, 700 - r * 14, width, "wide") for r in range(4)], min_items=2)
    # Marker columns on either side of the gutter, and at the 80% bar.
    for markers in (7, 8, 9, 10):
        for side in (0, 1):
            wide = [(330 if side == 0 else 40, 700 - r * 14, 220, "word") for r in range(14)]
            thin = [(40 if side == 0 else 330, 700 - r * 14, 6,
                     "\u2022" if r < markers else "text") for r in range(10)]
            emit_build([(150, 155)], wide + thin)

    # Narrow columns, which reject before anything else is measured.
    for width in (10, 40, 80, 100, 118, 119, 120):
        emit_prose([(20, 20 + width)], prose_left)
        emit_prose([(20, 400), (420, 420 + width)], prose_left + prose_right)
    # Table-shaped columns: many items per line, walked around the 3.5 bar.
    for per_line in (3, 4, 6, 7, 10, 12):
        items = []
        for r in range(14):
            for c in range(per_line):
                items.append((30 + c * 20, 700 - r * 14, 15, "c"))
        emit_prose([(20, 300)], items)
    # A mix: seven items on some lines and one on others, so the average
    # lands either side of the bar without any line being typical.
    for heavy in range(0, 15, 3):
        items = []
        for r in range(14):
            count = 7 if r < heavy else 1
            for c in range(count):
                items.append((30 + c * 20, 700 - r * 14, 130 if count == 1 else 15, "c"))
        emit_prose([(20, 300)], items)

    # --- identify_spanning_lines ---

    def emit_mask(columns, items):
        lines.append("M | {} ; {}".format(
            " ".join("{},{}".format(a, b) for a, b in columns) or "-",
            items_spec(items)))

    cols2 = [(0, 300), (300, 612)]
    cols3 = [(0, 200), (200, 400), (400, 612)]

    # Two columns of body text at matching baselines: the gap sits at the
    # gutter, so nothing spans however wide the pair reaches.
    body = []
    for row in range(10):
        y = 700 - row * 14
        body.append((20, y, 260, "left~column~text"))
        body.append((320, y, 260, "right~column~text"))
    emit_mask(cols2, body)
    # A genuine full-width title added to that page.
    emit_mask(cols2, body + [(20, 760, 560, "A~title~across~the~page")])
    # A title written as two items with a gap that is *not* at the gutter.
    emit_mask(cols2, body + [(20, 760, 200, "A~title"), (240, 760, 340, "continues")])
    # ... and one whose gap lands exactly on the gutter, so it reads as two
    # columns rather than a title.
    emit_mask(cols2, body + [(20, 760, 260, "A~title"), (320, 760, 260, "continues")])
    # The gutter tolerance, walked: the gap edge creeps past the gutter.
    for start in (290, 300, 310, 316, 320, 330, 350):
        emit_mask(cols2, body + [(20, 760, 260, "left"), (start, 760, 200, "right")])
    # Gaps under 5pt are word spacing and are not considered at all.
    for gap in (0, 2, 4, 5, 6, 20):
        emit_mask(cols2, body + [(20, 760, 280, "left"), (300 + gap, 760, 280, "right")])
    # The 1.3x span threshold against the widest column.
    for width in (300, 380, 390, 391, 400, 500):
        emit_mask(cols2, body + [(20, 760, width, "wide")])
    # Fewer than three items, or fewer than two columns.
    emit_mask(cols2, [(20, 700, 500, "a"), (30, 690, 500, "b")])
    emit_mask([(0, 612)], body)
    emit_mask([], body)
    # Three columns, so two gutters, and a line crossing only the first.
    emit_mask(cols3, body)
    wide3 = []
    for row in range(8):
        y = 700 - row * 14
        wide3.append((10, y, 180, "a"))
        wide3.append((210, y, 180, "b"))
        wide3.append((410, y, 180, "c"))
    emit_mask(cols3, wide3)
    emit_mask(cols3, wide3 + [(10, 760, 590, "title")])
    # Items sharing a baseline exactly, so the stable sorts matter.
    same = [(400, 700, 100, "z"), (20, 700, 100, "a"), (200, 700, 100, "m"),
            (20, 686, 100, "b"), (200, 686, 100, "n"), (400, 686, 100, "y")]
    emit_mask(cols2, same)
    emit_mask(cols3, same)
    # Baseline tolerance of 5pt: drifting rows that must not chain.
    for drift in (0, 2, 4, 5, 6, 12):
        drifted = []
        for row in range(8):
            drifted.append((20, 700 - row * drift, 280, "a"))
            drifted.append((320, 700 - row * drift, 280, "b"))
        emit_mask(cols2, drifted)

    # A spanning line needs at least two items on its baseline -- a single
    # wide item is skipped outright, which starved these cases at first.
    for pieces in (1, 2, 3, 5):
        title = []
        width = 560 // pieces
        for piece in range(pieces):
            title.append((20 + piece * (width + 2), 760, width, "part"))
        emit_mask(cols2, body + title)
    # Multi-piece titles whose internal gaps sit away from the gutter.
    for gapx in (60, 120, 180, 240, 380, 440, 520):
        emit_mask(cols2, body + [(20, 760, gapx - 30, "a"), (gapx, 760, 580 - gapx, "b")])
    # Three-piece titles with one gap at the gutter and one away from it --
    # any gutter gap at all disqualifies the whole line.
    emit_mask(cols2, body + [(20, 760, 120, "a"), (160, 760, 130, "b"), (320, 760, 260, "c")])
    emit_mask(cols2, body + [(20, 760, 120, "a"), (160, 760, 300, "b"), (480, 760, 100, "c")])
    # Wide multi-item lines inside the body rows themselves.
    for width in (200, 260, 300, 400):
        wide = []
        for row in range(6):
            y = 700 - row * 14
            wide.append((20, y, width, "a"))
            wide.append((30 + width, y, width, "b"))
        emit_mask(cols2, wide)
    # Three columns with two-piece spanning lines at several heights.
    for count in (1, 2, 4):
        extra = [(10, 760 + r * 16, 280, "x") for r in range(count)]
        extra += [(300, 760 + r * 16, 290, "y") for r in range(count)]
        emit_mask(cols3, wide3 + extra)
    # Unmeasured widths, so the span uses the estimate from text length.
    for text in ("t", "medium~length", "a~very~much~longer~run~of~title~text"):
        emit_mask(cols2, body + [(20, 760, 0, text), (400, 760, 0, text)])

    # --- split_column_stragglers ---

    def emit_split(entries):
        lines.append("G " + " ".join("{},{}".format(y, n) for y, n in entries))

    # Evenly spaced lines: no split at all.
    emit_split([(700 - r * 14, 1) for r in range(10)])
    emit_split([(700 - r * 14, 1) for r in range(3)])
    # Below the three-line floor.
    for count in (0, 1, 2, 3):
        emit_split([(700 - r * 14, 1) for r in range(count)])
    # A header remnant far above the body.
    emit_split([(780, 1)] + [(700 - r * 14, 1) for r in range(10)])
    # A footer far below.
    emit_split([(700 - r * 14, 1) for r in range(10)] + [(80, 1)])
    # Both, so the core is the middle segment.
    emit_split([(780, 1)] + [(700 - r * 14, 1) for r in range(10)] + [(80, 1)])
    # The 3x-median rule, walked by widening one gap.
    for gap in (14, 30, 41, 42, 43, 50, 100):
        entries = [(700 - r * 14, 1) for r in range(5)]
        base = entries[-1][0] - gap
        entries += [(base - r * 14, 1) for r in range(5)]
        emit_split(entries)
    # The 30pt floor: tightly set lines whose 3x median is under it.
    for gap in (10, 20, 29, 30, 31, 40):
        entries = [(700 - r * 4, 1) for r in range(6)]
        base = entries[-1][0] - gap
        entries += [(base - r * 4, 1) for r in range(6)]
        emit_split(entries)
    # Two segments of equal length, where Rust keeps the *last* maximum.
    for half in (2, 3, 5):
        entries = [(700 - r * 14, 1) for r in range(half)]
        base = entries[-1][0] - 200
        entries += [(base - r * 14, 1) for r in range(half)]
        emit_split(entries)
    # Three segments with the largest in each position.
    for big in range(3):
        entries = []
        y = 900.0
        for segment in range(3):
            count = 8 if segment == big else 3
            for _ in range(count):
                entries.append((y, 1))
                y -= 14
            y -= 200
        emit_split(entries)
    # Every gap oversized, so every line is its own segment.
    emit_split([(900 - r * 200, 1) for r in range(5)])

    # --- try_xy_cut_split ---

    def emit_xy(items, x_min=0.0, x_max=612.0):
        lines.append("X {} {} ; {}".format(x_min, x_max, items_spec(items)))

    def sides(left_n=12, right_n=12, left_x=20, left_w=200, right_x=340, right_w=200,
              right_y0=700):
        out = [(left_x, 700 - r * 14, left_w, "l") for r in range(left_n)]
        out += [(right_x, right_y0 - r * 14, right_w, "r") for r in range(right_n)]
        return out

    # A clean sidebar cut, and the page-width floor.
    emit_xy(sides())
    for x_max in (150.0, 199.0, 200.0, 201.0, 612.0):
        emit_xy(sides(), x_max=x_max)
    # The 15pt gap floor, walked by sliding the right side toward the left.
    for start in (215, 220, 229, 230, 231, 240, 300):
        emit_xy(sides(right_x=start))
    # Overlapping items, which give a negative gap and must never win.
    emit_xy([(20, 700 - r * 14, 400, "a") for r in range(12)]
            + [(200, 700 - r * 14, 400, "b") for r in range(12)])
    # An item reaching across others, so the running maximum matters: without
    # it a false gap would appear behind the long item.
    emit_xy([(20, 760, 560, "banner")] + sides())
    emit_xy([(20, 760, 560, "banner")] + sides(right_x=400))
    # The 10% margin rule, walked by moving the cut toward each edge.
    for right_x in (70, 80, 90, 100, 500, 540, 560, 580):
        emit_xy(sides(left_w=20, right_x=right_x, right_w=20))
    # Item counts: the major side needs 10 and the minor 3.
    for left_n in (0, 1, 2, 3, 4, 9, 10, 11):
        emit_xy(sides(left_n=left_n))
    for right_n in (0, 2, 3, 9, 10, 11):
        emit_xy(sides(right_n=right_n))
    # Vertical overlap at the 20% bar: the right side slid down the page.
    for offset in (0, 100, 140, 145, 150, 200, 400):
        emit_xy(sides(right_y0=700 - offset))
    # Everything on one baseline, so the y range is floored at 1.
    emit_xy([(20 + r * 5, 700, 4, "l") for r in range(12)]
            + [(400 + r * 5, 700, 4, "r") for r in range(12)])
    # Unmeasured widths, so the estimate decides where the edges are.
    for text in ("a", "medium~text", "a~much~longer~run~of~text~here"):
        emit_xy([(20, 700 - r * 14, 0, text) for r in range(12)]
                + [(400, 700 - r * 14, 0, text) for r in range(12)])
    # Two items only, and a page of identical items.
    emit_xy([(20, 700, 100, "a"), (400, 700, 100, "b")])
    emit_xy([(20, 700 - r * 14, 100, "a") for r in range(24)])

    # --- is_newspaper_layout ---

    def emit_news(columns, groups):
        body = []
        for index, group in enumerate(groups):
            if index:
                body.append("/")
            body.extend(str(y) for y in group)
        lines.append("N | {} ; {}".format(
            " ".join("{},{}".format(a, b) for a, b in columns), " ".join(body)))

    def run(count, start=700, step=14):
        return [start - r * step for r in range(count)]

    even2 = [(0, 300), (300, 612)]
    # Fewer than two columns.
    emit_news(even2, [run(20)])
    # The five-line floor.
    for count in (3, 4, 5, 6):
        emit_news(even2, [run(count), run(20)])
    # Dense and balanced: the 0.7 ratio, walked.
    for short in (15, 16, 20, 21, 28, 29, 30):
        emit_news(even2, [run(short), run(30)])
    # Unbalanced and dense: the Y-collision fallback at the 0.5 bar.
    for aligned in (0, 4, 7, 8, 9, 12, 16):
        short = [700 - r * 14 if r < aligned else 100 - r * 14 for r in range(16)]
        emit_news(even2, [short, run(30)])
    # Three columns, and the collision check against any other column.
    emit_news([(0, 200), (200, 400), (400, 612)], [run(16), run(30), run(28)])
    emit_news([(0, 200), (200, 400), (400, 612)],
              [[100 - r * 14 for r in range(16)], run(30), run(28)])
    # The sidebar branch: every guard walked one at a time from a passing base.
    sidebar_cols = [(0, 400), (400, 580)]
    sparse = [700 - r * 40 for r in range(8)]
    dense = run(30)
    emit_news(sidebar_cols, [dense, sparse])
    # width ratio
    for narrow_start in (300, 380, 400, 410, 450):
        emit_news([(0, narrow_start), (narrow_start, 580)], [dense, sparse])
    # line balance and body size
    for sparse_n in (5, 8, 9, 10, 11, 14):
        emit_news(sidebar_cols, [dense, [700 - r * 40 for r in range(sparse_n)]])
    for body_n in (15, 19, 20, 21, 30):
        emit_news(sidebar_cols, [run(body_n), sparse])
    # narrow-column width floor
    for narrow_w in (100, 155, 159, 160, 161, 200):
        emit_news([(0, 400), (580 - narrow_w, 580)], [dense, sparse])
    # the density ratio at 2.5
    for step in (14, 28, 34, 35, 36, 40, 80):
        emit_news(sidebar_cols, [dense, [700 - r * step for r in range(8)]])
    # the narrower column must also be the emptier one
    emit_news(sidebar_cols, [sparse, dense])
    # a single-line column, whose average gap is zero
    emit_news(sidebar_cols, [dense, [700] * 6])

    # The dense-balanced route to "newspaper", which was thin: enough lines
    # in the shortest column that the sidebar branch is skipped entirely.
    for short in (15, 18, 22, 25, 30, 40):
        for long in (30, 40, 60):
            if short <= long:
                emit_news(even2, [run(short), run(long)])
    # A narrow column packed with lines is a reference table, not a sidebar,
    # so the narrower column must also be the emptier one.
    for narrow_lines in (6, 8, 10, 12):
        emit_news([(0, 400), (400, 580)],
                  [[700 - r * 40 for r in range(narrow_lines)], run(30)])
        emit_news([(0, 180), (180, 580)],
                  [run(30), [700 - r * 40 for r in range(narrow_lines)]])
    # A single column, and none at all.
    emit_news(even2, [run(30)])
    emit_news(even2, [])
    emit_news([(0, 612)], [run(20)])
    # Narrow pages for the xy cut, and pages with a single item.
    for x_max in (0.0, 50.0, 199.9):
        emit_xy(sides(), x_max=x_max)
    emit_xy([(20, 700, 100, "only")])
    # NOT emitted: an empty item list. `try_xy_cut_split` indexes
    # `0..len - 1`, which underflows to a huge range and panics -- confirmed
    # against the reference binary. Its own caller returns early for any page
    # under twenty items, so the case is unreachable there; this port guards
    # instead, which is a deliberate divergence from a trap that cannot be
    # observed through the real entry point.

    # --- detect_columns: the assembly of everything above ---

    def emit_detect(items, has_table=0):
        lines.append("D {} ; {}".format(has_table, items_spec(items)))

    def page(rows, cols_x, width=200, step=14, top=700, text="word"):
        out = []
        for row in range(rows):
            y = top - row * step
            for x in cols_x:
                out.append((x, y, width, text))
        return out

    # An empty page, and pages too small to judge.
    emit_detect([])
    for rows in (1, 5, 9, 10, 11):
        emit_detect(page(rows, [20, 340]))
    # A page narrower than 200pt however many items it has.
    emit_detect(page(20, [0, 60], width=40))
    emit_detect(page(20, [0, 300], width=40))
    # The clean two-column case, with an empty gutter.
    emit_detect(page(15, [20, 340]))
    emit_detect(page(30, [20, 340]))
    # Three and four columns.
    emit_detect(page(15, [10, 170, 330], width=140))
    emit_detect(page(15, [10, 160, 310, 460], width=130))
    # A single column of prose.
    emit_detect(page(30, [20], width=560))
    # Full-width titles must not fill the gutter: over 60% of the page width
    # they are left out of the histogram entirely.
    for title_w in (300, 360, 367, 380, 500, 560):
        emit_detect(page(15, [20, 340]) + [(20, 780, title_w, "title")])
    # The 5% margin rule on valley centres.
    for left_x in (0, 5, 20, 60):
        emit_detect(page(15, [left_x, 340]))
    # The 8pt minimum gutter, walked by narrowing the gap.
    for gap in (2, 6, 8, 10, 20, 60):
        emit_detect(page(15, [20, 220 + gap]))
    # The noise threshold: a few stray items inside the gutter.
    for strays in (0, 1, 2, 3, 5, 10):
        extra = [(250, 700 - r * 14, 40, "x") for r in range(strays)]
        emit_detect(page(20, [20, 340]) + extra)
    # Justified text filling the gutter, dense enough for the relative path.
    def justified(rows, left_x=20, left_w=280, right_x=310, right_w=280):
        out = []
        for row in range(rows):
            y = 700 - row * 14
            out.append((left_x, y, left_w, "a~line~of~running~prose~here"))
            out.append((right_x, y, right_w, "a~line~of~running~prose~here"))
        return out
    for rows in (20, 40, 49, 50, 51, 60):
        emit_detect(justified(rows))
    # ... and the same page declared to have a table, which blocks both the
    # relative path and the XY cut.
    for rows in (20, 60):
        emit_detect(justified(rows), has_table=1)
    # A dense page of short scattered items, which the prose check rejects.
    def scattered(rows):
        out = []
        for row in range(rows):
            y = 700 - row * 14
            for column in range(6):
                out.append((20 + column * 95, y, 30, "c"))
        return out
    for rows in (10, 18, 20, 30):
        emit_detect(scattered(rows))
        emit_detect(scattered(rows), has_table=1)
    # A sidebar the histogram misses but the XY cut finds.
    def sidebar(body_rows=24, side_rows=6):
        out = [(20, 700 - r * 12, 380, "body~text~running~on") for r in range(body_rows)]
        out += [(430, 700 - r * 40, 150, "note") for r in range(side_rows)]
        return out
    for side_rows in (2, 3, 6, 12):
        emit_detect(sidebar(side_rows=side_rows))
        emit_detect(sidebar(side_rows=side_rows), has_table=1)
    # Overlapping full-width paragraphs: no gutter anywhere.
    emit_detect([(20, 700 - r * 14, 560, "full~width~paragraph~text") for r in range(30)])
    # Items with no measured width, so the estimate drives the histogram.
    emit_detect([(20, 700 - r * 14, 0, "left~column~text") for r in range(15)]
                + [(340, 700 - r * 14, 0, "right~column~text") for r in range(15)])
    # A page whose columns sit at different heights, so the vertical-overlap
    # gate in validate_and_build_columns decides.
    for offset in (0, 100, 200, 300):
        out = [(20, 700 - r * 14, 200, "l") for r in range(15)]
        out += [(340, 700 - offset - r * 14, 200, "r") for r in range(15)]
        emit_detect(out)
    # Random dense pages, biased toward two-column shapes.
    rng2 = random.Random(65_2026)
    for _ in range(40):
        rows = rng2.randrange(5, 40)
        gap = rng2.choice([0, 5, 10, 20, 40, 80])
        left_w = rng2.choice([100, 200, 280, 380])
        out = []
        for row in range(rows):
            y = 700 - row * rng2.choice([12, 14, 20])
            out.append((20, y, left_w, "l"))
            if rng2.random() < 0.9:
                out.append((20 + left_w + gap, y, rng2.choice([100, 200, 280]), "r"))
        emit_detect(out, has_table=rng2.choice([0, 0, 0, 1]))

    # Touching columns with jagged right edges: the gutter bins are never
    # empty, so the absolute search finds nothing and the relative one has to
    # decide. Dense enough (>=100 items) to be allowed to try.
    rng3 = random.Random(65_1207)
    for rows in (48, 50, 55, 70):
        for jag in (10, 20, 40, 60, 90):
            out = []
            for row in range(rows):
                out.append((20, 700 - row * 12, 290 - rng3.randrange(0, jag),
                            "a~line~of~running~prose~text"))
                out.append((310, 700 - row * 12, 280 - rng3.randrange(0, jag),
                            "a~line~of~running~prose~text"))
            emit_detect(out)
            emit_detect(out, has_table=1)
    # The same shape but scattered short items, so the prose check rejects
    # what the relative valley proposed.
    for rows in (50, 60):
        out = []
        for row in range(rows):
            for column in range(6):
                out.append((20 + column * 95, 700 - row * 12,
                            30 - rng3.randrange(0, 8), "c"))
        emit_detect(out)
    # Columns overlapping vertically by between a fifth and a third, where
    # validate_and_build_columns declines at 0.30 and the XY cut accepts at
    # 0.20 -- the only route to the edge-based and XY fallbacks.
    for left_rows, right_rows, offset in [
        (20, 20, 200), (20, 20, 240), (20, 20, 260), (24, 24, 250),
        (30, 30, 300), (30, 30, 330), (16, 24, 220), (24, 16, 220),
        (24, 16, 180), (24, 16, 260), (40, 12, 300), (12, 40, 300),
    ]:
        out = [(20, 700 - r * 14, 200, "l") for r in range(left_rows)]
        out += [(340, 700 - offset - r * 14, 200, "r") for r in range(right_rows)]
        emit_detect(out)
        emit_detect(out, has_table=1)
    # Sparse pages with touching columns: no absolute valley and under a
    # hundred items, so the relative route is skipped and the fallbacks run.
    for rows in (11, 20, 30, 45):
        out = []
        for row in range(rows):
            out.append((20, 700 - row * 14, 290 - rng3.randrange(0, 40), "left~text"))
            out.append((310, 700 - row * 14, 280, "right~text"))
        emit_detect(out)
        emit_detect(out, has_table=1)

    # Touching cells either side of a gutter crossed by a minority of rows:
    # no empty bins anywhere, a shallow dip in the middle, and short items
    # that the prose check then refuses -- the relative route's rejection.
    rng4 = random.Random(65_1307)
    for rows in (50, 60):
        for cross in (0.15, 0.25, 0.35, 0.5):
            out = []
            for row in range(rows):
                y = 700 - row * 11
                for cell in range(5):
                    out.append((20 + cell * 56, y, 56, "cell"))
                for cell in range(5):
                    out.append((320 + cell * 56, y, 56, "cell"))
                if rng4.random() < cross:
                    out.append((300, y, 20, "x"))
            emit_detect(out)
    # Items straddling the gutter, whose centres fall on one side: centre and
    # edge assignment then disagree about where they belong.
    for straddle in (0, 4, 8, 12, 18):
        out = [(20, 700 - r * 14, 200, "l") for r in range(20)]
        out += [(340, 700 - r * 14, 200, "r") for r in range(20)]
        out += [(250, 700 - r * 14, 90, "s") for r in range(straddle)]
        emit_detect(out)

    # --- group_single_column and should_use_y_sorting ---

    def emit_single(items):
        # x,y,w,bold,fontsize,text
        lines.append("S1 ; " + " ".join(
            "{},{},{},{},{},{}".format(x, y, w, b, fs, t) for x, y, w, b, fs, t in items))

    def prose(x, y, w=200, bold=0, size=12, text="a~line~of~running~prose~text"):
        return (x, y, w, bold, size, text)

    # Ordinary stacked lines, in stream order.
    emit_single([prose(20, 700 - r * 14) for r in range(10)])
    # Two runs per line, left to right and out of order.
    out = []
    for r in range(8):
        y = 700 - r * 14
        out.append(prose(20, y, 100, text="left"))
        out.append(prose(130, y, 100, text="right"))
    emit_single(out)
    out = []
    for r in range(8):
        y = 700 - r * 14
        out.append(prose(130, y, 100, text="right"))
        out.append(prose(20, y, 100, text="left"))
    emit_single(out)

    # should_use_y_sorting: chaotic stream order, walked around 0.4.
    for ups in range(0, 9):
        out = []
        y = 700.0
        for step in range(8):
            out.append(prose(20, y))
            y += 120 if step < ups else -120
        emit_single(out)
    # Too few items, and too few jumps to judge.
    for count in (2, 4, 5, 6):
        emit_single([prose(20, 700 - r * 14) for r in range(count)])
    for jumps in (0, 1, 2, 3, 4):
        out = [prose(20, 700 - r * 2) for r in range(8)]
        for j in range(jumps):
            out.append(prose(20, 900 + j * 200))
        emit_single(out)

    # The 3pt baseline tolerance, walked.
    for drift in (0.0, 0.4, 0.6, 1.0, 2.9, 3.0, 3.1, 5.0):
        out = []
        for r in range(6):
            out.append(prose(20 + r * 60, 700 - r * drift, 50, text="run"))
        emit_single(out)
    # Same left margin with a small y change: stacked lines, not one line.
    for dx in (0, 2, 4, 5, 6, 20):
        out = [prose(20, 700, 50, text="a"), prose(20 + dx, 699, 50, text="b")]
        out += [prose(20, 700 - r * 14, 50, text="c") for r in range(1, 6)]
        emit_single(out)
    # Starting to the left of where the line reached.
    for back in (0, 5, 9, 10, 11, 30):
        out = [prose(100, 700, 50, text="a"), prose(100 - back, 699, 50, text="b")]
        out += [prose(20, 700 - r * 14, 50, text="c") for r in range(1, 6)]
        emit_single(out)

    # The wide-void prose split: same baseline, a big gap, both sides wordy.
    long_text = "a~sentence~of~genuine~running~prose"
    for gap in (20, 30, 36, 37, 40, 80, 200):
        out = [prose(20, 700, 100, text=long_text),
               prose(120 + gap, 700, 100, text=long_text)]
        out += [prose(20, 700 - r * 14, 100, text="filler") for r in range(1, 6)]
        emit_single(out)
    # Font size drives the threshold where it exceeds 30.
    for size in (6, 10, 12, 20, 40):
        out = [prose(20, 700, 100, size=size, text=long_text),
               prose(220, 700, 100, size=size, text=long_text)]
        out += [prose(20, 700 - r * 14, 100, text="filler") for r in range(1, 6)]
        emit_single(out)
    # The incoming run must start with a letter and be substantial prose.
    for incoming in ("42", "42~is~the~answer~here", "the~answer~is~here~now",
                     "short~two", "a~b~c", "abc~def~ghi", "no", "~", "3.14~pages~of~it"):
        out = [prose(20, 700, 100, text=long_text), prose(220, 700, 100, text=incoming)]
        out += [prose(20, 700 - r * 14, 100, text="filler") for r in range(1, 6)]
        emit_single(out)
    # The line side must be wordy too -- a short label keeps its value.
    for line_text in ("Name", "Name~here", "a~b", "a~much~longer~line~of~prose"):
        out = [prose(20, 700, 100, text=line_text), prose(220, 700, 100, text=long_text)]
        out += [prose(20, 700 - r * 14, 100, text="filler") for r in range(1, 6)]
        emit_single(out)
    # An uppercase start needs a style mismatch as well as prose.
    upper = "A~Sentence~Of~Genuine~Running~Prose"
    for line_bold, item_bold in ((0, 0), (1, 0), (0, 1), (1, 1)):
        out = [prose(20, 700, 100, bold=line_bold, text=long_text),
               prose(220, 700, 100, bold=item_bold, text=upper)]
        out += [prose(20, 700 - r * 14, 100, text="filler") for r in range(1, 6)]
        emit_single(out)
    # ... and the *whole* line must be bold, not merely its last run.
    out = [prose(20, 700, 40, bold=0, text="Label"),
           prose(70, 700, 40, bold=1, text=long_text),
           prose(320, 700, 100, bold=0, text=upper)]
    out += [prose(20, 700 - r * 14, 100, text="filler") for r in range(1, 6)]
    emit_single(out)
    # A zero-width run, so the gap is measured from its left edge alone.
    for width in (0, 50, 100):
        out = [prose(20, 700, width, text=long_text), prose(220, 700, 100, text=long_text)]
        out += [prose(20, 700 - r * 14, 100, text="filler") for r in range(1, 6)]
        emit_single(out)
    # An empty column.
    emit_single([])

    # More carriage returns: a run starting left of where the line reached,
    # with several runs already on it.
    for back in (11, 15, 30, 60):
        for runs in (1, 2, 3):
            out = [prose(100 + i * 60, 700, 50, text="r") for i in range(runs)]
            out.append(prose(100 - back, 699, 50, text="b"))
            out += [prose(20, 700 - r * 14, 50, text="c") for r in range(1, 5)]
            emit_single(out)
    # More style-mismatch splits: an all-bold line beside a regular run
    # starting uppercase, and the near misses around it.
    upper2 = "Another~Sentence~Of~Running~Prose"
    for runs, item_bold in [(1, 0), (2, 0), (3, 0), (1, 1), (2, 1)]:
        out = [prose(20 + i * 60, 700, 50, bold=1, text=long_text) for i in range(runs)]
        out.append(prose(20 + runs * 60 + 200, 700, 100, bold=item_bold, text=upper2))
        out += [prose(20, 700 - r * 14, 50, text="c") for r in range(1, 5)]
        emit_single(out)
    # One run of the line not bold, so the whole-line test fails.
    for odd in (0, 1, 2):
        out = [prose(20 + i * 60, 700, 50, bold=0 if i == odd else 1, text=long_text)
               for i in range(3)]
        out.append(prose(400, 700, 100, bold=0, text=upper2))
        out += [prose(20, 700 - r * 14, 50, text="c") for r in range(1, 5)]
        emit_single(out)

    # is_list_marker_column: the 80% bar, and what counts as a marker.
    markers = ["\u2022", "\u25cf", "\u25cb", "\u25e6", "\u25aa",
               "\u25ab", "\u25c6", "\u25c7", "\u25a0", "\u25a1"]
    lines.append("L -")
    for marker in markers:
        lines.append("L " + marker)
        # A marker glued to its text is not a standalone marker.
        lines.append("L " + marker + "item")
        lines.append("L ~" + marker + "~")
    for count in range(1, 11):
        row = ["\u2022"] * count + ["text"] * (10 - count)
        lines.append("L " + " ".join(row))
    # Near neighbours that are not on the list.
    for other in ["-", "*", "\u00b7", "\u2023", "\u2043", "\u25cf\u25cf", "1.", ""]:
        lines.append("L " + (other if other else "~"))

    # spans_multiple_columns: the 10%-of-width and the 20pt rules, and the
    # estimated width when none was measured.
    for width in (0, 10, 30, 60, 120, 300):
        for x in (0, 45, 90, 140, 300, 500):
            lines.append(f"S {x} {width} 12 Heading | 0 300 320 612")
    # A narrow column where 10% is under 20pt, and a wide one where it is over.
    for x in (0, 90, 150, 250):
        lines.append(f"S {x} 40 12 T | 0 100 110 200 210 300")
        lines.append(f"S {x} 40 12 T | 0 500 510 1000")
    # No columns, one column, and zero-width columns.
    lines.append("S 0 100 12 T |")
    lines.append("S 0 100 12 T | 0 300")
    lines.append("S 0 100 12 T | 50 50 60 60")

    # is_page_number: the digit rule and the two bands.
    for text in ("1", "12", "123", "1234", "12345", "0", "007", "1a", "a",
                 "1~2", "~7~", "-1", "1.", "\u00b9", "\uff11"):
        for y in (0.0, 99.0, 100.0, 101.0, 400.0, 719.0, 720.0, 721.0, 900.0):
            lines.append(f"P {y} {text}")

    return lines


def cffname_cases(random_count):
    """Cases for the CFF Name INDEX reader.

    A well-formed case is built from the pieces the reader looks at --
    header size, INDEX count, offset size, the offsets themselves -- and
    then each of those is varied off its valid value, because every early
    return in the function is one of those checks failing.
    """
    rng = random.Random(60_2026)

    def build(name, header_size=4, count=1, off_size=1, major=1,
              extra_names=(), first_offset=1, trailing=b"", pad=b""):
        names = [name] + list(extra_names)
        header = bytes([major, 0, header_size, off_size])
        header += bytes(max(header_size - 4, 0))
        body = bytes([count >> 8, count & 0xFF, off_size])
        offsets = [first_offset]
        for entry in names:
            offsets.append(offsets[-1] + len(entry))
        # The offset array is `count + 1` entries whatever `names` holds, so
        # a mismatched count truncates or over-reads it on purpose.
        wanted = count + 1
        while len(offsets) < wanted:
            offsets.append(offsets[-1])
        for value in offsets[:wanted]:
            # An illegal offset size still has to produce bytes, so the value
            # is truncated rather than the case being dropped -- the point of
            # those cases is that the reader rejects the size before reading.
            width = max(off_size, 1)
            body += (value % (1 << (8 * width))).to_bytes(width, "big")
        for entry in names:
            body += entry
        return header + body + trailing + pad

    lines = []

    def emit(blob):
        lines.append(blob.hex())

    # The ordinary shape, and the subset-tagged name the function exists for.
    emit(build(b"Amplitude-LightItalic"))
    emit(build(b"XXXXXX+Amplitude-LightItalic"))
    emit(build(b"ABCDEF+Helvetica-BoldOblique"))
    emit(build(b"Tc1"))
    emit(build(b""))

    # Header size drives every subsequent index, so it is varied widely --
    # including past the end of the data.
    for header_size in (0, 1, 2, 3, 4, 5, 8, 16, 40, 255):
        emit(build(b"Roman", header_size=header_size))

    # Offset size 1..4 are legal, 0 and 5 are not.
    for off_size in (0, 1, 2, 3, 4, 5, 255):
        emit(build(b"Nimbus-Medi", off_size=off_size))

    # Count zero is an empty INDEX; a large count runs the offset array off
    # the end; a count larger than the names present shifts the object base.
    for count in (0, 1, 2, 3, 7, 255, 65535):
        emit(build(b"Cardo-Italic", count=count, extra_names=(b"Second",)))

    # Offsets are 1-based, so 0 is the rejected value and anything below the
    # first offset makes an inverted range.
    for first in (0, 1, 2, 5, 100, 65535):
        emit(build(b"Slanted", first_offset=first))

    # A major version other than 1 is rejected outright.
    for major in (0, 1, 2, 255):
        emit(build(b"Vera-Bold", major=major))

    # Truncation at every length, which is where the bounds checks live.
    full = build(b"Charter-BoldItalic")
    for length in range(len(full) + 1):
        emit(full[:length])

    # A name whose bytes are not UTF-8 -- the reference is lossy rather than
    # rejecting, so the answer is replacement characters.
    emit(build(bytes([0xFF, 0xFE, 0x41, 0x80])))
    emit(build("Ubuntu-Kursiv\u00e9".encode("utf-8")))

    # Real sfnt and OpenType headers, which must be refused: they are what
    # the deferred TrueType branch would take.
    emit(bytes([0x00, 0x01, 0x00, 0x00]) + bytes(40))
    emit(b"OTTO" + bytes(40))
    emit(b"true" + bytes(40))
    emit(b"ttcf" + bytes(40))
    emit(b"")

    # Multi-byte offset sizes with a name past 255 bytes, so the high bytes
    # of the offsets actually carry information.
    emit(build(b"L" * 300, off_size=2))
    emit(build(b"L" * 300, off_size=3))
    emit(build(b"L" * 70000, off_size=3))

    # Random blobs, some starting with the valid major version so they reach
    # further into the function than the first check.
    for _ in range(random_count):
        length = rng.randrange(0, 48)
        blob = bytes(rng.randrange(0, 256) for _ in range(length))
        if blob and rng.random() < 0.7:
            blob = bytes([1]) + blob[1:]
        emit(blob)

    return lines


def singlebyte_cases(random_count):
    """Cases for the single-byte decoding fallbacks."""
    rng = random.Random(59_2026)

    def h(text):
        return text.encode("utf-8").hex()

    def hb(values):
        return bytes(values).hex()

    lines = []

    # Every byte, both with and without the Windows-1252 reading.
    for flag in (0, 1):
        for start in range(0, 256, 16):
            lines.append(f"B {hb(range(start, start + 16))} {flag}")

    # C1 normalisation over text that reached the C1 block some other way.
    for text in ["a\u0080b", "\u0092quoted\u0093", "plain", "\u0081\u008d\u009d"]:
        for flag in (0, 1):
            lines.append(f"N {h(text)} {flag}")

    # Which fonts get the Windows-1252 reading.
    fonts = ["-", "Helvetica", "ABCDEF+Helvetica", "CMR10", "ABCDEF+CMR10", "cmr10",
             "TeXCMMathsSymbols", "Symbol", "Wingdings", "ZapfDingbats", "MathJax",
             "NotoEmoji", "DingbatsX", "ecrm1000", "msam10", "ttdc", "A+B+CMR10",
             "SymbolMT", "Arial"]
    for font in fonts:
        for cid in (0, 1):
            lines.append(f"U {'-' if font == '-' else h(font)} {cid}")

    # The private-use fold, across the whole range.
    for text in ["\uf0a1", "\uf0a7", "\uf0b7", "\uf0fc", "\uf041", "\uf020", "\uf01f",
                 "\uf000", "\uf0ff", "plain", "a\uf041b"]:
        lines.append(f"P {h(text)}")

    # The symbol fallback.
    for name in ["-", "Symbol", "Wingdings", "ZapfDingbats", "SymbolMT", "Helvetica"]:
        for payload in [[0x41, 0x42], [0x00, 0x1F], [], [0x20, 0xFF]]:
            lines.append(f"S {hb(payload)} {'-' if name == '-' else h(name)}")

    # Scoring.
    scored = ["", "the quick brown fox is in a box", "aaaaaaaaaaaaaaaaaaaa", "12345",
              "\ufffd\ufffd\ufffd", "\u65e5\u672c\u8a9e\u3042\u30a2",
              "de\u2026ciente", "a b c d e", "THE AND OF", "x" * 16]
    for text in scored:
        lines.append(f"T {h(text)}")

    # Choosing between two decodings.
    pairs = [("", ""), ("the and of", ""), ("", "the and of"),
             ("the and of to in", "xxxxxxxxxxxxxxxxxxxx"),
             ("xxxxxxxxxxxxxxxxxxxx", "the and of to in"),
             ("abc", "abd")]
    for a, b in pairs:
        lines.append(f"C {h(a)} {h(b)}")

    alphabet = "abc \u0080\u0092\uf041\ufffd\u65e5123"
    for _ in range(random_count):
        text = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 24)))
        lines.append(f"T {h(text)}")
        lines.append(f"P {h(text)}")
        lines.append(f"N {h(text)} {rng.randint(0, 1)}")

    return lines


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

    gb_blocks = gridbuild_cases(arguments.cases)
    with open(os.path.join(arguments.directory, "gridbuild-cases.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(gb_blocks) + "\n")
    gb_answers = []
    for b in gb_blocks:
        r = subprocess.run(
            [probe, "--gridbuild"], input=b + "\n", capture_output=True, text=True, check=True
        )
        gb_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "gridbuild-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(gb_answers))

    cr_answers = []
    for b in gb_blocks:
        r = subprocess.run(
            [probe, "--cellrows"], input=b + "\n", capture_output=True, text=True, check=True
        )
        cr_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "cellrows-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(cr_answers))

    rt_answers = []
    for b in gb_blocks:
        r = subprocess.run(
            [probe, "--recttables"], input=b + "\n", capture_output=True, text=True, check=True
        )
        rt_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "recttables-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(rt_answers))

    cs_answers = []
    for b in gb_blocks:
        r = subprocess.run(
            [probe, "--cellstripe"], input=b + "\n", capture_output=True, text=True, check=True
        )
        cs_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "cellstripe-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(cs_answers))

    co_blocks = collapse_cases(max(arguments.cases // 2, 60))
    with open(os.path.join(arguments.directory, "collapse-cases.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(co_blocks))
    co_answers = []
    for b in co_blocks:
        r = subprocess.run(
            [probe, "--collapse"], input=b + "\n", capture_output=True, text=True, check=True
        )
        co_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "collapse-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(co_answers))

    prep_answers = []
    for b in gb_blocks:
        r = subprocess.run(
            [probe, "--prepare"], input=b + "\n", capture_output=True, text=True, check=True
        )
        prep_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "prepare-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(prep_answers))

    stack_answers = []
    for b in gb_blocks:
        r = subprocess.run(
            [probe, "--stripe"], input=b + "\n", capture_output=True, text=True, check=True
        )
        stack_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "stack-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(stack_answers))

    stripe_answers = []
    for b in gb_blocks:
        r = subprocess.run(
            [probe, "--stripe"], input=b + "\n", capture_output=True, text=True, check=True
        )
        stripe_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "stripe-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(stripe_answers))

    cls_answers = []
    for b in gb_blocks:
        r = subprocess.run(
            [probe, "--classify"], input=b + "\n", capture_output=True, text=True, check=True
        )
        cls_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "classify-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(cls_answers))

    assign_blocks = assign_cases(arguments.cases)
    with open(os.path.join(arguments.directory, "assign-cases.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(assign_blocks) + "\n")
    assign_answers = []
    for b in assign_blocks:
        r = subprocess.run(
            [probe, "--assign"], input=b + "\n", capture_output=True, text=True, check=True
        )
        assign_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "assign-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(assign_answers))

    rect_blocks = rect_cases(arguments.cases)
    with open(os.path.join(arguments.directory, "rect-cases.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(rect_blocks) + "\n")
    rect_answers = []
    for b in rect_blocks:
        r = subprocess.run(
            [probe, "--rects"], input=b + "\n", capture_output=True, text=True, check=True
        )
        rect_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "rect-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(rect_answers))

    hyp_blocks = hypothesis_cases(arguments.cases)
    with open(os.path.join(arguments.directory, "hyp-cases.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(hyp_blocks) + "\n")
    hyp_answers = []
    for b in hyp_blocks:
        r = subprocess.run(
            [probe, "--hyp"], input=b + "\n", capture_output=True, text=True, check=True
        )
        hyp_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "hyp-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(hyp_answers))

    rule_blocks = rule_cases(arguments.cases)
    sb_blocks = structtable_cases(max(arguments.cases // 4, 80))
    with open(os.path.join(arguments.directory, "structtable-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(sb_blocks))
    sb_answers = []
    for b in sb_blocks:
        r = subprocess.run(
            [probe, "--structtables"], input=b + "\n", capture_output=True, text=True,
            check=True
        )
        sb_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "structtable-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(sb_answers))

    sh_blocks = structheader_cases(max(arguments.cases // 4, 80))
    with open(os.path.join(arguments.directory, "structheader-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(sh_blocks))
    sh_answers = []
    for b in sh_blocks:
        r = subprocess.run(
            [probe, "--structheader"], input=b + "\n", capture_output=True, text=True,
            check=True
        )
        sh_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "structheader-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(sh_answers))

    sr_blocks = structrow_cases(max(arguments.cases // 4, 80))
    with open(os.path.join(arguments.directory, "structrow-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(sr_blocks))
    sr_answers = []
    for b in sr_blocks:
        r = subprocess.run(
            [probe, "--structrows"], input=b + "\n", capture_output=True, text=True,
            check=True
        )
        sr_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "structrow-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(sr_answers))

    sc_blocks = structcol_cases(max(arguments.cases // 4, 80))
    with open(os.path.join(arguments.directory, "structcol-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(sc_blocks))
    sc_answers = []
    for b in sc_blocks:
        r = subprocess.run(
            [probe, "--structcols"], input=b + "\n", capture_output=True, text=True,
            check=True
        )
        sc_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "structcol-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(sc_answers))

    st_blocks = structtree_cases(max(arguments.cases // 4, 60))
    with open(os.path.join(arguments.directory, "structtree-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(st_blocks))
    st_answers = []
    for b in st_blocks:
        r = subprocess.run(
            [probe, "--structtree"], input=b + "\n", capture_output=True, text=True,
            check=True
        )
        st_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "structtree-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(st_answers))

    sn_lines = structname_cases(max(arguments.cases // 3, 100))
    with open(os.path.join(arguments.directory, "structname-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(sn_lines))
    r = subprocess.run(
        [probe, "--structnames"], input="\n".join(sn_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "structname-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    jn_lines = join_cases(max(arguments.cases // 2, 200))
    with open(os.path.join(arguments.directory, "join-cases.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(jn_lines))
    r = subprocess.run(
        [probe, "--join"], input="\n".join(jn_lines) + "\n", capture_output=True, text=True,
        check=True
    )
    with open(os.path.join(arguments.directory, "join-rust.txt"), "w", encoding="utf-8") as f:
        f.write(r.stdout)

    ls_blocks = letterspacing_cases(max(arguments.cases // 4, 60))
    with open(os.path.join(arguments.directory, "letterspacing-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(ls_blocks))
    ls_answers = []
    for b in ls_blocks:
        r = subprocess.run(
            [probe, "--letterspacing"], input=b + "\n", capture_output=True, text=True,
            check=True
        )
        ls_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "letterspacing-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(ls_answers))

    sb_lines = singlebyte_cases(max(arguments.cases // 6, 60))
    with open(os.path.join(arguments.directory, "singlebyte-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(sb_lines))
    r = subprocess.run(
        [probe, "--singlebyte"], input="\n".join(sb_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "singlebyte-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    wr_lines = wrapped_cases(max(arguments.cases // 4, 100))
    with open(os.path.join(arguments.directory, "wrapped-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(wr_lines))
    r = subprocess.run(
        [probe, "--wrapped"], input="\n".join(wr_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "wrapped-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    cx2_lines = complexity_cases(max(arguments.cases // 16, 30))
    with open(os.path.join(arguments.directory, "complexity-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(cx2_lines))
    r = subprocess.run(
        [probe, "--complexity"], input="\n".join(cx2_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "complexity-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    wt_lines = writer_cases(max(arguments.cases // 8, 60))
    with open(os.path.join(arguments.directory, "writer-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(wt_lines))
    r = subprocess.run(
        [probe, "--writer"], input="\n".join(wt_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "writer-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    pl_lines = prologue_cases(max(arguments.cases // 8, 60))
    with open(os.path.join(arguments.directory, "prologue-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(pl_lines))
    r = subprocess.run(
        [probe, "--prologue"], input="\n".join(pl_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "prologue-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    pr_lines = preprocess_cases(max(arguments.cases // 8, 60))
    with open(os.path.join(arguments.directory, "preprocess2-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(pr_lines))
    r = subprocess.run(
        [probe, "--preprocess"], input="\n".join(pr_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "preprocess2-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    po_lines = positioned_cases(max(arguments.cases // 8, 60))
    with open(os.path.join(arguments.directory, "positioned-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(po_lines))
    r = subprocess.run(
        [probe, "--positioned"], input="\n".join(po_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "positioned-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    is_lines = isolated_cases(max(arguments.cases // 4, 100))
    with open(os.path.join(arguments.directory, "isolated-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(is_lines))
    r = subprocess.run(
        [probe, "--isolated"], input="\n".join(is_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "isolated-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    cx_lines = chart_text_cases(max(arguments.cases // 4, 100))
    with open(os.path.join(arguments.directory, "charttext-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(cx_lines))
    r = subprocess.run(
        [probe, "--charttext"], input="\n".join(cx_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "charttext-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    ct_lines = chart_cases(max(arguments.cases // 4, 100))
    with open(os.path.join(arguments.directory, "chart-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(ct_lines))
    r = subprocess.run(
        [probe, "--chart"], input="\n".join(ct_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "chart-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    nb_lines = numbering_cases(max(arguments.cases // 4, 100))
    with open(os.path.join(arguments.directory, "numbering-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(nb_lines))
    r = subprocess.run(
        [probe, "--numbering"], input="\n".join(nb_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "numbering-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    pp_lines = postprocess_cases(max(arguments.cases // 2, 200))
    with open(os.path.join(arguments.directory, "postprocess-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(pp_lines))
    r = subprocess.run(
        [probe, "--postprocess"], input="\n".join(pp_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "postprocess-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    hd_lines = heading_cases(max(arguments.cases // 5, 60))
    with open(os.path.join(arguments.directory, "heading-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(hd_lines))
    r = subprocess.run(
        [probe, "--heading"], input="\n".join(hd_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "heading-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    rd_lines = reading_cases(max(arguments.cases // 6, 40))
    with open(os.path.join(arguments.directory, "reading-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(rd_lines))
    r = subprocess.run(
        [probe, "--reading"], input="\n".join(rd_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "reading-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    vl_lines = valley_cases(max(arguments.cases // 4, 80))
    with open(os.path.join(arguments.directory, "valley-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(vl_lines))
    r = subprocess.run(
        [probe, "--valleys"], input="\n".join(vl_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "valley-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    cf_lines = cffname_cases(max(arguments.cases // 3, 120))
    with open(os.path.join(arguments.directory, "cffname-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(cf_lines))
    r = subprocess.run(
        [probe, "--cffname"], input="\n".join(cf_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "cffname-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    df_lines = difference_cases(max(arguments.cases // 3, 100))
    with open(os.path.join(arguments.directory, "difference-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(df_lines))
    r = subprocess.run(
        [probe, "--differences"], input="\n".join(df_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "difference-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    reference = os.path.join(
        os.path.expanduser("~"),
        ".cargo/registry/src/index.crates.io-1949cf8c6b5b557f/pdf-inspector-0.1.7",
        "src/glyph_names.rs")
    if os.path.exists(reference):
        gn_lines = glyphname_cases(reference)
        with open(os.path.join(arguments.directory, "glyphname-cases.txt"), "w",
                  encoding="utf-8") as f:
            f.write("\n".join(gn_lines))
        r = subprocess.run(
            [probe, "--glyphnames"], input="\n".join(gn_lines) + "\n", capture_output=True,
            text=True, check=True
        )
        with open(os.path.join(arguments.directory, "glyphname-rust.txt"), "w",
                  encoding="utf-8") as f:
            f.write(r.stdout)

    lg_lines = ligature_cases(max(arguments.cases // 3, 100))
    with open(os.path.join(arguments.directory, "ligature-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(lg_lines))
    r = subprocess.run(
        [probe, "--ligatures"], input="\n".join(lg_lines) + "\n", capture_output=True,
        text=True, check=True
    )
    with open(os.path.join(arguments.directory, "ligature-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write(r.stdout)

    bd_blocks = bidi_cases(max(arguments.cases // 3, 80))
    with open(os.path.join(arguments.directory, "bidi-cases.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(bd_blocks))
    bd_answers = []
    for b in bd_blocks:
        r = subprocess.run(
            [probe, "--bidi"], input=b + "\n", capture_output=True, text=True, check=True
        )
        bd_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "bidi-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(bd_answers))

    tq_blocks = textquality_cases(max(arguments.cases // 3, 80))
    with open(os.path.join(arguments.directory, "textquality-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(tq_blocks))
    tq_answers = []
    for b in tq_blocks:
        r = subprocess.run(
            [probe, "--textquality"], input=b + "\n", capture_output=True, text=True, check=True
        )
        tq_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "textquality-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(tq_answers))

    dt_blocks = detector_cases(max(arguments.cases // 3, 80))
    with open(os.path.join(arguments.directory, "detector-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(dt_blocks))
    dt_answers = []
    for b in dt_blocks:
        r = subprocess.run(
            [probe, "--detector"], input=b + "\n", capture_output=True, text=True, check=True
        )
        dt_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "detector-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(dt_answers))

    lt_blocks = linetable_cases(max(arguments.cases // 4, 60))
    with open(os.path.join(arguments.directory, "linetable-cases.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(lt_blocks))
    lt_answers = []
    for b in lt_blocks:
        r = subprocess.run(
            [probe, "--linetables"], input=b + "\n", capture_output=True, text=True, check=True
        )
        lt_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "linetable-rust.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n===\n".join(lt_answers))

    oe_blocks = openedge_cases(max(arguments.cases // 4, 60))
    with open(os.path.join(arguments.directory, "openedge-cases.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(oe_blocks))
    oe_answers = []
    for b in oe_blocks:
        r = subprocess.run(
            [probe, "--openedge"], input=b + "\n", capture_output=True, text=True, check=True
        )
        oe_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "openedge-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(oe_answers))

    an_answers = []
    for b in rule_blocks:
        r = subprocess.run(
            [probe, "--anchors"], input=b + "\n", capture_output=True, text=True, check=True
        )
        an_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "anchors-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(an_answers))

    with open(os.path.join(arguments.directory, "rules-cases.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(rule_blocks) + "\n")
    rule_answers = []
    for b in rule_blocks:
        r = subprocess.run(
            [probe, "--rules"], input=b + "\n", capture_output=True, text=True, check=True
        )
        rule_answers.append(r.stdout)
    with open(os.path.join(arguments.directory, "rules-rust.txt"), "w", encoding="utf-8") as f:
        f.write("\n===\n".join(rule_answers))

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
