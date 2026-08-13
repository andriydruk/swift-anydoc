"""Build small PDFs exercising marked-content nesting, for the MCID probe.

Each file is a single page whose content stream wraps text in BMC/BDC/EMC in
a different arrangement, so the id in effect for each run can be compared
against the reference. Written by hand rather than with a library because the
point is to control the operator sequence exactly.
"""

import argparse
import os
import subprocess


def pdf(content: str) -> bytes:
    """A one-page PDF carrying `content` as its content stream."""
    stream = content.encode("latin-1")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 5 0 R >> /Properties << /P1 6 0 R >> >> "
        b"/Contents 4 0 R >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /MCID 7 >>",
    ]

    out = bytearray(b"%PDF-1.7\n")
    offsets = []
    for index, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{index} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n".encode()
    out += b"0000000000 65535 f \n"
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode()
    out += (
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n".encode()
        + b"%%EOF\n"
    )
    return bytes(out)


def text(x, y, body):
    return f"BT /F1 12 Tf {x} {y} Td ({body}) Tj ET\n"


CASES = {
    # No marked content at all.
    "plain": text(100, 700, "plain"),
    # One BDC with an inline properties dictionary.
    "simple": "/Span << /MCID 3 >> BDC\n" + text(100, 700, "tagged") + "EMC\n",
    # Text before, inside and after the marked section.
    "around": (
        text(100, 720, "before")
        + "/Span << /MCID 4 >> BDC\n"
        + text(100, 700, "inside")
        + "EMC\n"
        + text(100, 680, "after")
    ),
    # Nested: the innermost id wins.
    "nested": (
        "/Sect << /MCID 1 >> BDC\n"
        + text(100, 720, "outer")
        + "/Span << /MCID 2 >> BDC\n"
        + text(100, 700, "inner")
        + "EMC\n"
        + text(100, 680, "outer-again")
        + "EMC\n"
    ),
    # BMC carries no id, so enclosing content still governs.
    "bmc-inside": (
        "/Sect << /MCID 5 >> BDC\n"
        + "/Artifact BMC\n"
        + text(100, 700, "under-bmc")
        + "EMC\n"
        + "EMC\n"
    ),
    # A bare BMC with nothing enclosing it.
    "bmc-only": "/Artifact BMC\n" + text(100, 700, "artifact") + "EMC\n",
    # A BDC whose dictionary has no MCID key.
    "no-mcid": "/Span << /Lang (en) >> BDC\n" + text(100, 700, "untagged") + "EMC\n",
    # Properties given by name, resolved through the page's /Properties.
    "by-name": "/Span /P1 BDC\n" + text(100, 700, "named") + "EMC\n",
    # An unbalanced EMC, which must not underflow.
    "extra-emc": "EMC\nEMC\n" + text(100, 700, "after-emc"),
    # An unclosed BDC running to the end of the stream.
    "unclosed": "/Span << /MCID 8 >> BDC\n" + text(100, 700, "unclosed"),
    # Several sibling sections.
    "siblings": (
        "/Span << /MCID 10 >> BDC\n" + text(100, 720, "one") + "EMC\n"
        + "/Span << /MCID 11 >> BDC\n" + text(100, 700, "two") + "EMC\n"
        + "/Span << /MCID 12 >> BDC\n" + text(100, 680, "three") + "EMC\n"
    ),
    # ActualText: the glyphs are suppressed and the declared text emitted.
    "actual": "/Span << /ActualText (fi) >> BDC\n" + text(100, 700, "XY") + "EMC\n",
    # With an MCID alongside it.
    "actual-mcid": (
        "/Span << /ActualText (ligature) /MCID 9 >> BDC\n"
        + text(100, 700, "XY") + "EMC\n"
    ),
    # A Td between the BDC and the first glyph moves to the right line.
    "actual-moved": (
        "/Span << /ActualText (moved) >> BDC\nBT /F1 12 Tf 100 760 Td "
        + "0 -60 Td (XY) Tj ET\nEMC\n"
    ),
    # Text either side of the section.
    "actual-around": (
        text(100, 720, "before")
        + "/Span << /ActualText (middle) >> BDC\n" + text(100, 700, "XY") + "EMC\n"
        + text(100, 680, "after")
    ),
    # Nested sections, the inner one also declaring text.
    "actual-nested": (
        "/Span << /ActualText (outer) >> BDC\n"
        + text(100, 720, "AB")
        + "/Span << /ActualText (inner) >> BDC\n" + text(100, 700, "CD") + "EMC\n"
        + text(100, 680, "EF")
        + "EMC\n"
    ),
    # Whitespace-only ActualText, which is dropped.
    "actual-blank": "/Span << /ActualText ( ) >> BDC\n" + text(100, 700, "XY") + "EMC\n",
    # An empty section with no glyphs at all.
    "actual-empty": "/Span << /ActualText (alone) >> BDC\nEMC\n",
    # A TJ array inside the section.
    "actual-tj": (
        "/Span << /ActualText (array) >> BDC\n"
        + "BT /F1 12 Tf 100 700 Td [(A) -200 (B)] TJ ET\nEMC\n"
    ),
    # A ligature in the declared text, which expansion must handle.
    "actual-ligature": (
        "/Span << /ActualText (office) >> BDC\n" + text(100, 700, "XY") + "EMC\n"
    ),
    # Deep nesting where only the outermost declares an id.
    "deep": (
        "/Sect << /MCID 20 >> BDC\n"
        + "/Span << >> BDC\n"
        + "/Span BMC\n"
        + text(100, 700, "deep")
        + "EMC\nEMC\nEMC\n"
    ),
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("--probe", help="graphicsprobe, to write .expected beside each PDF")
    arguments = parser.parse_args()
    os.makedirs(arguments.directory, exist_ok=True)
    for name, content in sorted(CASES.items()):
        path = os.path.join(arguments.directory, f"{name}.pdf")
        with open(path, "wb") as handle:
            handle.write(pdf(content))
        # The content stream alone, so the Swift side can be driven without a
        # PDF reader in the loop.
        with open(os.path.join(arguments.directory, f"{name}.content"), "w",
                  encoding="latin-1") as handle:
            handle.write(content)
        if arguments.probe:
            result = subprocess.run([arguments.probe, "--mcid", path],
                                    capture_output=True, text=True, check=True)
            with open(os.path.join(arguments.directory, f"{name}.expected"), "w",
                      encoding="utf-8") as handle:
                handle.write(result.stdout)
    print(f"{len(CASES)} marked-content PDFs written to {arguments.directory}")


if __name__ == "__main__":
    main()
