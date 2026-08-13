"""Build PDFs whose font dictionaries exercise the descriptor style flags.

Each file carries one page whose `/Resources /Font` holds several font
dictionaries, arranged to hit a different branch of `descriptor_style_flags`
and `get_font_file2_obj_num`: descriptor present or hanging off a descendant,
`/ItalicAngle` at each side of the four-degree bar, `/Flags` as an integer, a
real or a reference, and `/FontFile3` streams holding real CFF Name INDEXes.

Hand-built rather than produced by a library, because the point is to control
the object graph — including the shapes a library would refuse to write.
"""

import argparse
import os
import re
import subprocess


def pdf(objects: list[bytes]) -> bytes:
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


def cff(name: bytes) -> bytes:
    """A minimal bare-CFF program whose Name INDEX holds one name."""
    header = bytes([1, 0, 4, 1])
    body = bytes([0, 1, 1, 1, 1 + len(name)]) + name
    return header + body


def stream(data: bytes) -> bytes:
    return b"<< /Length " + str(len(data)).encode() + b" >>\nstream\n" + data + b"\nendstream"


def document(fonts: dict[str, bytes], extra: list[bytes] = ()) -> bytes:
    """Catalog, page tree, page, contents, font resources, then `extra`.

    `fonts` maps a resource name to the object body; those objects are
    numbered from 6 upwards, and anything in `extra` follows them. Both may
    write `@N`, which is replaced by the object number of `extra[N]` — the
    fonts come first, so those numbers are not known when the case is
    written.
    """
    content = b"BT /F1 12 Tf 100 700 Td (hi) Tj ET"
    entries = b" ".join(
        f"/{resource} {6 + index} 0 R".encode() for index, resource in enumerate(fonts)
    )
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R"
        b" /Resources << /Font 5 0 R >> >>",
        stream(content),
        b"<< " + entries + b" >>",
    ]
    objects.extend(fonts.values())
    objects.extend(extra)

    base = 6 + len(fonts)
    def substitute(body: bytes) -> bytes:
        return re.sub(rb"@(\d+)", lambda m: str(base + int(m.group(1))).encode(), body)

    return pdf([substitute(body) for body in objects])


def simple(base: bytes, descriptor: bytes | None = None,
           descriptor_ref: int | None = None) -> bytes:
    out = b"<< /Type /Font /Subtype /TrueType /BaseFont /" + base
    if descriptor is not None:
        out += b" /FontDescriptor " + descriptor
    if descriptor_ref is not None:
        out += f" /FontDescriptor @{descriptor_ref} 0 R".encode()
    return out + b" >>"


CASES = {
    # The four-degree bar, from either side and at it exactly. The reference
    # takes `>= 4.0`, so the boundary case is italic.
    "italic-angle": document({
        "F1": simple(b"Sub+Tag", descriptor_ref=0),
        "F2": simple(b"Sub+Tag", descriptor_ref=1),
        "F3": simple(b"Sub+Tag", descriptor_ref=2),
        "F4": simple(b"Sub+Tag", descriptor_ref=3),
        "F5": simple(b"Sub+Tag", descriptor_ref=4),
    }, [
        b"<< /Type /FontDescriptor /ItalicAngle 0 >>",
        b"<< /Type /FontDescriptor /ItalicAngle -3.9 >>",
        b"<< /Type /FontDescriptor /ItalicAngle -4 >>",
        b"<< /Type /FontDescriptor /ItalicAngle 4.0 >>",
        b"<< /Type /FontDescriptor /ItalicAngle 12 >>",
    ]),
    # `/Flags` bit 7 is italic and bit 19 is ForceBold; a real-valued or
    # indirect `/Flags` reads as absent, since the reference wants an integer
    # and does not resolve.
    "flags": document({
        "F1": simple(b"Sub+Tag", descriptor_ref=0),
        "F2": simple(b"Sub+Tag", descriptor_ref=1),
        "F3": simple(b"Sub+Tag", descriptor_ref=2),
        "F4": simple(b"Sub+Tag", descriptor_ref=3),
        "F5": simple(b"Sub+Tag", descriptor_ref=4),
        "F6": simple(b"Sub+Tag", descriptor_ref=5),
    }, [
        b"<< /Type /FontDescriptor /Flags 64 >>",
        b"<< /Type /FontDescriptor /Flags 262144 >>",
        b"<< /Type /FontDescriptor /Flags 262208 >>",
        b"<< /Type /FontDescriptor /Flags 64.0 >>",
        b"<< /Type /FontDescriptor /Flags @6 0 R >>",
        b"<< /Type /FontDescriptor /Flags 4 >>",
        b"64",
    ]),
    # An indirect `/ItalicAngle` reads as zero for the same reason.
    "indirect-angle": document({
        "F1": simple(b"Sub+Tag", descriptor_ref=0),
        "F2": simple(b"Sub+Tag", descriptor_ref=1),
    }, [
        b"<< /Type /FontDescriptor /ItalicAngle @2 0 R >>",
        b"<< /Type /FontDescriptor /ItalicAngle 30 >>",
        b"30",
    ]),
    # A descriptor written inline rather than as a reference, and one that is
    # not a dictionary at all.
    "inline-descriptor": document({
        "F1": simple(b"Sub+Tag", descriptor=b"<< /ItalicAngle 20 /Flags 262144 >>"),
        "F2": simple(b"Sub+Tag", descriptor=b"42"),
        "F3": simple(b"Sub+Tag"),
    }),
    # Type0: the descriptor hangs off DescendantFonts[0], but only when the
    # font dictionary has none of its own — a font carrying both keeps its
    # own, which is the shape the reference's `or_else` decides. F3 reaches
    # the array through a reference rather than writing it inline.
    "type0-descendant": document({
        "F1": b"<< /Type /Font /Subtype /Type0 /BaseFont /Sub+Tag /Encoding /Identity-H"
              b" /DescendantFonts [@0 0 R] >>",
        "F2": b"<< /Type /Font /Subtype /Type0 /BaseFont /Sub+Tag /Encoding /Identity-H"
              b" /DescendantFonts [@0 0 R] /FontDescriptor @3 0 R >>",
        "F3": b"<< /Type /Font /Subtype /Type0 /BaseFont /Sub+Tag /Encoding /Identity-H"
              b" /DescendantFonts @1 0 R >>",
    }, [
        b"<< /Type /Font /Subtype /CIDFontType2 /FontDescriptor @2 0 R >>",
        b"[@0 0 R]",
        b"<< /Type /FontDescriptor /ItalicAngle 0 /Flags 0 >>",
        b"<< /Type /FontDescriptor /ItalicAngle 15 >>",
    ]),
    # The CMap lookup key: FontFile2 beats FontFile3, a descendant with
    # neither falls back to its own object number, and a descendant with no
    # descriptor at all gives nothing — the fallback sits after the
    # descriptor has already been required.
    "cmap-key": document({
        "F1": b"<< /Type /Font /Subtype /Type0 /Encoding /Identity-H"
              b" /DescendantFonts [@0 0 R] >>",
        "F2": b"<< /Type /Font /Subtype /Type0 /Encoding /Identity-V"
              b" /DescendantFonts [@1 0 R] >>",
        "F3": b"<< /Type /Font /Subtype /Type0 /Encoding /Identity-H"
              b" /DescendantFonts [@2 0 R] >>",
        "F4": b"<< /Type /Font /Subtype /Type0 /Encoding /WinAnsiEncoding"
              b" /DescendantFonts [@0 0 R] >>",
        "F5": b"<< /Type /Font /Subtype /Type0 /DescendantFonts [@0 0 R] >>",
        "F6": b"<< /Type /Font /Subtype /Type0 /Encoding /Identity-H"
              b" /DescendantFonts [@3 0 R] >>",
    }, [
        b"<< /Type /Font /Subtype /CIDFontType2 /FontDescriptor @4 0 R >>",
        b"<< /Type /Font /Subtype /CIDFontType0 /FontDescriptor @5 0 R >>",
        b"<< /Type /Font /Subtype /CIDFontType2 /FontDescriptor @6 0 R >>",
        b"<< /Type /Font /Subtype /CIDFontType2 >>",
        b"<< /Type /FontDescriptor /FontFile2 @7 0 R /FontFile3 @8 0 R >>",
        b"<< /Type /FontDescriptor /FontFile3 @8 0 R >>",
        b"<< /Type /FontDescriptor >>",
        stream(cff(b"Embedded-Regular")),
        stream(cff(b"Embedded-Italic")),
    ]),
    # A simple font's key is its own descriptor's font file.
    "simple-key": document({
        "F1": simple(b"Sub+Tag", descriptor_ref=0),
        "F2": simple(b"Sub+Tag", descriptor_ref=1),
        "F3": simple(b"Sub+Tag"),
    }, [
        b"<< /Type /FontDescriptor /FontFile2 @2 0 R >>",
        b"<< /Type /FontDescriptor >>",
        stream(cff(b"Simple-Regular")),
    ]),
    # The embedded program's own opinion: a CFF Name INDEX whose PostScript
    # name says italic or bold even though the descriptor claims upright.
    # F4 already knows it is italic, so the program is consulted only for
    # bold — and the answer is the same either way.
    "cff-name": document({
        "F1": simple(b"Sub+Tag", descriptor_ref=0),
        "F2": simple(b"Sub+Tag", descriptor_ref=1),
        "F3": simple(b"Sub+Tag", descriptor_ref=2),
        "F4": simple(b"Sub+Tag", descriptor_ref=3),
    }, [
        b"<< /Type /FontDescriptor /FontFile3 @4 0 R >>",
        b"<< /Type /FontDescriptor /FontFile3 @5 0 R >>",
        b"<< /Type /FontDescriptor /FontFile3 @6 0 R >>",
        b"<< /Type /FontDescriptor /ItalicAngle 20 /FontFile3 @4 0 R >>",
        stream(cff(b"ABCDEF+Amplitude-LightItalic")),
        stream(cff(b"ABCDEF+Nimbus-Bold")),
        stream(cff(b"ABCDEF+Plain")),
    ]),
    # A font file that is not CFF at all: an sfnt header, which the deferred
    # TrueType branch would read and the CFF reader must refuse.
    "sfnt-file": document({
        "F1": simple(b"Sub+Tag", descriptor_ref=0),
        "F2": simple(b"Sub+Tag", descriptor_ref=1),
    }, [
        b"<< /Type /FontDescriptor /FontFile2 @2 0 R >>",
        b"<< /Type /FontDescriptor /FontFile3 @3 0 R >>",
        stream(bytes([0x00, 0x01, 0x00, 0x00]) + bytes(60)),
        stream(b"OTTO" + bytes(60)),
    ]),
    # A font file reference pointing at nothing, and one pointing at a
    # non-stream — both must come back empty rather than failing. The key is
    # still reported, since it is the reference's number and not the object.
    "broken-file": document({
        "F1": simple(b"Sub+Tag", descriptor_ref=0),
        "F2": simple(b"Sub+Tag", descriptor_ref=1),
    }, [
        b"<< /Type /FontDescriptor /FontFile3 99 0 R >>",
        b"<< /Type /FontDescriptor /FontFile3 @2 0 R >>",
        b"<< /NotAStream true >>",
    ]),
    # The name heuristics are *not* part of these two functions, so a
    # BaseFont that reads bold and italic changes nothing here.
    "name-only": document({
        "F1": simple(b"Helvetica-BoldOblique"),
        "F2": simple(b"Helvetica-BoldOblique", descriptor_ref=0),
    }, [
        b"<< /Type /FontDescriptor /ItalicAngle 0 /Flags 0 >>",
    ]),
    # Font resources that are not dictionaries at all.
    "degenerate": document({
        "F1": b"[1 2 3]",
        "F2": b"null",
    }),
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("--probe", help="graphicsprobe, to write .expected beside each PDF")
    arguments = parser.parse_args()
    os.makedirs(arguments.directory, exist_ok=True)
    for name, data in sorted(CASES.items()):
        path = os.path.join(arguments.directory, f"{name}.pdf")
        with open(path, "wb") as handle:
            handle.write(data)
        if arguments.probe:
            result = subprocess.run([arguments.probe, "--fontstyle", path],
                                    capture_output=True, text=True, check=True)
            with open(os.path.join(arguments.directory, f"{name}.expected"), "w",
                      encoding="utf-8") as handle:
                handle.write(result.stdout)
    print(f"{len(CASES)} font PDFs written to {arguments.directory}")


if __name__ == "__main__":
    main()
