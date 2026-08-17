#!/usr/bin/env python3
"""Classify reference functions this port has no counterpart for.

Wave 134 counted 241 name-mismatches against the reference and treated the
number as a to-do list. Waves 135 and 136 found that misleading in two
directions: some are renames, and many more are reachable only from public
APIs this port does not implement — the region and structured-cell entry
points in `lib.rs`, which have nothing to do with converting a document to
Markdown.

This walks the reference's call graph from the entry points the port *does*
implement and reports only what is both unmatched and reachable. That is the
list worth working from.

    python3 scripts/find-unported.py <reference-src-dir>
"""
import os
import re
import sys
from collections import defaultdict, deque

REFERENCE = sys.argv[1] if len(sys.argv) > 1 else "reference/src"

# The entry points this port implements: detect, extract, convert.
ROOTS = [
    "process_document",
    "to_markdown_from_items_with_rects_and_lines",
    "extract_positioned_text_from_doc",
    "extract_positioned_text_impl",
    "detect_from_document",
    "analyze_page_content",
]

bodies = {}
for root, _, names in os.walk(REFERENCE):
    for name in names:
        if not name.endswith(".rs"):
            continue
        path = os.path.join(root, name)
        text = open(path).read().split("#[cfg(test)]")[0]
        # Split into function bodies by brace depth, crudely but adequately.
        for match in re.finditer(r"^\s*(?:pub(?:\([a-z()]+\))?\s+)?fn (\w+)", text, re.M):
            start = match.end()
            depth, index, opened = 0, start, False
            while index < len(text):
                if text[index] == "{":
                    depth += 1
                    opened = True
                elif text[index] == "}":
                    depth -= 1
                    if opened and depth == 0:
                        break
                index += 1
            bodies[match.group(1)] = (path[len(REFERENCE) + 1:], text[start:index])

calls = defaultdict(set)
for name, (_, body) in bodies.items():
    for other in bodies:
        if other != name and re.search(r"\b" + other + r"\s*\(", body):
            calls[name].add(other)

reachable, queue = set(), deque(r for r in ROOTS if r in bodies)
reachable.update(queue)
while queue:
    current = queue.popleft()
    for callee in calls[current]:
        if callee not in reachable:
            reachable.add(callee)
            queue.append(callee)

swift = ""
for root, _, names in os.walk("Sources/AnyDoc"):
    for name in names:
        if name.endswith(".swift"):
            swift += open(os.path.join(root, name)).read()
swift = swift.lower()

def matched(name):
    """Whether the Swift sources appear to contain this function.

    **Name matching cannot see a rename**, which is this tool's central
    limitation and the reason its output is a candidate list rather than a
    gap count. Several transforms are tried to cut the obvious false
    positives — the full camel name, the last two words, and a distinctive
    final word — but a function ported under a genuinely different name
    still shows up here. Every candidate needs a look before it is believed.
    """
    words = name.split("_")
    camel = "".join(w.capitalize() if i else w for i, w in enumerate(words))
    if camel.lower() in swift:
        return True
    if len(words) >= 2:
        tail = "".join(w.capitalize() for w in words[-2:])
        if tail.lower() in swift:
            return True
    last = words[-1]
    if len(last) >= 6 and last.lower() in swift:
        return True
    return False


gaps = []
for name, (path, _) in sorted(bodies.items()):
    if name.startswith("probe_"):
        continue
    if matched(name):
        continue
    gaps.append((name, path, name in reachable))

live = [g for g in gaps if g[2]]
print(f"{len(bodies)} reference functions, {len(reachable)} reachable from the ported entry points")
print(f"{len(gaps)} unmatched by name; {len(live)} of those are reachable")
print("Candidates, not gaps: a rename is invisible here. Verify before working.\n")
for name, path, _ in live:
    print(f"  {name}  [{path}]")
