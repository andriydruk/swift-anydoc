#!/bin/sh
# Generate the NFKC tables in Sources/AnyDoc/Pdf/PdfNfkcTables.swift.
#
# The tables are dumped from `unicode-normalization`, the crate the reference
# itself uses, rather than from Python's `unicodedata` — those are different
# Unicode versions (17.0 against 13.0), and a table generated from the wrong
# one would diverge from the reference on anything added or changed between
# them. Asking the reference's own dependency is the only way to be exact.
#
# Hangul is left out deliberately: its decomposition and composition are
# arithmetic, so 11,172 syllables would otherwise dominate the table for no
# information at all. `PdfNfkc.swift` implements that arithmetic.
#
#   scripts/gen-nfkc-tables.sh <work-dir>
set -eu

if [ $# -lt 1 ]; then
    echo "usage: $0 <work-dir>" >&2
    exit 2
fi
work=$1
mkdir -p "$work"
crate=$work/nfkcdump
mkdir -p "$crate/src"

cat > "$crate/Cargo.toml" <<'EOF'
[package]
name = "nfkcdump"
version = "0.1.0"
edition = "2021"

[dependencies]
unicode-normalization = "0.1"
EOF

cat > "$crate/src/main.rs" <<'EOF'
// Dump the tables an NFKC implementation needs, straight from the crate the
// reference uses.
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::canonical_combining_class;

const HANGUL_S_BASE: u32 = 0xAC00;
const HANGUL_S_COUNT: u32 = 11172;

fn is_hangul_syllable(cp: u32) -> bool {
    (HANGUL_S_BASE..HANGUL_S_BASE + HANGUL_S_COUNT).contains(&cp)
}

fn main() {
    println!("VERSION {:?}", unicode_normalization::UNICODE_VERSION);

    // Full compatibility decomposition, per codepoint.
    for cp in 0..0x110000u32 {
        if is_hangul_syllable(cp) {
            continue;
        }
        let Some(ch) = char::from_u32(cp) else { continue };
        let decomposed: String = std::iter::once(ch).nfkd().collect();
        if decomposed.chars().count() == 1 && decomposed.chars().next() == Some(ch) {
            continue;
        }
        print!("D {cp:X}");
        for c in decomposed.chars() {
            print!(" {:X}", c as u32);
        }
        println!();
    }

    // Canonical combining classes.
    for cp in 0..0x110000u32 {
        let Some(ch) = char::from_u32(cp) else { continue };
        let ccc = canonical_combining_class(ch);
        if ccc != 0 {
            println!("C {cp:X} {ccc}");
        }
    }

    // Every codepoint's NFKC, for the differential probe. Printed as hex so
    // lone surrogates and control characters survive the round trip.
    for cp in 0..0x110000u32 {
        let Some(ch) = char::from_u32(cp) else { continue };
        let normalized: String = std::iter::once(ch).nfkc().collect();
        print!("N {cp:X}");
        for c in normalized.chars() {
            print!(" {:X}", c as u32);
        }
        println!();
    }

    // Multi-scalar sequences. Single codepoints never exercise canonical
    // ordering or composition blocking, which is where the interesting bugs
    // live: a run of combining marks has to sort stably by class, and a mark
    // may be blocked from its starter by another mark of equal or higher
    // class standing between them.
    let starters: &[u32] = &[
        0x41, 0x55, 0x61, 0x6F, 0x391, 0x627, 0x628, 0x1100, 0xAC00, 0xAC01, 0x4E00,
        0xFB50, 0xFE70, 0x1D5, 0xDC, 0x212B, 0x2126, 0xFDFA, 0x1F1E6, 0x20000,
    ];
    let marks: &[u32] = &[
        0x300, 0x301, 0x304, 0x308, 0x30C, 0x323, 0x327, 0x334, 0x591, 0x5B0, 0x64B,
        0x654, 0x655, 0x1161, 0x11A8, 0x3099, 0x200D, 0x20, 0x41,
    ];
    let mut seed: u64 = 0x5EED_1234_ABCD_0001;
    let mut next = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    for _ in 0..4000 {
        let length = 2 + (next() % 5) as usize;
        let mut sequence: Vec<char> = Vec::new();
        for position in 0..length {
            let value = if position == 0 || next() % 3 == 0 {
                starters[(next() as usize) % starters.len()]
            } else {
                marks[(next() as usize) % marks.len()]
            };
            if let Some(c) = char::from_u32(value) {
                sequence.push(c);
            }
        }
        let normalized: String = sequence.iter().copied().nfkc().collect();
        print!("S");
        for c in &sequence {
            print!(" {:X}", *c as u32);
        }
        print!(" |");
        for c in normalized.chars() {
            print!(" {:X}", c as u32);
        }
        println!();
    }

    // Canonical composition pairs.
    //
    // These come from the *one-step* canonical decomposition, not the full
    // NFD. U+01D5 decomposes fully to three scalars (U, diaeresis, macron)
    // but composes from two (U+00DC, macron), so reading pairs off the full
    // decomposition misses it — and every other multiply-accented letter with
    // it. The one-step form is recovered by recomposing everything but the
    // final mark and checking the whole thing round-trips; a composite on the
    // exclusion list fails that check, so the list is never needed.
    for cp in 0..0x110000u32 {
        if is_hangul_syllable(cp) {
            continue;
        }
        let Some(ch) = char::from_u32(cp) else { continue };
        let decomposed: Vec<char> = std::iter::once(ch).nfd().collect();
        if decomposed.len() < 2 {
            continue;
        }
        let head: Vec<char> = decomposed[..decomposed.len() - 1]
            .iter()
            .copied()
            .nfc()
            .collect();
        if head.len() != 1 {
            continue;
        }
        let last = decomposed[decomposed.len() - 1];
        let recomposed: Vec<char> = [head[0], last].iter().copied().nfc().collect();
        if recomposed.len() == 1 && recomposed[0] == ch {
            println!("P {:X} {:X} {:X}", head[0] as u32, last as u32, cp);
        }
    }
}
EOF

(cd "$crate" && cargo build --release --offline >/dev/null 2>&1) || {
    echo "nfkcdump failed to build (needs unicode-normalization in the local registry)" >&2
    exit 1
}
"$crate/target/release/nfkcdump" > "$work/nfkc-dump.txt"
python3 "$(dirname "$0")/gen-nfkc-tables.py" "$work/nfkc-dump.txt"
