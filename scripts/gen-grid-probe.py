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
