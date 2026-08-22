#!/usr/bin/env python3
"""Per-format conversion timings for the release CLI.

§5.6 sets the targets — median within 1.5× the Rust median after the Phase 7
pass, peak RSS within 1.5× — and none of that can be worked on before it is
measured. This reports median and p95 wall time per format over the fixture
corpus, plus peak RSS, from warm runs.

    scripts/bench.py <fixture-dir> [--runs N] [--json out.json]

Timing a whole process includes ~1-2 ms of spawn and dynamic linking on every
sample. That overhead is constant, so it inflates the small formats' medians
most; the number to compare across runs is the same-harness delta, not the
absolute. `--baseline` prints the spawn cost so it can be read off.
"""
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

CLI = ".build/release/anydoc-cli"


def time_file(path: Path, runs: int) -> tuple[float, float, float] | None:
    """Median, p95 and best of `runs` in-process conversions, in ms.

    `--bench` does the loop inside one process. Timing a process per
    conversion cannot work here: fork, exec and dynamic linking cost ~12.8 ms
    on this machine, three times the entire Rust median being compared
    against, so every format but PDF measured as zero.
    """
    result = subprocess.run([CLI, str(path), "--bench", str(runs)],
                            capture_output=True, check=False)
    if result.returncode != 0:
        return None
    parts = result.stdout.decode(errors="replace").split()
    if len(parts) != 3:
        return None
    return tuple(float(p) for p in parts)  # type: ignore[return-value]


def peak_rss_kb(path: Path) -> int:
    """Peak resident set of one conversion, via the shell's own timer."""
    result = subprocess.run(
        ["/usr/bin/time", "-l", CLI, str(path)],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=False)
    for line in result.stderr.decode(errors="replace").splitlines():
        if "maximum resident set size" in line:
            return int(line.strip().split()[0]) // 1024
    return 0


def main(fixtures: str, runs: int, out_json: str | None) -> None:
    files = sorted(p for p in Path(fixtures).rglob("*") if p.is_file()
                   and p.suffix.lower() not in {".md", ""} and "abuse" not in p.parts)
    if not files:
        raise SystemExit(f"no fixtures under {fixtures}")

    by_format: dict[str, list[float]] = {}
    rss: dict[str, list[int]] = {}
    skipped = 0
    for path in files:
        extension = path.suffix.lower().lstrip(".")
        timing = time_file(path, runs)
        if timing is None:          # a fixture the converter refuses by design
            skipped += 1
            continue
        median, _p95, best = timing
        by_format.setdefault(extension, []).append(median)
        rss.setdefault(extension, []).append(peak_rss_kb(path))

    print(f"{'format':<8} {'files':>6} {'median':>9} {'p95':>9} {'slowest':>9} {'peak RSS':>10}")
    report: dict = {"runs_per_file": runs, "formats": {}}
    for extension in sorted(by_format):
        samples = sorted(by_format[extension])
        median = statistics.median(samples)
        p95 = samples[min(len(samples) - 1, int(len(samples) * 0.95))]
        peak = max(rss[extension])
        print(f"{extension:<8} {len(samples):>6} {median:>8.3f}m {p95:>8.3f}m "
              f"{samples[-1]:>8.3f}m {peak:>9} K")
        report["formats"][extension] = {
            "files": len(samples), "median_ms": median, "p95_ms": p95,
            "slowest_ms": samples[-1], "peak_rss_kb": peak,
        }
    total = sorted(m for s in by_format.values() for m in s)
    overall = statistics.median(total)
    report["overall_median_ms"] = overall
    print(f"{'ALL':<8} {len(total):>6} {overall:>8.3f}m")
    if skipped:
        print(f"({skipped} fixture(s) the converter rejects, excluded)")
    if out_json:
        Path(out_json).write_text(json.dumps(report, indent=2))
        print(f"wrote {out_json}")


if __name__ == "__main__":
    positional = [a for a in sys.argv[1:] if not a.startswith("--")]
    run_count = 5
    json_out = None
    for a in sys.argv[1:]:
        if a.startswith("--runs="):
            run_count = int(a.split("=", 1)[1])
        if a.startswith("--json="):
            json_out = a.split("=", 1)[1]
    if not positional:
        raise SystemExit("usage: bench.py <fixture-dir> [--runs=N] [--json=out.json]")
    main(positional[0], run_count, json_out)
