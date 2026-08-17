#!/usr/bin/env python3
"""List ported functions with no caller anywhere in Sources/.

The connection gap — a component ported, probed, and never called — is this
port's most-repeated defect, found ten times through wave 116 and always by
accident. This makes looking for it cheap and repeatable.

A name here is not necessarily a bug: most are waiting on a consumer that is
genuinely unported (chart regions, the detector's document half, OCR). The
list is a starting point for asking "why not?", not a defect report.

    python3 scripts/find-orphans.py [source-dir]
"""
import os
import re
import sys

directory = sys.argv[1] if len(sys.argv) > 1 else "Sources/AnyDoc/Pdf"

declarations = {}
for name in sorted(os.listdir(directory)):
    if not name.endswith(".swift"):
        continue
    text = open(os.path.join(directory, name)).read()
    for match in re.finditer(r"^(?:private |internal )?func (pdf\w+)", text, re.M):
        declarations.setdefault(match.group(1), name)

sources = {}
for root, _, names in os.walk("Sources"):
    for name in names:
        if name.endswith(".swift"):
            path = os.path.join(root, name)
            sources[path] = open(path).read()

orphans = []
for function, home in sorted(declarations.items()):
    uses = 0
    for path, text in sources.items():
        found = len(re.findall(r"\b" + function + r"\b", text))
        # The declaration itself is not a use.
        uses += found - 1 if os.path.basename(path) == home else found
    if uses <= 0:
        orphans.append((function, home))

print(f"{len(declarations)} functions, {len(orphans)} with no caller in Sources/\n")
for function, home in orphans:
    print(f"  {function}  [{home}]")
