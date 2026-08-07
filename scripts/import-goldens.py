#!/usr/bin/env python3
"""Convert anydoc's committed insta snapshots into plain golden files.

Usage: import-goldens.py <anydoc-checkout>/tests/snapshots <out-dir>

Each `snapshots__<rel__path>.snap` becomes `<rel__path>.golden` holding the
snapshot content with the insta YAML header stripped. Goldens are the byte
truth the Swift snapshot tests compare against (modulo a single trailing
newline, which insta normalizes on save).
"""
import sys
from pathlib import Path

def strip_header(text: str) -> str:
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        raise SystemExit(f"missing insta header in snapshot")
    end = next(i for i in range(1, len(lines)) if lines[i] == "---")
    return "\n".join(lines[end + 1:])

def main(src: str, dst: str) -> None:
    out = Path(dst)
    out.mkdir(parents=True, exist_ok=True)
    count = 0
    for snap in sorted(Path(src).glob("*.snap")):
        name = snap.name.removeprefix("snapshots__").removesuffix(".snap")
        (out / f"{name}.golden").write_text(strip_header(snap.read_text()))
        count += 1
    print(f"wrote {count} goldens to {out}")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
