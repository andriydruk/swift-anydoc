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

    generator = random.Random(4242)
    words = ["a", "bb", "12", "", "3.50", "total"]

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
