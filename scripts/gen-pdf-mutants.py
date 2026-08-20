#!/usr/bin/env python3
"""Deterministic corruption mutants of the generated PDF corpus.

Every other format got a mutation sweep — 650 mutants for `.xls`, 1,050 for
`.xlsx`, 1,075 for `.doc` — and PDF, the largest reader by far, did not. This
builds the same kind of corpus: a fixed number of single-edit mutants per
source document, produced by a seeded xorshift64* so the stream is identical
on every run and on both implementations.

Three edit kinds, chosen because they break different layers:

  * a byte flipped in place — corrupts a token, a length, an offset or a
    stream's compressed payload wherever it lands;
  * a truncation — cuts the file at a point, which is what a failed download
    or a killed writer produces;
  * a run of bytes zeroed — the shape of a partially-written block.

The point is not that the reference and this port produce the *same* text
from a corrupt file. It is that neither crashes, neither hangs, and where the
reference still produces output this port produces the same output. A reader
that invents content from a file the reference refuses is worse than one that
fails.

    scripts/gen-pdf-mutants.py <corpus-dir> <out-dir> [--per-file N]
"""
import sys
from pathlib import Path


class Rand:
    """xorshift64*, the same generator the other sweeps use."""

    def __init__(self, seed: int) -> None:
        self.state = seed & 0xFFFFFFFFFFFFFFFF or 0x9E3779B97F4A7C15

    def next(self) -> int:
        x = self.state
        x ^= (x >> 12) & 0xFFFFFFFFFFFFFFFF
        x ^= (x << 25) & 0xFFFFFFFFFFFFFFFF
        x ^= (x >> 27) & 0xFFFFFFFFFFFFFFFF
        self.state = x & 0xFFFFFFFFFFFFFFFF
        return (self.state * 0x2545F4914F6CDD1D) & 0xFFFFFFFFFFFFFFFF

    def below(self, bound: int) -> int:
        return self.next() % bound if bound > 0 else 0


def mutants(data: bytes, count: int, seed: int):
    rng = Rand(seed)
    for index in range(count):
        kind = rng.below(3)
        out = bytearray(data)
        if kind == 0:                                   # flip one byte
            at = rng.below(len(out))
            out[at] ^= 1 << rng.below(8)
            tag = "flip"
        elif kind == 1:                                 # truncate
            at = rng.below(len(out))
            out = out[:at]
            tag = "trunc"
        else:                                           # zero a run
            at = rng.below(len(out))
            run = min(len(out) - at, 1 + rng.below(64))
            out[at:at + run] = b"\x00" * run
            tag = "zero"
        yield index, tag, bytes(out)


def main(corpus: str, out: str, per_file: int) -> None:
    destination = Path(out)
    destination.mkdir(parents=True, exist_ok=True)
    written = 0
    # Sorted, so the same corpus always yields the same mutant set.
    for source in sorted(Path(corpus).glob("*.pdf")):
        data = source.read_bytes()
        if not data:
            continue
        # Seed from the name, so adding a document does not renumber the rest.
        seed = int.from_bytes(source.name.encode()[:8].ljust(8, b"\x00"), "big")
        for index, tag, payload in mutants(data, per_file, seed):
            (destination / f"{source.stem}--{tag}{index:03d}.pdf").write_bytes(payload)
            written += 1
    print(f"wrote {written} mutants to {destination}")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    per = 8
    for a in sys.argv[1:]:
        if a.startswith("--per-file"):
            per = int(a.split("=", 1)[1]) if "=" in a else per
    if len(args) < 2:
        raise SystemExit("usage: gen-pdf-mutants.py <corpus-dir> <out-dir> [--per-file=N]")
    main(args[0], args[1], per)
