#!/usr/bin/env python3
"""Generate an adversarial PDF corpus.

The committed fixture is one narrow shape — single column, classic xref,
FlateDecode, simple TrueType fonts with ToUnicode. Whole branches of the
reader (cross-reference streams, object streams, CID fonts, the other
filters, the PNG predictors, incremental updates) are written but never
exercised by it. This builds files that do exercise them.

usage: scripts/gen-pdf-corpus.py <output-dir>

Verify with `scratchpad/pdfprobe` (lopdf) as the oracle and the Swift
reader's own dump; they must agree on the object graph.
"""
import os
import struct
import sys
import zlib

OUT = sys.argv[1] if len(sys.argv) > 1 else "pdf-corpus"
os.makedirs(OUT, exist_ok=True)


class Builder:
    """Assembles a PDF body: objects numbered from 1, offsets recorded."""

    def __init__(self, version=b"1.7"):
        self.out = bytearray(b"%PDF-" + version + b"\n%\xe2\xe3\xcf\xd3\n")
        self.offsets = {}
        self.next_id = 1

    def reserve(self):
        n = self.next_id
        self.next_id += 1
        return n

    def add(self, body, obj_id=None):
        """Write `N 0 obj ... endobj` and return the object number."""
        if obj_id is None:
            obj_id = self.reserve()
        self.offsets[obj_id] = len(self.out)
        self.out += b"%d 0 obj\n" % obj_id
        self.out += body
        self.out += b"\nendobj\n"
        return obj_id

    def stream(self, dict_body, data, obj_id=None):
        d = b"<<" + dict_body + b"/Length %d>>" % len(data)
        return self.add(d + b"\nstream\n" + data + b"\nendstream", obj_id)


def flate(data):
    return zlib.compress(data)


def lzw(data):
    """LZW as PDF writes it: MSB-first, 9..12 bits, 256 clear, 257 EOD."""
    out = bytearray()
    bitbuf = 0
    bitcnt = 0

    def emit(code, width):
        nonlocal bitbuf, bitcnt
        bitbuf = (bitbuf << width) | code
        bitcnt += width
        while bitcnt >= 8:
            out.append((bitbuf >> (bitcnt - 8)) & 0xFF)
            bitcnt -= 8

    table = {bytes([i]): i for i in range(256)}
    nxt = 258
    width = 9
    emit(256, width)
    w = b""
    for ch in data:
        c = bytes([ch])
        if w + c in table:
            w = w + c
            continue
        emit(table[w], width)
        table[w + c] = nxt
        nxt += 1
        # Early change: widen one code sooner, which is the PDF default.
        if nxt + 1 > (1 << width) and width < 12:
            width += 1
        w = c
    if w:
        emit(table[w], width)
    emit(257, width)
    if bitcnt:
        out.append((bitbuf << (8 - bitcnt)) & 0xFF)
    return bytes(out)


def ascii85(data):
    out = bytearray()
    for i in range(0, len(data), 4):
        chunk = data[i : i + 4]
        pad = 4 - len(chunk)
        chunk = chunk + b"\x00" * pad
        n = struct.unpack(">I", chunk)[0]
        if n == 0 and pad == 0:
            out += b"z"
            continue
        digits = []
        for _ in range(5):
            digits.append(n % 85)
            n //= 85
        digits.reverse()
        out += bytes(d + 33 for d in digits)[: 5 - pad]
    return bytes(out) + b"~>"


def png_predict(rows, colors=1, columns=1, filter_type=2):
    """Apply a PNG row filter, which the reader must undo."""
    out = bytearray()
    previous = bytes(columns * colors)
    for row in rows:
        out.append(filter_type)
        if filter_type == 0:
            out += row
        elif filter_type == 1:  # Sub
            out += bytes(
                (row[i] - (row[i - colors] if i >= colors else 0)) & 0xFF for i in range(len(row))
            )
        elif filter_type == 2:  # Up
            out += bytes((row[i] - previous[i]) & 0xFF for i in range(len(row)))
        elif filter_type == 4:  # Paeth with no left/upper-left = Up
            out += bytes((row[i] - previous[i]) & 0xFF for i in range(len(row)))
        previous = row
    return bytes(out)


CONTENT = b"""BT /F1 24 Tf 72 720 Td (Generated Heading) Tj ET
BT /F1 10 Tf 72 690 Td [(Body text with a ) -300 (positioned gap.)] TJ ET
BT /F1 10 Tf 72 675 Td (Second body line.) Tj ET
"""

SIMPLE_FONT = (
    b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica"
    b"/FirstChar 32/LastChar 126/Widths [%s]>>"
    % b" ".join(b"500" for _ in range(95))
)


def classic_trailer(b, root, extra=b""):
    """A classic xref table plus trailer."""
    xref_at = len(b.out)
    count = b.next_id
    b.out += b"xref\n0 %d\n" % count
    b.out += b"0000000000 65535 f \n"
    for i in range(1, count):
        b.out += b"%010d 00000 n \n" % b.offsets.get(i, 0)
    b.out += b"trailer\n<</Size %d/Root %d 0 R" % (count, root) + extra + b">>\n"
    b.out += b"startxref\n%d\n%%%%EOF\n" % xref_at
    return bytes(b.out)


def xref_stream_trailer(b, root, widths=(1, 4, 2), predictor=None, extra=b""):
    """A PDF 1.5 cross-reference stream instead of a table."""
    stream_id = b.reserve()
    xref_at = len(b.out)
    b.offsets[stream_id] = xref_at
    count = b.next_id

    rows = []
    # Object 0 is the free head.
    rows.append(bytes([0]) + struct.pack(">I", 0) + struct.pack(">H", 0xFFFF))
    for i in range(1, count):
        rows.append(bytes([1]) + struct.pack(">I", b.offsets.get(i, 0)) + struct.pack(">H", 0))
    row_len = 1 + 4 + 2

    parms = b""
    if predictor is not None:
        data = flate(png_predict(rows, colors=row_len, columns=1, filter_type=predictor))
        parms = b"/DecodeParms<</Predictor 12/Colors %d/Columns 1/BitsPerComponent 8>>" % row_len
    else:
        data = flate(b"".join(rows))

    d = (
        b"<</Type/XRef/Size %d/Root %d 0 R/W[%d %d %d]/Filter/FlateDecode%s"
        % (count, root, widths[0], widths[1], widths[2], parms)
        + extra
        + b"/Length %d>>" % len(data)
    )
    b.out += b"%d 0 obj\n" % stream_id + d + b"\nstream\n" + data + b"\nendstream\nendobj\n"
    b.out += b"startxref\n%d\n%%%%EOF\n" % xref_at
    return bytes(b.out)


def base_document(b, content=CONTENT, font=SIMPLE_FONT, content_filter=None):
    """Catalog, pages, one page, its content and font. Returns the root id."""
    if content_filter == "lzw":
        data, filt = lzw(content), b"/Filter/LZWDecode"
    elif content_filter == "a85":
        data, filt = ascii85(content), b"/Filter/ASCII85Decode"
    elif content_filter == "a85+flate":
        data, filt = ascii85(flate(content)), b"/Filter[/ASCII85Decode/FlateDecode]"
    elif content_filter == "none":
        data, filt = content, b""
    else:
        data, filt = flate(content), b"/Filter/FlateDecode"

    content_id = b.stream(filt, data)
    font_id = b.add(font)
    page_id = b.reserve()
    pages_id = b.reserve()
    b.add(
        b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
        b"/Resources<</Font<</F1 %d 0 R>>>>/Contents %d 0 R>>"
        % (pages_id, font_id, content_id),
        page_id,
    )
    b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % page_id, pages_id)
    root = b.add(b"<</Type/Catalog/Pages %d 0 R>>" % pages_id)
    return root


def write(name, data):
    open(os.path.join(OUT, name + ".pdf"), "wb").write(data)


def annotated_document(b):
    """A page carrying /Link annotations and an AcroForm, so the annotation
    layer has something to find. Nothing here is drawn by the content stream:
    a link is a rectangle plus an action, and a field value lives off the
    trailer, which is exactly why they need their own extraction path."""
    content_id = b.stream(b"/Filter/FlateDecode", flate(CONTENT))
    font_id = b.add(SIMPLE_FONT)
    page_id = b.reserve()
    pages_id = b.reserve()

    # An external URI, an internal jump with no URI (dropped), a non-Link
    # annotation (skipped), and one whose rectangle is reversed.
    external = b.add(
        b"<</Type/Annot/Subtype/Link/Rect[100 700 300 720]"
        b"/A<</S/URI/URI(https://example.test/a)>>>>"
    )
    internal = b.add(b"<</Type/Annot/Subtype/Link/Rect[100 660 300 680]/Dest[0 /Fit]>>")
    other = b.add(b"<</Type/Annot/Subtype/Text/Rect[10 10 20 20]/Contents(note)>>")
    reversed_rect = b.add(
        b"<</Type/Annot/Subtype/Link/Rect[300 720 100 700]"
        b"/A<</S/URI/URI(https://example.test/b)>>>>"
    )

    # A text field under a group, so the qualified name is exercised, plus a
    # checkbox, an unchecked checkbox, and a signature field (all skipped but
    # the last two for different reasons).
    text_field = b.reserve()
    group = b.reserve()
    b.add(
        b"<</T(city)/FT/Tx/V(Lisbon)/Rect[100 600 300 620]/P %d 0 R/Parent %d 0 R>>"
        % (page_id, group),
        text_field,
    )
    b.add(b"<</T(address)/Kids[%d 0 R]>>" % text_field, group)
    checkbox = b.add(b"<</T(agree)/FT/Btn/V/Yes/Rect[100 560 120 580]/P %d 0 R>>" % page_id)
    unchecked = b.add(b"<</T(spam)/FT/Btn/V/Off/Rect[100 520 120 540]/P %d 0 R>>" % page_id)
    signature = b.add(b"<</T(sig)/FT/Sig/V<</Type/Sig>>/Rect[100 480 300 500]>>")

    b.add(
        b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
        b"/Resources<</Font<</F1 %d 0 R>>>>/Contents %d 0 R"
        b"/Annots[%d 0 R %d 0 R %d 0 R %d 0 R]>>"
        % (pages_id, font_id, content_id, external, internal, other, reversed_rect),
        page_id,
    )
    b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % page_id, pages_id)
    acroform = b.add(
        b"<</Fields[%d 0 R %d 0 R %d 0 R %d 0 R]>>"
        % (group, checkbox, unchecked, signature)
    )
    return b.add(
        b"<</Type/Catalog/Pages %d 0 R/AcroForm %d 0 R>>" % (pages_id, acroform)
    )


# --- baseline -------------------------------------------------------------
b = Builder()
write("classic-xref", classic_trailer(b, base_document(b)))

# --- cross-reference streams ---------------------------------------------
b = Builder()
write("xref-stream", xref_stream_trailer(b, base_document(b)))

# The predictor branch of the filter chain, which nothing has exercised.
b = Builder()
write("xref-stream-predictor", xref_stream_trailer(b, base_document(b), predictor=2))

# Narrow /W fields: a one-byte offset field is legal for a small file.
b = Builder()
root = base_document(b)
stream_id = b.reserve()
xref_at = len(b.out)
b.offsets[stream_id] = xref_at
count = b.next_id
rows = [bytes([0, 0, 0])]
for i in range(1, count):
    rows.append(bytes([1]) + struct.pack(">H", b.offsets.get(i, 0)) + bytes([0]))
data = flate(b"".join(rows))
b.out += b"%d 0 obj\n" % stream_id + (
    b"<</Type/XRef/Size %d/Root %d 0 R/W[1 2 1]/Filter/FlateDecode/Length %d>>"
    % (count, root, len(data))
) + b"\nstream\n" + data + b"\nendstream\nendobj\n"
b.out += b"startxref\n%d\n%%%%EOF\n" % xref_at
write("xref-stream-narrow-w", bytes(b.out))

# --- object streams -------------------------------------------------------
b = Builder()
content_id = b.stream(b"/Filter/FlateDecode", flate(CONTENT))
# The font, page and pages objects live compressed inside an ObjStm.
font_id, page_id, pages_id, root_id = (b.reserve() for _ in range(4))
inner = [
    (font_id, SIMPLE_FONT),
    (
        page_id,
        b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
        b"/Resources<</Font<</F1 %d 0 R>>>>/Contents %d 0 R>>"
        % (pages_id, font_id, content_id),
    ),
    (pages_id, b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % page_id),
    (root_id, b"<</Type/Catalog/Pages %d 0 R>>" % pages_id),
]
header = b""
bodies = b""
for oid, body in inner:
    header += b"%d %d " % (oid, len(bodies))
    bodies += body + b" "
payload = header + bodies
objstm_id = b.reserve()
data = flate(payload)
b.offsets[objstm_id] = len(b.out)
b.out += b"%d 0 obj\n" % objstm_id + (
    b"<</Type/ObjStm/N %d/First %d/Filter/FlateDecode/Length %d>>"
    % (len(inner), len(header), len(data))
) + b"\nstream\n" + data + b"\nendstream\nendobj\n"

xref_id = b.reserve()
xref_at = len(b.out)
b.offsets[xref_id] = xref_at
count = b.next_id
rows = [bytes([0]) + struct.pack(">I", 0) + struct.pack(">H", 0xFFFF)]
compressed = {oid: i for i, (oid, _) in enumerate(inner)}
for i in range(1, count):
    if i in compressed:
        rows.append(bytes([2]) + struct.pack(">I", objstm_id) + struct.pack(">H", compressed[i]))
    else:
        rows.append(bytes([1]) + struct.pack(">I", b.offsets.get(i, 0)) + struct.pack(">H", 0))
data = flate(b"".join(rows))
b.out += b"%d 0 obj\n" % xref_id + (
    b"<</Type/XRef/Size %d/Root %d 0 R/W[1 4 2]/Filter/FlateDecode/Length %d>>"
    % (count, root_id, len(data))
) + b"\nstream\n" + data + b"\nendstream\nendobj\n"
b.out += b"startxref\n%d\n%%%%EOF\n" % xref_at
write("object-stream", bytes(b.out))

# --- filters --------------------------------------------------------------
for name, kind in [
    ("filter-lzw", "lzw"),
    ("filter-ascii85", "a85"),
    ("filter-chained", "a85+flate"),
    ("filter-none", "none"),
]:
    b = Builder()
    write(name, classic_trailer(b, base_document(b, content_filter=kind)))

# --- indirect /Length -----------------------------------------------------
b = Builder()
data = flate(CONTENT)
length_id = b.reserve()
content_id = b.add(
    b"<</Filter/FlateDecode/Length %d 0 R>>\nstream\n" % length_id + data + b"\nendstream"
)
b.add(b"%d" % len(data), length_id)
font_id = b.add(SIMPLE_FONT)
page_id, pages_id = b.reserve(), b.reserve()
b.add(
    b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
    b"/Resources<</Font<</F1 %d 0 R>>>>/Contents %d 0 R>>" % (pages_id, font_id, content_id),
    page_id,
)
b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % page_id, pages_id)
root = b.add(b"<</Type/Catalog/Pages %d 0 R>>" % pages_id)
write("indirect-length", classic_trailer(b, root))

# --- CID / Type0 font -----------------------------------------------------
CID_CMAP = b"""/CIDInit /ProcSet findresource begin
12 dict begin begincmap
1 begincodespacerange <0000> <FFFF> endcodespacerange
2 beginbfrange
<0001> <0003> <0041>
<0004> <0004> <00660066>
endbfrange
endcmap CMapName currentdict /CMap defineresource pop end end"""

b = Builder()
tounicode_id = b.stream(b"/Filter/FlateDecode", flate(CID_CMAP))
descendant_id = b.reserve()
cid_font = (
    b"<</Type/Font/Subtype/Type0/BaseFont/Subset+CIDFont/Encoding/Identity-H"
    b"/DescendantFonts[%d 0 R]/ToUnicode %d 0 R>>" % (descendant_id, tounicode_id)
)
b.add(
    b"<</Type/Font/Subtype/CIDFontType2/BaseFont/Subset+CIDFont"
    b"/CIDSystemInfo<</Registry(Adobe)/Ordering(Identity)/Supplement 0>>"
    b"/DW 1000/W[1 [600 700 800] 4 4 900]>>",
    descendant_id,
)
# Two-byte codes: CIDs 1,2,3 then the ligature at 4.
cid_content = (
    b"BT /F1 18 Tf 72 700 Td <000100020003> Tj ET\n"
    b"BT /F1 10 Tf 72 670 Td <0004> Tj ET\n"
)
content_id = b.stream(b"/Filter/FlateDecode", flate(cid_content))
font_id = b.add(cid_font)
page_id, pages_id = b.reserve(), b.reserve()
b.add(
    b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
    b"/Resources<</Font<</F1 %d 0 R>>>>/Contents %d 0 R>>" % (pages_id, font_id, content_id),
    page_id,
)
b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % page_id, pages_id)
root = b.add(b"<</Type/Catalog/Pages %d 0 R>>" % pages_id)
write("cid-font", classic_trailer(b, root))

# --- content-stream shapes ------------------------------------------------
SHAPES = b"""q 1 0 0 1 0 0 cm
BT /F1 12 Tf 100 700 Td (nested state) Tj ET
q 2 0 0 2 0 0 cm BT /F1 12 Tf 50 350 Td (scaled by cm) Tj ET Q
Q
BT /F1 12 Tf 100 650 Td 50 Tz (condensed) Tj 100 Tz ET
BT /F1 12 Tf 100 630 Td 3 Ts (raised) Tj 0 Ts ET
BT /F1 12 Tf 2 Tc 1 Tw 100 610 Td (spaced out) Tj 0 Tc 0 Tw ET
BT /F1 12 Tf 100 590 Td 14 TL (first line) ' (second line) ' ET
BT /F1 12 Tf 100 550 Td 1 2 (aw ac quoted) " ET
BT /F1 12 Tf 100 530 Td (invisible) Tj 3 Tr (hidden) Tj 0 Tr ET
BI /W 1 /H 1 /BPC 8 /CS /G ID \x00 EI
BT /F1 12 Tf 100 510 Td (after inline image) Tj ET
"""
b = Builder()
write("content-shapes", classic_trailer(b, base_document(b, content=SHAPES)))

# Multiple content streams that concatenate into one page.
b = Builder()
c1 = b.stream(b"/Filter/FlateDecode", flate(b"BT /F1 12 Tf 72 700 Td (part one) Tj ET\n"))
c2 = b.stream(b"/Filter/FlateDecode", flate(b"BT /F1 12 Tf 72 680 Td (part two) Tj ET\n"))
font_id = b.add(SIMPLE_FONT)
page_id, pages_id = b.reserve(), b.reserve()
b.add(
    b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
    b"/Resources<</Font<</F1 %d 0 R>>>>/Contents[%d 0 R %d 0 R]>>"
    % (pages_id, font_id, c1, c2),
    page_id,
)
b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % page_id, pages_id)
root = b.add(b"<</Type/Catalog/Pages %d 0 R>>" % pages_id)
write("content-array", classic_trailer(b, root))

# --- multi-column ---------------------------------------------------------
COLUMNS = b"".join(
    b"BT /F1 10 Tf %d %d Td (%s) Tj ET\n" % (x, y, label)
    for y in range(700, 600, -14)
    for x, label in ((72, b"left column text"), (340, b"right column text"))
)
b = Builder()
write("two-column", classic_trailer(b, base_document(b, content=COLUMNS)))

# --- incremental update / Prev chain -------------------------------------
b = Builder()
root = base_document(b)
first = classic_trailer(b, root)
# Append a second revision that replaces the page's content.
out = bytearray(first)
prev_xref = first.rfind(b"startxref")
prev_offset = int(first[prev_xref + 9 : first.find(b"%%EOF", prev_xref)].strip())
new_content = flate(b"BT /F1 14 Tf 72 700 Td (revised content) Tj ET\n")
new_id = b.next_id
off = len(out)
out += b"%d 0 obj\n<</Filter/FlateDecode/Length %d>>\nstream\n" % (new_id, len(new_content))
out += new_content + b"\nendstream\nendobj\n"
xref_at = len(out)
out += b"xref\n0 1\n0000000000 65535 f \n%d 1\n%010d 00000 n \n" % (new_id, off)
out += b"trailer\n<</Size %d/Root %d 0 R/Prev %d>>\n" % (new_id + 1, root, prev_offset)
out += b"startxref\n%d\n%%%%EOF\n" % xref_at
write("incremental-update", bytes(out))

# --- malformed ------------------------------------------------------------
b = Builder()
good = classic_trailer(b, base_document(b))
# An xref whose offsets are all wrong: the reader must not invent objects.
write("bad-xref-offsets", good.replace(b"0000000009", b"0000009999"))
write("truncated", good[: len(good) // 2])
write("no-startxref", good.replace(b"startxref", b"startxrefX"))
write("garbage-header", b"not a pdf at all\n" + good[20:])

b = Builder()
root = base_document(b)
data = flate(CONTENT)
# A stream whose /Length lies: recovery must find `endstream`.
b.offsets[b.next_id] = len(b.out)
lying = b.next_id
b.next_id += 1
b.out += b"%d 0 obj\n<</Filter/FlateDecode/Length 999999>>\nstream\n" % lying
b.out += data + b"\nendstream\nendobj\n"
write("lying-length", classic_trailer(b, root))



# --- annotations and form fields -----------------------------------------
b = Builder()
write("annotations", classic_trailer(b, annotated_document(b)))

# --- graphics paths -------------------------------------------------------
#
# The path machinery had nothing exercising it. The reference hands out one
# `rects` list whose contents depend on what the page drew: `re` rectangles
# when there are any, otherwise filled-subpath rects, otherwise clip rects.
# These three files pick one branch each so all three are compared.

# `re` rectangles — painted by fill and by stroke, plus one used only as a
# clip path, which draws no ink. Also `m`/`l`/`h`/`S` strokes and a `cm` that
# scales what follows.
GRAPHICS_RECTS = b"""q
2 w
100 700 200 20 re f
100 660 200 20 re S
100 620 200 20 re W n
150 600 m 350 600 l S
150 580 m 350 580 l 350 560 l h S
q 2 0 0 2 0 0 cm 50 250 100 10 re f Q
Q
BT /F1 12 Tf 100 500 Td (text beside the rules) Tj ET
"""
b = Builder()
write("graphics-rects", classic_trailer(b, base_document(b, content=GRAPHICS_RECTS)))

# No `re` at all, so the reference falls through to filled-subpath rects: a
# four-segment closed subpath, a three-segment one whose closing edge is
# implied, and a non-rectangular quadrilateral that must be rejected.
GRAPHICS_FILLS = b"""q
100 700 m 300 700 l 300 720 l 100 720 l h f
100 660 m 300 660 l 300 680 l h f
100 600 m 300 610 l 290 640 l 110 630 l h f
Q
BT /F1 12 Tf 100 500 Td (filled shapes) Tj ET
"""
b = Builder()
write("graphics-fills", classic_trailer(b, base_document(b, content=GRAPHICS_FILLS)))

# No `re` and no fills, so clip rectangles surface. Four of them, since the
# reference wants at least four before it trusts them.
GRAPHICS_CLIPS = b"""q
100 700 m 300 700 l 300 720 l 100 720 l h W n
Q q
100 660 m 300 660 l 300 680 l 100 680 l h W n
Q q
100 620 m 300 620 l 300 640 l 100 640 l h W n
Q q
100 580 m 300 580 l 300 600 l 100 600 l h W n
Q
BT /F1 12 Tf 100 500 Td (clipped regions) Tj ET
"""
b = Builder()
write("graphics-clips", classic_trailer(b, base_document(b, content=GRAPHICS_CLIPS)))


# --- underlines and rulings -----------------------------------------------
#
# Telling an underline from a table ruling is most of underline.rs, so the
# corpus needs one file per branch of that decision.

# A stroked rule just under a baseline underlines; a rule through the glyphs
# strikes out; a thin filled rect underlines the same way a stroke does; text
# with no rule near it is left alone.
UNDERLINE_BASIC = b"""q 0.5 w
BT /F1 12 Tf 100 700 Td (underlined by a stroke) Tj ET
100 697 m 220 697 l S
BT /F1 12 Tf 100 660 Td (struck through) Tj ET
100 664 m 180 664 l S
BT /F1 12 Tf 100 620 Td (underlined by a rect) Tj ET
100 616 110 1 re f
BT /F1 12 Tf 100 580 Td (plain text) Tj ET
Q
"""
b = Builder()
write("underline-basic", classic_trailer(b, base_document(b, content=UNDERLINE_BASIC)))

# Full-width rules repeating down the page under short cell labels are table
# rulings — the repetition check must discard every one of them.
UNDERLINE_TABLE = b"""q 0.5 w
BT /F1 12 Tf 100 700 Td (row one) Tj ET
100 694 m 500 694 l S
BT /F1 12 Tf 100 660 Td (row two) Tj ET
100 654 m 500 654 l S
BT /F1 12 Tf 100 620 Td (row three) Tj ET
100 614 m 500 614 l S
BT /F1 12 Tf 100 580 Td (row four) Tj ET
100 574 m 500 574 l S
Q
"""
b = Builder()
write("underline-table", classic_trailer(b, base_document(b, content=UNDERLINE_TABLE)))

# Separated segments on one row are per-column header separators, whatever
# their snugness.
UNDERLINE_SEGMENTED = b"""q 0.5 w
BT /F1 12 Tf 100 700 Td (alpha) Tj ET
BT /F1 12 Tf 200 700 Td (beta) Tj ET
BT /F1 12 Tf 300 700 Td (gamma) Tj ET
100 694 m 140 694 l S
200 694 m 230 694 l S
300 694 m 345 694 l S
Q
"""
b = Builder()
write("underline-segmented", classic_trailer(b, base_document(b, content=UNDERLINE_SEGMENTED)))

# A short bar with a numerator above and a denominator hugging it below is a
# fraction, not an underline.
UNDERLINE_FRACTION = b"""q 0.5 w
BT /F1 12 Tf 100 700 Td (12) Tj ET
100 696 m 118 696 l S
BT /F1 12 Tf 100 683 Td (34) Tj ET
Q
"""
b = Builder()
write("underline-fraction", classic_trailer(b, base_document(b, content=UNDERLINE_FRACTION)))


# --- fragment merging ---------------------------------------------------
#
# A PDF does not draw words. These are the shapes the merge pass has to put
# back together: a word split across several Tj at explicit positions, a
# letterspaced all-caps run drawn a glyph at a time, a chemical subscript,
# and a footnote superscript. The simple-font glyph advance is 6pt at 12pt.
MERGE_FRAGMENTS = b"""BT /F1 12 Tf 100 700 Td (Hel) Tj 18 0 Td (lo) Tj 12 0 Td (wor) Tj 18 0 Td (ld) Tj ET
BT /F1 12 Tf 100 670 Td (T) Tj 9 0 Td (R) Tj 9 0 Td (A) Tj 9 0 Td (C) Tj 9 0 Td (K) Tj ET
BT /F1 12 Tf 100 640 Td (H) Tj ET
BT /F1 6 Tf 106 638 Td (2) Tj ET
BT /F1 12 Tf 109 640 Td (O) Tj ET
BT /F1 12 Tf 100 610 Td (note) Tj ET
BT /F1 6 Tf 124 614 Td (3) Tj ET
BT /F1 12 Tf 100 580 Td (far) Tj 60 0 Td (apart) Tj ET
"""
b = Builder()
write("merge-fragments", classic_trailer(b, base_document(b, content=MERGE_FRAGMENTS)))


# The threshold branches of the merge loop, one line each: a lowercase pair
# (wider 0.13em threshold), a mixed-case pair (0.08em), joining punctuation
# (0.25em, never spaced), a gap just past the 0.5em merge limit, a backward
# jump past -0.5em, and a size change outside the 20% band.
MERGE_THRESHOLDS = b"""BT /F1 12 Tf 100 700 Td (ab) Tj 13.2 0 Td (cd) Tj ET
BT /F1 12 Tf 100 670 Td (AB) Tj 13.2 0 Td (cd) Tj ET
BT /F1 12 Tf 100 640 Td (word) Tj 26 0 Td (.) Tj ET
BT /F1 12 Tf 100 610 Td (near) Tj 29 0 Td (far) Tj ET
BT /F1 12 Tf 100 580 Td (one) Tj -30 0 Td (two) Tj ET
BT /F1 12 Tf 100 550 Td (big) Tj ET
BT /F1 8 Tf 118 550 Td (small) Tj ET
"""
b = Builder()
write("merge-thresholds", classic_trailer(b, base_document(b, content=MERGE_THRESHOLDS)))


# --- the markdown path ----------------------------------------------------
#
# Everything above stresses the *object layer*: xref shapes, filters, object
# streams. Those files convert byte-identically largely because their text is
# trivial. The files below stress the other half — the passes that turn
# positioned glyphs into Markdown — so the end-to-end comparison covers
# headings, lists, captions, code, tables, and the multi-page bookkeeping.

def font_named(name):
    return (
        b"<</Type/Font/Subtype/Type1/BaseFont/" + name
        + b"/FirstChar 32/LastChar 126/Widths [%s]>>"
        % b" ".join(b"500" for _ in range(95))
    )


BOLD_FONT = font_named(b"Helvetica-Bold")
ITALIC_FONT = font_named(b"Helvetica-Oblique")
MONO_FONT = font_named(b"Courier")


def styled_document(b, content, fonts=None):
    """One page whose resources carry several fonts: F1 plain, F2 bold, F3
    italic, F4 monospace."""
    fonts = fonts or [SIMPLE_FONT, BOLD_FONT, ITALIC_FONT, MONO_FONT]
    content_id = b.stream(b"/Filter/FlateDecode", flate(content))
    ids = [b.add(font) for font in fonts]
    resources = b"".join(
        b"/F%d %d 0 R" % (index + 1, font_id) for index, font_id in enumerate(ids)
    )
    page_id = b.reserve()
    pages_id = b.reserve()
    b.add(
        b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
        b"/Resources<</Font<<%s>>>>/Contents %d 0 R>>" % (pages_id, resources, content_id),
        page_id,
    )
    b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % page_id, pages_id)
    return b.add(b"<</Type/Catalog/Pages %d 0 R>>" % pages_id)


def paged_document(b, pages):
    """Several pages sharing one font, each with its own content stream."""
    font_id = b.add(SIMPLE_FONT)
    pages_id = b.reserve()
    page_ids = []
    for content in pages:
        content_id = b.stream(b"/Filter/FlateDecode", flate(content))
        page_ids.append(
            b.add(
                b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
                b"/Resources<</Font<</F1 %d 0 R>>>>/Contents %d 0 R>>"
                % (pages_id, font_id, content_id)
            )
        )
    kids = b" ".join(b"%d 0 R" % pid for pid in page_ids)
    b.add(b"<</Type/Pages/Kids[%s]/Count %d>>" % (kids, len(page_ids)), pages_id)
    return b.add(b"<</Type/Catalog/Pages %d 0 R>>" % pages_id)


def line(text, y, size=10, x=72, font=1):
    return b"BT /F%d %d Tf %d %d Td (%s) Tj ET\n" % (font, size, x, y, text)


# Heading tiers: four sizes over body text, so `compute_heading_tiers` has a
# ladder to find and `detect_header_level` a ratio to place each on.
MD_HEADINGS = (
    line(b"Document Title", 720, 24)
    + line(b"Section One", 690, 18)
    + line(b"Subsection", 665, 14)
    + line(b"Body text under the subsection heading.", 645)
    + line(b"A second line of body text.", 631)
    + line(b"Section Two", 600, 18)
    + line(b"More body text follows the second section.", 580)
)
b = Builder()
write("md-headings", classic_trailer(b, base_document(b, content=MD_HEADINGS)))

# Lists: a bullet, a numbered item, a wrapped continuation indented to the
# item's text, and a paragraph that ends the list.
MD_LISTS = (
    line(b"Shopping", 720, 18)
    + line(b"- first bullet item", 690)
    + line(b"continues on the next line", 676, x=78)
    + line(b"- second bullet item", 662)
    + line(b"1. numbered item one", 640)
    + line(b"2. numbered item two", 626)
    + line(b"A closing paragraph well below the list.", 580)
)
b = Builder()
write("md-lists", classic_trailer(b, base_document(b, content=MD_LISTS)))

# Captions and a table of contents: `is_caption_line` and the dot-leader
# rows, which must not run together into one paragraph.
MD_CAPTIONS = (
    line(b"Figure 1: a caption line", 720)
    + line(b"Body text after the caption.", 700)
    + line(b"Table 2. Another caption", 670)
    + line(b"Contents", 630, 18)
    + line(b"Chapter One .......... 5", 600)
    + line(b"Chapter Two .......... 9", 586)
)
b = Builder()
write("md-captions", classic_trailer(b, base_document(b, content=MD_CAPTIONS)))

# Emphasis and code: bold, italic and monospace runs, the last of which
# becomes a fenced block.
MD_STYLES = (
    line(b"Plain body text here.", 720)
    + line(b"Bold heading line", 700, 12, font=2)
    + line(b"italic words here", 686, 10, font=3)
    + line(b"let x = 1", 660, 10, font=4)
    + line(b"let y = 2", 646, 10, font=4)
    + line(b"Ordinary prose after the code block.", 610)
)
b = Builder()
write("md-styles", classic_trailer(b, styled_document(b, MD_STYLES)))

# A drop cap: one outsized capital that belongs to the front of the line
# below it, and which must not define a heading tier of its own.
MD_DROPCAP = (
    line(b"Chapter One", 720, 14)
    + line(b"nce upon a time there was a document", 690)
    + line(b"that began with an outsized letter.", 676)
    + b"BT /F1 30 Tf 60 686 Td (O) Tj ET\n"
)
b = Builder()
write("md-dropcap", classic_trailer(b, base_document(b, content=MD_DROPCAP)))

# Three pages sharing a running header and footer, which
# `strip_repeated_lines` must remove from all but the first — and a page
# number in the footer, so the normalisation that ignores trailing digits is
# exercised too.
MD_PAGES = [
    line(b"Annual Report of the Commission", 760)
    + b"".join(
        line(b"body line %d on page %d with plenty of text" % (row, page), 700 - row * 14)
        for row in range(8)
    )
    + line(b"Confidential Working Draft %d" % page, 40)
    for page in range(1, 4)
]
b = Builder()
write("md-multipage", classic_trailer(b, paged_document(b, MD_PAGES)))

# A hyphenated word broken across lines, a bare URL, and a standalone page
# number — three of `clean_markdown`'s passes.
MD_CLEANUP = (
    line(b"A paragraph ending in a hyphen-", 720)
    + line(b"ated word that continues here.", 706)
    + line(b"See https://example.test/page for more.", 670)
    + line(b"7", 40)
)
b = Builder()
write("md-cleanup", classic_trailer(b, base_document(b, content=MD_CLEANUP)))

# A bordered table: `re` rectangles forming a two-by-three grid with text in
# each cell, which the rect detector should grid.
MD_TABLE_RECTS = b"".join(
    b"%d %d 120 20 re S\n" % (72 + column * 120, 700 - row * 20)
    for row in range(3)
    for column in range(2)
) + b"".join(
    line(b"cell %d%d" % (row, column), 706 - row * 20, x=78 + column * 120)
    for row in range(3)
    for column in range(2)
)
b = Builder()
write("md-table-rects", classic_trailer(b, base_document(b, content=MD_TABLE_RECTS)))

# A ruled table: horizontal and vertical strokes rather than rectangles, so
# the line detector is the one that has to find it.
MD_TABLE_LINES = (
    b"".join(b"72 %d m 312 %d l S\n" % (700 - row * 20, 700 - row * 20) for row in range(4))
    + b"".join(b"%d 700 m %d 640 l S\n" % (72 + col * 120, 72 + col * 120) for col in range(3))
    + b"".join(
        line(b"r%dc%d" % (row, column), 686 - row * 20, x=78 + column * 120)
        for row in range(3)
        for column in range(2)
    )
)
b = Builder()
write("md-table-lines", classic_trailer(b, base_document(b, content=MD_TABLE_LINES)))


# --- documents aimed at the *unported* stages ------------------------------
#
# The files above pass. These are built to fail, or to prove they do not: each
# targets a stage this port has not wired to a document — form XObjects,
# structure-tree tagging, chart masking, side-by-side bands — so the
# end-to-end comparison measures the gap instead of leaving it unexamined.

# Text inside a Form XObject, invoked with `Do`. The content stream the page
# names holds no glyphs at all.
def xobject_document(b):
    inner = b.stream(
        b"/Type/XObject/Subtype/Form/BBox[0 0 612 792]/Filter/FlateDecode",
        flate(line(b"text drawn inside a form xobject", 700)),
    )
    content_id = b.stream(
        b"/Filter/FlateDecode",
        flate(line(b"text drawn by the page itself", 730) + b"q /X0 Do Q\n"),
    )
    font_id = b.add(SIMPLE_FONT)
    page_id = b.reserve()
    pages_id = b.reserve()
    b.add(
        b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
        b"/Resources<</Font<</F1 %d 0 R>>/XObject<</X0 %d 0 R>>>>/Contents %d 0 R>>"
        % (pages_id, font_id, inner, content_id),
        page_id,
    )
    b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % page_id, pages_id)
    return b.add(b"<</Type/Catalog/Pages %d 0 R>>" % pages_id)


b = Builder()
write("gap-xobject-text", classic_trailer(b, xobject_document(b)))


# A tagged document: a structure tree marking one line as H1 and one as a
# list item, with the content stream's marked-content ids to match. The
# visual heuristics alone would read both as ordinary text.
def tagged_document(b):
    content = (
        b"/P <</MCID 0>> BDC\n" + line(b"Tagged As A Heading", 720) + b"EMC\n"
        b"/P <</MCID 1>> BDC\n" + line(b"tagged as a list item", 690) + b"EMC\n"
        + line(b"untagged body text follows", 660)
    )
    content_id = b.stream(b"/Filter/FlateDecode", flate(content))
    font_id = b.add(SIMPLE_FONT)
    page_id = b.reserve()
    pages_id = b.reserve()
    struct_root = b.reserve()
    heading = b.add(
        b"<</Type/StructElem/S/H1/P %d 0 R/Pg %d 0 R/K 0>>" % (struct_root, page_id))
    listitem = b.add(
        b"<</Type/StructElem/S/LI/P %d 0 R/Pg %d 0 R/K 1>>" % (struct_root, page_id))
    b.add(
        b"<</Type/StructTreeRoot/K[%d 0 R %d 0 R]>>" % (heading, listitem), struct_root)
    b.add(
        b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
        b"/Resources<</Font<</F1 %d 0 R>>>>/Contents %d 0 R/StructParents 0>>"
        % (pages_id, font_id, content_id),
        page_id,
    )
    b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % page_id, pages_id)
    return b.add(
        b"<</Type/Catalog/Pages %d 0 R/StructTreeRoot %d 0 R>>" % (pages_id, struct_root))


b = Builder()
write("gap-tagged", classic_trailer(b, tagged_document(b)))

# A bar chart: filled rectangles with value labels over them, beside prose.
# The rects read as cell borders and the labels as aligned columns, so
# without chart masking the whole page grids into a phantom table.
GAP_CHART = (
    b"".join(
        b"%d 600 40 %d re f\n" % (100 + index * 60, 30 + index * 25) for index in range(5)
    )
    + b"".join(
        line(b"%d" % (10 + index * 5), 590, x=110 + index * 60) for index in range(5)
    )
    + line(b"Quarterly Revenue", 700, 14)
    + b"".join(
        line(b"a line of prose beneath the chart number %d" % row, 540 - row * 14)
        for row in range(6)
    )
)
b = Builder()
write("gap-chart", classic_trailer(b, base_document(b, content=GAP_CHART)))

# Two prose columns with a wide gutter and no alignment between them — a
# newspaper layout, not a table. Reading order must run down the left column
# then down the right, and `split_side_by_side` is what decides that.
GAP_NEWSPAPER = b"".join(
    line(b"left column sentence number %d here" % row, 700 - row * 14, x=72)
    for row in range(10)
) + b"".join(
    line(b"right column sentence number %d" % row, 700 - row * 14 - 7, x=330)
    for row in range(10)
)
b = Builder()
write("gap-newspaper", classic_trailer(b, base_document(b, content=GAP_NEWSPAPER)))

# Text under a rotated CTM, which the extractor has to place through the
# matrix rather than by its Td offsets alone.
GAP_ROTATED = (
    line(b"upright text on the page", 720)
    + b"q 0 1 -1 0 400 200 cm\n" + line(b"rotated ninety degrees", 0, x=0) + b"Q\n"
)
b = Builder()
write("gap-rotated", classic_trailer(b, base_document(b, content=GAP_ROTATED)))


print("generated %d pdfs in %s" % (len([f for f in os.listdir(OUT) if f.endswith(".pdf")]), OUT))
