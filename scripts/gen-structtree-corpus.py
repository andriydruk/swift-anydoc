"""Build tagged PDFs exercising structure-tree parsing.

Each file has a /StructTreeRoot arranged differently — nesting, role maps,
MCR and OBJR dictionaries, /K in each of its four shapes — so the parsed tree
can be compared against the reference. Hand-built rather than produced by a
library, because the point is to control the object graph exactly.
"""

import argparse
import os
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


def document(struct_root: bytes, extra: list[bytes] = ()) -> bytes:
    """Catalog, page tree, one page, then the structure objects from 5 on."""
    content = b"BT /F1 12 Tf 100 700 Td (hi) Tj ET"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 5 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
        b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content
        + b"\nendstream",
        struct_root,
    ]
    objects.extend(extra)
    return pdf(objects)


# The page is object 3.
PAGE = b"3 0 R"

CASES = {
    # A root with no children at all: reported as untagged.
    "empty": document(b"<< /Type /StructTreeRoot >>"),
    "empty-kids": document(b"<< /Type /StructTreeRoot /K [] >>"),
    # One element, /K as a single integer — content of that element.
    "single": document(
        b"<< /Type /StructTreeRoot /K 6 0 R >>",
        [b"<< /Type /StructElem /S /P /Pg " + PAGE + b" /K 0 >>"],
    ),
    # /K as an array of integers.
    "mcid-array": document(
        b"<< /Type /StructTreeRoot /K 6 0 R >>",
        [b"<< /Type /StructElem /S /P /Pg " + PAGE + b" /K [0 1 2] >>"],
    ),
    # Nested elements.
    "nested": document(
        b"<< /Type /StructTreeRoot /K 6 0 R >>",
        [
            b"<< /Type /StructElem /S /Document /Pg " + PAGE + b" /K [7 0 R 8 0 R] >>",
            b"<< /Type /StructElem /S /H1 /K 0 >>",
            b"<< /Type /StructElem /S /P /K 1 >>",
        ],
    ),
    # /Pg inherited from an ancestor.
    "inherited-page": document(
        b"<< /Type /StructTreeRoot /K 6 0 R >>",
        [
            b"<< /Type /StructElem /S /Sect /Pg " + PAGE + b" /K [7 0 R] >>",
            b"<< /Type /StructElem /S /P /K 5 >>",
        ],
    ),
    # A marked-content reference dictionary.
    "mcr": document(
        b"<< /Type /StructTreeRoot /K 6 0 R >>",
        [
            b"<< /Type /StructElem /S /P /Pg " + PAGE
            + b" /K [<< /Type /MCR /MCID 3 >>] >>",
        ],
    ),
    # An MCR carrying its own /Pg.
    "mcr-own-page": document(
        b"<< /Type /StructTreeRoot /K 6 0 R >>",
        [
            b"<< /Type /StructElem /S /P /K [<< /Type /MCR /MCID 4 /Pg " + PAGE
            + b" >>] >>",
        ],
    ),
    # An object reference, which carries no content.
    "objr": document(
        b"<< /Type /StructTreeRoot /K 6 0 R >>",
        [
            b"<< /Type /StructElem /S /P /Pg " + PAGE
            + b" /K [<< /Type /OBJR /Obj 3 0 R >> 7] >>",
        ],
    ),
    # A role map onto a standard type.
    "rolemap": document(
        b"<< /Type /StructTreeRoot /RoleMap << /MyHead /H1 >> /K 6 0 R >>",
        [b"<< /Type /StructElem /S /MyHead /Pg " + PAGE + b" /K 0 >>"],
    ),
    # A two-hop role map chain.
    "rolemap-chain": document(
        b"<< /Type /StructTreeRoot /RoleMap << /A /B /B /H2 >> /K 6 0 R >>",
        [b"<< /Type /StructElem /S /A /Pg " + PAGE + b" /K 0 >>"],
    ),
    # A role map cycle, which the hop limit must survive.
    "rolemap-cycle": document(
        b"<< /Type /StructTreeRoot /RoleMap << /A /B /B /A >> /K 6 0 R >>",
        [b"<< /Type /StructElem /S /A /Pg " + PAGE + b" /K 0 >>"],
    ),
    # An unmapped custom type falls through to Other.
    "unknown-role": document(
        b"<< /Type /StructTreeRoot /K 6 0 R >>",
        [b"<< /Type /StructElem /S /Whatever /Pg " + PAGE + b" /K 0 >>"],
    ),
    # An element with no /S at all is dropped.
    "no-type": document(
        b"<< /Type /StructTreeRoot /K [6 0 R 7 0 R] >>",
        [
            b"<< /Type /StructElem /Pg " + PAGE + b" /K 0 >>",
            b"<< /Type /StructElem /S /P /Pg " + PAGE + b" /K 1 >>",
        ],
    ),
    # A bare integer directly under the root.
    "bare-mcid": document(b"<< /Type /StructTreeRoot /Pg " + PAGE + b" /K [0 1] >>"),
    # Alt, ActualText and Lang.
    "attributes": document(
        b"<< /Type /StructTreeRoot /K 6 0 R >>",
        [
            b"<< /Type /StructElem /S /Figure /Pg " + PAGE
            + b" /Alt (a seal) /ActualText (fi) /Lang (en-US) /K 0 >>",
        ],
    ),
    # A full tagged table.
    "table": document(
        b"<< /Type /StructTreeRoot /K 6 0 R >>",
        [
            b"<< /Type /StructElem /S /Table /Pg " + PAGE + b" /K [7 0 R 8 0 R] >>",
            b"<< /Type /StructElem /S /TR /K [9 0 R 10 0 R] >>",
            b"<< /Type /StructElem /S /TR /K [11 0 R 12 0 R] >>",
            b"<< /Type /StructElem /S /TH /K 0 >>",
            b"<< /Type /StructElem /S /TH /K 1 >>",
            b"<< /Type /StructElem /S /TD /K 2 >>",
            b"<< /Type /StructElem /S /TD /K 3 >>",
        ],
    ),
    # /K as a lone dictionary rather than an array.
    "kids-dict": document(
        b"<< /Type /StructTreeRoot /K << /Type /StructElem /S /P /Pg " + PAGE
        + b" /K 0 >> >>"
    ),
    # A self-referential element, which the depth limit must survive.
    "cycle": document(
        b"<< /Type /StructTreeRoot /K 6 0 R >>",
        [b"<< /Type /StructElem /S /Div /Pg " + PAGE + b" /K [6 0 R] >>"],
    ),
    # No structure tree at all.
    "untagged": pdf([
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    ]),
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
            result = subprocess.run([arguments.probe, "--structparse", path],
                                    capture_output=True, text=True, check=True)
            with open(os.path.join(arguments.directory, f"{name}.expected"), "w",
                      encoding="utf-8") as handle:
                handle.write(result.stdout)
    print(f"{len(CASES)} tagged PDFs written to {arguments.directory}")


if __name__ == "__main__":
    main()
