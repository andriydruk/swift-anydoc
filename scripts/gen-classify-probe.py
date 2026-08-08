#!/usr/bin/env python3
"""Build the differential probe for the PDF line classifiers.

The predicates in `Sources/AnyDoc/Pdf/PdfClassify.swift` and the font-name
heuristics in `PdfFontStyle.swift` are short enough to look obviously correct
and are not: each decides its edges by accident of how the Rust was written —
an `all()` over an empty slice that returns true, a byte-length bound, a
`strip_prefix` that does not require the space it appears to. Swift makes it
worse, because `String` compares grapheme clusters where Rust compares bytes,
so `Courier` followed by a combining mark stops containing `courier`.

This extracts the reference's own functions verbatim into a small Rust binary,
generates a corpus weighted towards exactly those edges, and writes the
oracle's answers. `PdfClassifyProbeTests` then compares.

    python3 scripts/gen-classify-probe.py <output-dir> [--cases N]
    ANYDOC_CLASSIFY_PROBE=<output-dir> swift test --filter PdfClassifyProbe

Requires cargo and a local pdf-inspector 0.1.7 in the cargo registry.
"""

import argparse
import glob
import os
import random
import subprocess
import sys

REGISTRY = os.path.expanduser("~/.cargo/registry/src/*/pdf-inspector-0.1.7/src")


def reference_source():
    matches = glob.glob(REGISTRY)
    if not matches:
        sys.exit(
            "pdf-inspector-0.1.7 not found in the cargo registry.\n"
            "Fetch it with: cargo add pdf-inspector@0.1.7 (in a scratch crate)"
        )
    return matches[0]


def extract(path, start, end):
    """The text from `start` up to `end`, both located as literal markers."""
    text = open(path, encoding="utf-8").read()
    begin = text.index(start)
    return text[begin : text.index(end, begin)]


def write_probe(reference, directory):
    """A Rust binary wrapping the reference's classifiers, unmodified."""
    src = os.path.join(directory, "classifyprobe", "src")
    os.makedirs(src, exist_ok=True)

    classify = extract(
        os.path.join(reference, "markdown", "classify.rs"),
        "//! Line classification",
        "#[cfg(test)]",
    ).replace("pub(crate) fn", "pub fn")
    leaders = extract(
        os.path.join(reference, "markdown", "analysis.rs"),
        "pub(crate) fn has_dot_leaders",
        "/// Detect a table-of-contents entry",
    ).replace("pub(crate) fn", "pub fn")
    fonts = extract(
        os.path.join(reference, "text_utils.rs"),
        "pub fn is_bold_font",
        "/// Expand Unicode ligature",
    )

    # Probe strings are escaped so any byte rides on one line, and `|`
    # separates the output's fields.
    harness = r"""
use std::io::{self, Read, Write};

fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let out = io::stdout();
    let mut out = out.lock();
    for line in input.split('\n') {
        if line.is_empty() { continue }
        let text: String = unescape(line);
        writeln!(out, "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}",
            line,
            is_caption_line(&text) as u8,
            starts_with_bullet_marker(&text) as u8,
            is_list_item(&text) as u8,
            escape(&format_list_item(&text)),
            is_code_like(&text) as u8,
            is_monospace_font(&text) as u8,
            has_dot_leaders(&text) as u8,
            is_bold_font(&text) as u8,
            is_italic_font(&text) as u8).unwrap();
    }
}

fn escape(s: &str) -> String {
    s.chars().map(|c| match c {
        '\n' => "\\n".to_string(), '\r' => "\\r".to_string(), '\t' => "\\t".to_string(),
        '\\' => "\\\\".to_string(), '|' => "\\p".to_string(),
        _ => c.to_string(),
    }).collect()
}

fn unescape(s: &str) -> String {
    let mut out = String::new();
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c != '\\' { out.push(c); continue }
        match it.next() {
            Some('n') => out.push('\n'), Some('r') => out.push('\r'),
            Some('t') => out.push('\t'), Some('p') => out.push('|'),
            Some('\\') => out.push('\\'), Some(other) => { out.push('\\'); out.push(other) }
            None => out.push('\\'),
        }
    }
    out
}
"""
    with open(os.path.join(src, "main.rs"), "w", encoding="utf-8") as handle:
        handle.write(classify + "\n" + leaders + "\n" + fonts + harness)
    with open(
        os.path.join(directory, "classifyprobe", "Cargo.toml"), "w", encoding="utf-8"
    ) as handle:
        handle.write(
            "[package]\nname='classifyprobe'\nversion='0.0.0'\nedition='2021'\n"
            "[[bin]]\nname='classifyprobe'\npath='src/main.rs'\n"
        )


def escape(text):
    return (
        text.replace("\\", "\\\\")
        .replace("|", "\\p")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


def cases(random_count):
    """Probe strings: the reference's own test inputs, a systematic sweep of
    every literal the classifiers look at, and a random tail. The tail is what
    found the grapheme bugs — combining marks are in the alphabet for exactly
    that reason."""
    out = []

    # The reference's own unit-test inputs.
    out += [
        "• Item one", "- Item two", "* Item three", "1. First", "2) Second",
        "a. Letter item", "Regular text", "● Item", "- existing",
        "<u>● Item text</u>", "**● Fraud: Willing cooperation;**",
        "**● Label:** rest of line", "*● Italic:* rest", "const x = 5;",
        "function foo() {", "import React from 'react'", "This is regular text.",
    ]

    bullets = ["•", "●", "○", "◦", "-", "*"]
    for bullet in bullets:
        for tail in ["", " ", " X", "X", "  X"]:
            out.append(bullet + tail)
        for wrapper in ["**", "*", "<u>", "***", "_"]:
            out.append(wrapper + bullet + " Label:" + wrapper.replace("<u>", "</u>"))
            out.append(wrapper + bullet + "Label")

    for lead in ["", "  ", "\t", "  ", " "]:
        for body in ["• x", "1. x", "(a) x", "a) x", ".5 x", "Figure 1", "FIGURE 1",
                     "table 2", "Fig. 3"]:
            out.append(lead + body)

    # The five-character window the numbered test uses.
    for digits in ["1", "12", "123", "1234", "12345", "123456", "0", "00"]:
        for delimiter in [".", ")"]:
            out.append(digits + delimiter + " item")
            out.append(digits + delimiter + "item")

    for char in "abzABZ0(){}[];=<>.#*-_|\\ §é":
        out += [char, char + ".", char + ")", "(" + char + ")", char + " tail",
                "(" + char + ") tail"]

    for prefix in ["Figure", "Table", "figure", "table", "FIGURE", "TABLE", "Figura",
                   "Tabela", "Fig.", "Fig", "Chart", "Graph", "Diagram", "Image",
                   "Imagem", "Photo", "Foto", "Gráfico", "Note", "Nota", "Source", "Fonte"]:
        for suffix in [" 1", " (a)", " #2", " of Contents", ": x", ":x", "", "  1", " one"]:
            out.append(prefix + suffix)

    for pattern in ["import ", "export ", "from ", "const ", "let ", "var ", "function ",
                    "class ", "def ", "pub fn ", "fn ", "async fn ", "impl ", "=> ",
                    "-> ", ":: ", ":= "]:
        out += [pattern + "x", pattern.strip() + "x", "  " + pattern + "x"]

    # The byte-length bound in `is_code_like`, from both sides and in a script
    # where characters are not bytes.
    out += ["a;", "a{", "a}", "a=b", "(a)(b)(c)", "<a><b>", "x" * 199 + ";",
            "x" * 200 + ";", "é" * 99 + ";", "é" * 100 + ";",
            "See (a), (b) and (c)", "no punctuation at all"]

    out += ["a .... 3", "a ... b ... 7", "and so on ... then more", "....", "...",
            "a...b", "a...b...c", ". . . .", "x....", "..", "a..b..c..d"]

    for name in ["Courier", "ABCDEF+Consolas-Bold", "JetBrainsMono", "DejaVu Sans Mono",
                 "Helvetica", "MONO", "Source Code Pro", "Liberation Mono",
                 "Inconsolata", "Menlo", "fixedsys", "Terminal"]:
        out.append(name)

    out += ["", "   ", "\u00a0", "\u2028x", "\U0001F642 x", "\u2022\u0301 x",
            "\u0130mage 1", "\uff26\uff29\uff27\uff35\uff32\uff25 1",
            "\ufb01gure 1", "\u2160. Roman", "\uff11. Fullwidth",
            "\u2022\u200b x", "- ", "* ", "-", "*", "\\", "|", "a\\|b"]

    # Uppercase forms whose full lowercase might complete a pattern, plus the
    # Greek final sigma, where Rust's `to_lowercase` is context-sensitive.
    out += ["BOLD", "BÖLD", "ITALİC", "MEDİUM", "ΣLANT", "SLANTΣ", "HEAVΥ", "Σ", "ΑΣ",
            "ΟΔΟΣ", "ς"]

    generator = random.Random(1234)
    alphabet = list("ab z019.)(-*<>u=;{}#[]:/\\|") + [
        "\u00e9", "\u00c5", "\u00a0", "\u0301", "\u0308", "\u200b", "\u2003",
        "\u2022", "\u25cf", "\u25cb", "\u25e6", "\t", "\u2028", "\u0130",
        "\ufb01", "\uff11", "\uff26", "\U0001F642", "\u3000", "\x00",
    ]
    words = ["Figure", "Table", "figure", "Source:", "Note:", "Fig.", "import ", "const ",
             "fn ", "=> ", "Courier", "mono", "**", "<u>", "</u>", "*", "- ", "1. ",
             "(a)", ". . .", "....", "Mono", "Fonte:", "bold", "-Medi", "Oblique",
             "kursiv", "SemiBold", "-It"]
    for _ in range(random_count):
        length = generator.randint(0, 14)
        out.append(
            "".join(
                generator.choice(words) if generator.random() < 0.3
                else generator.choice(alphabet)
                for _ in range(length)
            )
        )
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory")
    parser.add_argument("--cases", type=int, default=25000,
                        help="size of the random tail (default 25000)")
    arguments = parser.parse_args()

    os.makedirs(arguments.directory, exist_ok=True)
    write_probe(reference_source(), arguments.directory)

    crate = os.path.join(arguments.directory, "classifyprobe")
    subprocess.run(["cargo", "build", "--release", "--offline"], cwd=crate, check=True)

    seen, corpus = set(), []
    for case in cases(arguments.cases):
        escaped = escape(case)
        # The probe skips empty lines, so an empty case has no answer to
        # compare against.
        if not escaped or escaped in seen:
            continue
        seen.add(escaped)
        corpus.append(escaped)

    cases_path = os.path.join(arguments.directory, "classify-cases.txt")
    with open(cases_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(corpus) + "\n")

    with open(cases_path, encoding="utf-8") as stdin, open(
        os.path.join(arguments.directory, "classify-rust.txt"), "w", encoding="utf-8"
    ) as stdout:
        subprocess.run(
            [os.path.join(crate, "target", "release", "classifyprobe")],
            stdin=stdin, stdout=stdout, check=True,
        )

    print(f"{len(corpus)} probe strings; oracle answers written to {arguments.directory}")


if __name__ == "__main__":
    main()
