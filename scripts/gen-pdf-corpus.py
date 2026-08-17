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


# The documents below were written to a `detector/` subdirectory in wave 121,
# because the reference's detector calls an image-backed page scanned and
# emits no Markdown while this port — then having no detector — extracted
# whatever text was there. Wave 123 wired the detector into the pipeline and
# all eight began matching, so the subdirectory is gone and they are ordinary
# corpus documents again.


def image_xobject(b, width, height):
    """A minimal image XObject. The detector reads only /Width and /Height,
    so the sample data is deliberately far too short for the dimensions —
    nothing decodes it."""
    return b.stream(
        b"/Type/XObject/Subtype/Image/Width %d/Height %d"
        b"/ColorSpace/DeviceGray/BitsPerComponent 8" % (width, height),
        b"\x00" * 16,
    )


def image_page(b, xobjects, content_extra=b"", text=b"Page with images."):
    """One page whose /XObject dictionary holds `xobjects` (name -> id)."""
    entries = b"".join(b"/%s %d 0 R" % (n, i) for n, i in xobjects)
    draws = b"".join(
        b"q 100 0 0 80 %d %d cm /%s Do Q\n" % (72 + (k % 4) * 110, 500 - (k // 4) * 90, n)
        for k, (n, _) in enumerate(xobjects)
    )
    font = b.add(SIMPLE_FONT)
    content = b.stream(b"", line(text, 700) + draws + content_extra)
    page = b.reserve()
    pages = b.reserve()
    b.add(
        b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
        b"/Resources<</Font<</F1 %d 0 R>>/XObject<<%s>>>>/Contents %d 0 R>>"
        % (pages, font, entries, content),
        page,
    )
    b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % page, pages)
    return b.add(b"<</Type/Catalog/Pages %d 0 R>>" % pages)


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


def tagged_table_document(b, sparse=False):
    """A document whose structure tree declares a table: /Table > /TR > /TD,
    with marked-content ids tying each cell to the text that draws it. The
    author's declaration is what the reference believes ahead of any
    geometric guess."""
    rows, columns = 3, 2
    content = b""
    mcid = 0
    for row in range(rows):
        for column in range(columns):
            content += (
                b"/P <</MCID %d>> BDC\n" % mcid
                # Deliberately **ragged**: no two rows share a column x, so
                # the alignment heuristic cannot find this grid and only the
                # author's own tagging can. A regularly-spaced tagged table
                # is silently carried by the heuristic detector and tests
                # nothing.
                + line(b"r%dc%d" % (row, column), 700 - row * 20,
                       x=72 + column * 120 + row * 37)
                + b"EMC\n"
            )
            mcid += 1
    if sparse:
        # Enough untagged prose to push the tagged table under the
        # reference's 50% coverage gate, which then discards it entirely.
        for index in range(10):
            content += line(
                b"Paragraph number %d, which is not part of any table." % index,
                580 - index * 16)
    else:
        content += line(b"A paragraph well below the tagged table.", 580)

    content_id = b.stream(b"/Filter/FlateDecode", flate(content))
    font_id = b.add(SIMPLE_FONT)
    page_id = b.reserve()
    pages_id = b.reserve()
    struct_root = b.reserve()
    table_id = b.reserve()

    row_ids = []
    mcid = 0
    for row in range(rows):
        cell_ids = []
        for _ in range(columns):
            cell_ids.append(
                b.add(b"<</Type/StructElem/S/TD/P %d 0 R/Pg %d 0 R/K %d>>"
                      % (table_id, page_id, mcid)))
            mcid += 1
        kids = b" ".join(b"%d 0 R" % cid for cid in cell_ids)
        row_ids.append(
            b.add(b"<</Type/StructElem/S/TR/P %d 0 R/Pg %d 0 R/K[%s]>>"
                  % (table_id, page_id, kids)))
    table_kids = b" ".join(b"%d 0 R" % rid for rid in row_ids)
    b.add(b"<</Type/StructElem/S/Table/P %d 0 R/Pg %d 0 R/K[%s]>>"
          % (struct_root, page_id, table_kids), table_id)
    b.add(b"<</Type/StructTreeRoot/K[%d 0 R]>>" % table_id, struct_root)

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
write("tagged-table", classic_trailer(b, tagged_table_document(b)))

b = Builder()
write("tagged-table-sparse", classic_trailer(b, tagged_table_document(b, sparse=True)))


# A calendar: seven columns of day boxes, ragged at both ends — the first week
# starts on a Wednesday and the last stops on a Tuesday — so the rect grid
# detector declines and leaves a *hint* instead. That hint is what stage 3,
# `try_build_rect_guided_table`, is for. The day numbers of each week are drawn
# as **one** text run, which is also what `split_merged_numbers` exists to undo.
#
# The geometry is tuned to the three conditions a large-cluster hint needs, all
# of which the first attempt missed: boxes within **3pt** of each other so they
# cluster at all, at least **30** of them, and a bounding box no wider than
# **400pt**. Seven 50pt columns over six weeks is 350 × 240 and 34 boxes.
CAL_X0, CAL_COLUMN, CAL_Y0, CAL_ROW = 72, 50, 640, 40
_cal_boxes = []
_cal_text = []
_day = 1
for _week in range(6):
    _first = 3 if _week == 0 else 0
    _last = 2 if _week == 5 else 6
    _run = []
    for _column in range(_first, _last + 1):
        # Wednesday of week 3 is a holiday and draws no box at all, which is
        # the gap the boundary interpolation has to put back.
        if not (_week == 3 and _column == 3):
            _cal_boxes.append(
                b"%d %d %d %d re S\n"
                % (CAL_X0 + _column * CAL_COLUMN, CAL_Y0 - _week * CAL_ROW,
                   CAL_COLUMN - 1, CAL_ROW - 1))
        _run.append(b"%d" % _day)
        _day += 1
    _cal_text.append(
        line(b" ".join(_run), CAL_Y0 - _week * CAL_ROW + CAL_ROW - 12,
             x=CAL_X0 + _first * CAL_COLUMN + 3))

MD_CALENDAR = b"".join(_cal_boxes) + b"".join(_cal_text)
b = Builder()
write("rect-guided-calendar", classic_trailer(b, base_document(b, content=MD_CALENDAR)))


# Two columns of prose with aligned baselines — a newsletter, or any
# two-up layout. Shown to a table detector all at once this is a perfect
# two-column grid, so an unbanded cascade emits a table where there is only
# prose. `split_side_by_side` finds the gutter and the two flows are read
# independently.
# Twenty rows, because `split_side_by_side` wants at least forty runs on the
# page and twenty to either side of the gutter — a nine-row draft of this file
# produced no split at all, and so tested nothing. The lines are short so that
# none of them straddles the gutter.
MD_TWO_COLUMNS = b"".join(
    line(b"Left line %d here." % row, 700 - row * 18, x=72)
    + line(b"Right line %d here." % row, 700 - row * 18, x=330)
    for row in range(20)
)
b = Builder()
write("two-column-prose", classic_trailer(b, base_document(b, content=MD_TWO_COLUMNS)))


# A table whose cells are drawn as filled **paths** — `m`/`l`/`h`/`f`, with no
# `re` operator anywhere. The page therefore contributes nothing to the `re`
# rectangle list, and a detector fed that list directly sees no table at all.
# The reference substitutes its fill rectangles for the empty list inside the
# extractor, which is what `pdfSelectedRectangles` reproduces.
#
# A first draft drew the cells as `re W n` clip regions instead, and proved
# nothing: `re` is recorded unconditionally, painted or clipped, so the
# rectangle list was never empty and the substitution never ran.
def _cell_path(x, y, w, h):
    return (b"%d %d m %d %d l %d %d l %d %d l h f\n"
            % (x, y, x + w, y, x + w, y + h, x, y + h))


# The text is set at **ragged** x positions — each row shifted — so the
# alignment heuristic cannot grid it and only the filled cells can. A first
# draft used a tidy 2x3 grid and matched with the substitution removed,
# because six items are exactly the heuristic's minimum and it found the
# table from the text alone.
MD_PATH_TABLE = b"".join(
    _cell_path(72 + column * 120, 700 - row * 22, 118, 20)
    for row in range(4)
    for column in range(3)
) + b"".join(
    line(b"c%d%d" % (row, column), 706 - row * 22, x=76 + column * 120 + row * 26)
    for row in range(4)
    for column in range(3)
)
b = Builder()
write("path-drawn-table", classic_trailer(b, base_document(b, content=MD_PATH_TABLE)))


# --- documents for the detector's font verdicts ----------------------------
#
# Every document above answers the three usage-based font questions
# identically — one font, decodable — so none of them tests the layer. These
# four separate the branches.

def detector_font_document(b, font_body, extra_objects=b"", content=None):
    """A one-page document whose single /F1 is whatever `font_body` says."""
    font_id = b.add(font_body)
    body = content if content is not None else line(b"Sample text on the page.", 700)
    content_id = b.stream(b"/Filter/FlateDecode", flate(body))
    page_id = b.reserve()
    pages_id = b.reserve()
    b.add(
        b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
        b"/Resources<</Font<</F1 %d 0 R>>>>/Contents %d 0 R>>"
        % (pages_id, font_id, content_id),
        page_id,
    )
    b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % page_id, pages_id)
    return b.add(b"<</Type/Catalog/Pages %d 0 R>>" % pages_id)


# 1. Identity-H, no /ToUnicode, and a /W array whose CIDs are low — a real
#    subset. Nothing can decode this, so it is the OCR case.
b = Builder()
_desc = b.add(
    b"<</Type/Font/Subtype/CIDFontType2/BaseFont/Sub+Test"
    b"/CIDSystemInfo<</Registry(Adobe)/Ordering(Identity)/Supplement 0>>"
    b"/DW 500/W [1 [500 500 500 500 500]]>>"
)
write("detector-identityh-bare", classic_trailer(b, detector_font_document(
    b,
    b"<</Type/Font/Subtype/Type0/BaseFont/Sub+Test/Encoding/Identity-H"
    b"/DescendantFonts[%d 0 R]>>" % _desc,
)))

# 2. The same font, but with /W CIDs up at Unicode letter values. Chromium
#    and wkhtmltopdf emit this, and the text extracts correctly with no
#    /ToUnicode at all — so the fallback finds it decodable.
b = Builder()
_desc = b.add(
    b"<</Type/Font/Subtype/CIDFontType2/BaseFont/Test"
    b"/CIDSystemInfo<</Registry(Adobe)/Ordering(Identity)/Supplement 0>>"
    b"/DW 500/W [72 [500 500 500 500 500 500 500 500]]>>"
)
write("detector-identityh-unicode-w", classic_trailer(b, detector_font_document(
    b,
    b"<</Type/Font/Subtype/Type0/BaseFont/Test/Encoding/Identity-H"
    b"/DescendantFonts[%d 0 R]>>" % _desc,
)))

# 3. A Type 3 font with no /ToUnicode: each glyph is a drawing procedure, so
#    the character codes mean nothing outside the font.
b = Builder()
_proc = b.stream(b"", b"10 0 0 0 10 10 d1\n0 0 10 10 re f\n")
_charprocs = b.add(b"<</square %d 0 R>>" % _proc)
_encoding = b.add(b"<</Type/Encoding/Differences[97/square]>>")
write("detector-type3-only", classic_trailer(b, detector_font_document(
    b,
    b"<</Type/Font/Subtype/Type3/FontBBox[0 0 10 10]/FontMatrix[0.001 0 0 0.001 0 0]"
    b"/CharProcs %d 0 R/Encoding %d 0 R/FirstChar 97/LastChar 97/Widths[10]>>"
    % (_charprocs, _encoding),
)))

# 4. An undecodable Identity-H font *alongside* a readable one: the `and
#    nothing else` clause of the Identity-H verdict, which a check that
#    merely looked for a bad font would get wrong.
#
#    Withdrawn in wave 119 and restored in wave 120. Its `<0001> Tj` used to
#    reach the decode chain's last resort, which rendered the bytes as their
#    own code points and put a literal NUL and SOH into the Markdown. The
#    reference drops every byte below 0x20, so the run yields nothing at all
#    — which is also what makes this document a regression test for that.
b = Builder()
_desc = b.add(
    b"<</Type/Font/Subtype/CIDFontType2/BaseFont/Sub+Test"
    b"/CIDSystemInfo<</Registry(Adobe)/Ordering(Identity)/Supplement 0>>"
    b"/DW 500/W [1 [500 500 500]]>>"
)
_bad = b.add(
    b"<</Type/Font/Subtype/Type0/BaseFont/Sub+Test/Encoding/Identity-H"
    b"/DescendantFonts[%d 0 R]>>" % _desc
)
_good = b.add(SIMPLE_FONT)
_content = b.stream(b"/Filter/FlateDecode", flate(
    line(b"Readable text here.", 700) + b"BT /F2 10 Tf 72 680 Td <0001> Tj ET\n"))
_page = b.reserve()
_pages = b.reserve()
b.add(
    b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
    b"/Resources<</Font<</F1 %d 0 R/F2 %d 0 R>>>>/Contents %d 0 R>>"
    % (_pages, _good, _bad, _content),
    _page,
)
b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % _page, _pages)
write("detector-mixed-fonts", classic_trailer(
    b, b.add(b"<</Type/Catalog/Pages %d 0 R>>" % _pages)))

# 5. Control bytes through an ordinary simple font, to pin that the drop rule
#    is **not** specific to CID fonts. `41 00 42 02` reads as `AB` on both
#    sides; a fix scoped to Type0 would leave this one wrong.
b = Builder()
write("decode-control-bytes", classic_trailer(b, detector_font_document(
    b, SIMPLE_FONT,
    content=line(b"Before the control bytes.", 700)
        + b"BT /F1 10 Tf 72 680 Td <41004202> Tj ET\n",
)))

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


# --- text-state arithmetic ------------------------------------------------
#
# Wave 107 found a font-size bug that had survived ninety waves because every
# probe fed the extractor upright, unscaled, unspaced text. These files feed
# it the rest of the text state: horizontal scaling, rise, character and word
# spacing, kerning, render modes, nested transforms and negative sizes. Each
# is arithmetic the extractor does on every run and that nothing had varied.

# Horizontal scaling (`Tz`), which scales advances but not the nominal size.
ARITH_TZ = (
    line(b"normal width text", 720)
    + b"BT /F1 10 Tf 200 Tz 72 700 Td (double width text) Tj ET\n"
    + b"BT /F1 10 Tf 50 Tz 72 680 Td (half width text) Tj ET\n"
    + b"BT /F1 10 Tf 100 Tz 72 660 Td (back to normal) Tj ET\n"
)
b = Builder()
write("arith-tz", classic_trailer(b, base_document(b, content=ARITH_TZ)))

# Rise (`Ts`): a superscript and a subscript sharing a line with body text.
ARITH_TS = (
    b"BT /F1 10 Tf 72 720 Td (base) Tj 4 Ts (raised) Tj 0 Ts ( level ) Tj"
    b" -4 Ts (lowered) Tj 0 Ts ( done) Tj ET\n"
    + line(b"a following line of ordinary text", 700)
)
b = Builder()
write("arith-ts", classic_trailer(b, base_document(b, content=ARITH_TS)))

# Character and word spacing (`Tc`/`Tw`), which widen every glyph and every
# space — the advance the word joiner measures its gaps against.
ARITH_SPACING = (
    line(b"no extra spacing here", 720)
    + b"BT /F1 10 Tf 2 Tc 72 700 Td (wide character spacing) Tj ET\n"
    + b"BT /F1 10 Tf 0 Tc 8 Tw 72 680 Td (wide word spacing here) Tj ET\n"
    + b"BT /F1 10 Tf 0 Tc 0 Tw 72 660 Td (back to normal spacing) Tj ET\n"
)
b = Builder()
write("arith-spacing", classic_trailer(b, base_document(b, content=ARITH_SPACING)))

# Kerning inside a `TJ` array: adjustments large enough to be a space, and
# small enough not to be.
ARITH_KERNING = (
    b"BT /F1 10 Tf 72 720 Td [(tight) -20 (kerning)] TJ ET\n"
    b"BT /F1 10 Tf 72 700 Td [(wide) -400 (kerning)] TJ ET\n"
    b"BT /F1 10 Tf 72 680 Td [(back) 200 (wards)] TJ ET\n"
)
b = Builder()
write("arith-kerning", classic_trailer(b, base_document(b, content=ARITH_KERNING)))

# Render modes: 3 is invisible (an OCR layer hides behind a scan), 7 is
# clip-only. Neither should reach the Markdown; mode 2 should.
ARITH_RENDER = (
    line(b"visible text mode zero", 720)
    + b"BT /F1 10 Tf 3 Tr 72 700 Td (invisible text mode three) Tj ET\n"
    + b"BT /F1 10 Tf 7 Tr 72 680 Td (clipping text mode seven) Tj ET\n"
    + b"BT /F1 10 Tf 2 Tr 72 660 Td (fill stroke mode two) Tj ET\n"
)
b = Builder()
write("arith-render", classic_trailer(b, base_document(b, content=ARITH_RENDER)))

# Nested `q`/`Q` with accumulating `cm`, so the transform has to unwind
# correctly rather than merely be applied.
ARITH_NESTED = (
    line(b"outside any transform", 740)
    + b"q 2 0 0 2 0 0 cm\n" + line(b"doubled once", 350)
    + b"q 0.5 0 0 0.5 0 0 cm\n" + line(b"back to normal inside", 600)
    + b"Q\n" + line(b"doubled again", 320) + b"Q\n"
    + line(b"outside again", 640)
)
b = Builder()
write("arith-nested", classic_trailer(b, base_document(b, content=ARITH_NESTED)))

# A negative vertical scale, which flips the text: the size is a magnitude,
# so it must not come out negative.
ARITH_NEGATIVE = (
    line(b"upright reference line", 720)
    + b"q 1 0 0 -1 0 792 cm\n" + line(b"flipped vertically", 120) + b"Q\n"
)
b = Builder()
write("arith-negative", classic_trailer(b, base_document(b, content=ARITH_NEGATIVE)))

# `TD`, `T*` and `'` — the line-positioning operators that set leading as a
# side effect, which a reader that only knows `Td` places wrongly.
ARITH_LEADING = (
    b"BT /F1 10 Tf 72 720 TD (first line by TD) Tj\n"
    b"0 -14 TD (second line, leading now fourteen) Tj\nT* (third line by T star) Tj\n"
    b"(fourth line by quote) ' ET\n"
)
b = Builder()
write("arith-leading", classic_trailer(b, base_document(b, content=ARITH_LEADING)))


# --- fonts and encodings --------------------------------------------------
#
# The decoding path: `ToUnicode` CMaps of every shape, `/Differences`
# encodings, missing widths, and `/ActualText`. Wave 97 rewrote the CMap
# parser after a differential probe found four defects in it; none of that
# had ever run end to end on a document.

def cid_document(b, tounicode, content, widths=b"/W [0 [500]]"):
    """A Type0/Identity-H font whose codes are two bytes wide."""
    cmap_id = b.stream(b"/Filter/FlateDecode", flate(tounicode))
    descendant = b.add(
        b"<</Type/Font/Subtype/CIDFontType2/BaseFont/Test"
        b"/CIDSystemInfo<</Registry(Adobe)/Ordering(Identity)/Supplement 0>>"
        b"/DW 500 " + widths + b">>"
    )
    font_id = b.add(
        b"<</Type/Font/Subtype/Type0/BaseFont/Test/Encoding/Identity-H"
        b"/DescendantFonts[%d 0 R]/ToUnicode %d 0 R>>" % (descendant, cmap_id)
    )
    content_id = b.stream(b"/Filter/FlateDecode", flate(content))
    page_id = b.reserve()
    pages_id = b.reserve()
    b.add(
        b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
        b"/Resources<</Font<</F1 %d 0 R>>>>/Contents %d 0 R>>"
        % (pages_id, font_id, content_id),
        page_id,
    )
    b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % page_id, pages_id)
    return b.add(b"<</Type/Catalog/Pages %d 0 R>>" % pages_id)


def tounicode_cmap(body):
    return (
        b"/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
        b"1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
        + body + b"endcmap\nend\nend\n"
    )


# `bfchar` mappings, including a ligature destination and a surrogate pair.
CID_BFCHAR = tounicode_cmap(
    b"4 beginbfchar\n<0001> <0048>\n<0002> <0065>\n<0003> <006C>\n"
    b"<0004> <D83CDF1F>\nendbfchar\n"
)
b = Builder()
write(
    "font-cid-bfchar",
    classic_trailer(
        b, cid_document(b, CID_BFCHAR, b"BT /F1 12 Tf 72 720 Td <0001000200030004> Tj ET\n")),
)

# `bfrange` in both forms: a base that increments, and an explicit array.
CID_BFRANGE = tounicode_cmap(
    b"2 beginbfrange\n<0001> <0003> <0041>\n<0010> <0012> [<0058> <0059> <005A>]\n"
    b"endbfrange\n"
)
b = Builder()
write(
    "font-cid-bfrange",
    classic_trailer(
        b,
        cid_document(
            b, CID_BFRANGE, b"BT /F1 12 Tf 72 720 Td <000100020003> Tj ET\n"
            b"BT /F1 12 Tf 72 700 Td <001000110012> Tj ET\n"),
    ),
)

# A CMap that maps one code to a *list* of whitespace alternatives, which the
# reference collapses to a single character — the wave 96 finding, now on a
# real document.
CID_COLLAPSE = tounicode_cmap(
    b"3 beginbfchar\n<0001> <0041>\n<0002> <00200009>\n<0003> <002D00AD>\nendbfchar\n"
)
b = Builder()
write(
    "font-cid-collapse",
    classic_trailer(
        b, cid_document(b, CID_COLLAPSE, b"BT /F1 12 Tf 72 720 Td <000100020003> Tj ET\n")),
)

# A simple font with a `/Differences` encoding, so codes name glyphs rather
# than Latin-1 positions.
DIFFERENCES_FONT = (
    b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica"
    b"/FirstChar 32/LastChar 126/Widths [%s]"
    b"/Encoding<</Type/Encoding/Differences[65 /bullet /emdash /quotedblleft]>>>>"
    % b" ".join(b"500" for _ in range(95))
)
b = Builder()
write(
    "font-differences",
    classic_trailer(
        b,
        base_document(
            b,
            content=b"BT /F1 12 Tf 72 720 Td (ABC) Tj ET\n"
            b"BT /F1 12 Tf 72 700 Td (plain text below) Tj ET\n",
            font=DIFFERENCES_FONT,
        ),
    ),
)

# A font declaring no `/Widths` at all, so every advance falls back.
NO_WIDTHS_FONT = b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>"
b = Builder()
write(
    "font-no-widths",
    classic_trailer(
        b,
        base_document(
            b,
            content=b"BT /F1 12 Tf 72 720 Td (text with no declared widths) Tj ET\n"
            b"BT /F1 12 Tf 72 700 Td (a second line to group with) Tj ET\n",
            font=NO_WIDTHS_FONT,
        ),
    ),
)

# `/ActualText`, which overrides what a marked-content span says it shows —
# how a producer spells out a ligature or a decorative glyph.
ACTUAL_TEXT = (
    b"BT /F1 12 Tf 72 720 Td (before ) Tj ET\n"
    b"/Span <</ActualText (fi)>> BDC\nBT /F1 12 Tf 130 720 Td (\\256) Tj ET\nEMC\n"
    b"BT /F1 12 Tf 72 700 Td (an ordinary following line) Tj ET\n"
)
b = Builder()
write("font-actualtext", classic_trailer(b, base_document(b, content=ACTUAL_TEXT)))


# --- encryption -----------------------------------------------------------
#
# Most "protected" PDFs are encrypted with an *empty* user password: the
# producer wanted to set permissions, not to keep anyone out. A reader that
# cannot decrypt them fails on a large share of real documents, and fails
# silently — the file parses and its streams decode to noise.
#
# These files are encrypted here rather than by a library, so the corpus can
# be regenerated anywhere without one.

import hashlib

PASSWORD_PADDING = bytes([
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56,
    0xFF, 0xFA, 0x01, 0x08, 0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80,
    0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
])


def rc4(key, data):
    state = list(range(256))
    j = 0
    for i in range(256):
        j = (j + state[i] + key[i % len(key)]) & 0xFF
        state[i], state[j] = state[j], state[i]
    out = bytearray()
    x = y = 0
    for byte in data:
        x = (x + 1) & 0xFF
        y = (y + state[x]) & 0xFF
        state[x], state[y] = state[y], state[x]
        out.append(byte ^ state[(state[x] + state[y]) & 0xFF])
    return bytes(out)


def encryption_dictionary(revision, key_length, doc_id, permissions=-4):
    """Owner and user strings for an empty user *and* owner password."""
    # Algorithm 3: the owner string, from the owner password (empty here).
    digest = hashlib.md5(PASSWORD_PADDING).digest()
    if revision >= 3:
        for _ in range(50):
            digest = hashlib.md5(digest).digest()
    rc4_key = digest[:key_length]
    owner = rc4(rc4_key, PASSWORD_PADDING)
    if revision >= 3:
        for round in range(1, 20):
            owner = rc4(bytes(b ^ round for b in rc4_key), owner)

    # Algorithm 2: the file key.
    material = bytearray(PASSWORD_PADDING)
    material += owner
    material += (permissions & 0xFFFFFFFF).to_bytes(4, "little")
    material += doc_id
    key = hashlib.md5(bytes(material)).digest()
    if revision >= 3:
        for _ in range(50):
            key = hashlib.md5(key[:key_length]).digest()
    key = key[:key_length]

    # Algorithms 4 and 5: the user string.
    if revision == 2:
        user = rc4(key, PASSWORD_PADDING)
    else:
        user = rc4(key, hashlib.md5(PASSWORD_PADDING + doc_id).digest())
        for round in range(1, 20):
            user = rc4(bytes(b ^ round for b in key), user)
        user += b"\x00" * 16
    return owner, user, key


def object_key(key, number, generation):
    material = key + bytes([
        number & 0xFF, (number >> 8) & 0xFF, (number >> 16) & 0xFF,
        generation & 0xFF, (generation >> 8) & 0xFF,
    ])
    return hashlib.md5(material).digest()[: min(len(key) + 5, 16)]


def encrypted_document(revision, key_length):
    """A one-page document whose content stream is RC4-encrypted."""
    doc_id = bytes(range(16))
    owner, user, key = encryption_dictionary(revision, key_length, doc_id)

    content = (
        line(b"Encrypted Document", 720, 18)
        + line(b"This text was RC4 encrypted in the file.", 690)
        + line(b"A second line, also encrypted.", 676)
    )
    stream = flate(content)

    b = Builder()
    # Object numbers are assigned in order below; the content stream is 1.
    content_id = b.stream(b"/Filter/FlateDecode", rc4(object_key(key, 1, 0), stream))
    font_id = b.add(SIMPLE_FONT)
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
    encrypt_id = b.add(
        b"<</Filter/Standard/V %d/R %d/Length %d/P -4/O <%s>/U <%s>>>"
        % (1 if revision == 2 else 2, revision, key_length * 8,
           owner.hex().encode(), user.hex().encode())
    )
    extra = b"/Encrypt %d 0 R/ID[<%s><%s>]" % (
        encrypt_id, doc_id.hex().encode(), doc_id.hex().encode())
    return classic_trailer(b, root, extra=extra)


def aes_encrypt_cbc(key, data):
    """AES-128-CBC with a fixed IV and PKCS#7 padding, written out so the
    corpus needs no crypto library. Encryption only — the port implements
    the inverse, and the two meeting is the point."""
    sbox = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab,
        0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4,
        0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71,
        0xd8, 0x31, 0x15, 0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
        0xeb, 0x27, 0xb2, 0x75, 0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6,
        0xb3, 0x29, 0xe3, 0x2f, 0x84, 0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb,
        0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf, 0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45,
        0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5,
        0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2, 0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44,
        0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73, 0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a,
        0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb, 0xe0, 0x32, 0x3a, 0x0a, 0x49,
        0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79, 0xe7, 0xc8, 0x37, 0x6d,
        0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08, 0xba, 0x78, 0x25,
        0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a, 0x70, 0x3e,
        0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e, 0xe1,
        0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb,
        0x16,
    ]

    def xtime(value):
        value <<= 1
        return (value ^ 0x1B) & 0xFF if value & 0x100 else value

    def mul(a, b):
        result = 0
        while b:
            if b & 1:
                result ^= a
            a = xtime(a)
            b >>= 1
        return result

    words = [list(key[i:i + 4]) for i in range(0, 16, 4)]
    rcon = 1
    for index in range(4, 44):
        word = list(words[index - 1])
        if index % 4 == 0:
            word = [sbox[b] for b in word[1:] + word[:1]]
            word[0] ^= rcon
            rcon = xtime(rcon)
        words.append([words[index - 4][i] ^ word[i] for i in range(4)])
    round_keys = [sum(words[i:i + 4], []) for i in range(0, 44, 4)]

    def encrypt_block(block):
        state = [block[i] ^ round_keys[0][i] for i in range(16)]
        for rnd in range(1, 11):
            state = [sbox[b] for b in state]
            shifted = list(state)
            for row in range(1, 4):
                for col in range(4):
                    shifted[col * 4 + row] = state[((col + row) % 4) * 4 + row]
            state = shifted
            if rnd < 10:
                mixed = list(state)
                for col in range(4):
                    base = col * 4
                    a = state[base:base + 4]
                    mixed[base] = mul(a[0], 2) ^ mul(a[1], 3) ^ a[2] ^ a[3]
                    mixed[base + 1] = a[0] ^ mul(a[1], 2) ^ mul(a[2], 3) ^ a[3]
                    mixed[base + 2] = a[0] ^ a[1] ^ mul(a[2], 2) ^ mul(a[3], 3)
                    mixed[base + 3] = mul(a[0], 3) ^ a[1] ^ a[2] ^ mul(a[3], 2)
                state = mixed
            state = [state[i] ^ round_keys[rnd][i] for i in range(16)]
        return bytes(state)

    iv = bytes(range(16))
    pad = 16 - len(data) % 16
    data = data + bytes([pad]) * pad
    out = bytearray(iv)
    previous = iv
    for start in range(0, len(data), 16):
        block = bytes(a ^ b for a, b in zip(data[start:start + 16], previous))
        previous = encrypt_block(block)
        out += previous
    return bytes(out)


def aes_object_key(key, number, generation):
    material = key + bytes([
        number & 0xFF, (number >> 8) & 0xFF, (number >> 16) & 0xFF,
        generation & 0xFF, (generation >> 8) & 0xFF,
    ]) + b"sAlT"
    return hashlib.md5(material).digest()[:16]


def aes_document():
    """A `/V 4` document whose stream crypt filter is /AESV2."""
    doc_id = bytes(range(16))
    owner, user, key = encryption_dictionary(4, 16, doc_id)

    content = (
        line(b"AES Encrypted Document", 720, 18)
        + line(b"This text was AES-128 encrypted in the file.", 690)
    )
    stream = flate(content)

    b = Builder()
    content_id = b.stream(
        b"/Filter/FlateDecode", aes_encrypt_cbc(aes_object_key(key, 1, 0), stream))
    font_id = b.add(SIMPLE_FONT)
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
    encrypt_id = b.add(
        b"<</Filter/Standard/V 4/R 4/Length 128/P -4/O <%s>/U <%s>"
        b"/CF<</StdCF<</CFM/AESV2/Length 16>>>>/StmF/StdCF/StrF/StdCF>>"
        % (owner.hex().encode(), user.hex().encode())
    )
    extra = b"/Encrypt %d 0 R/ID[<%s><%s>]" % (
        encrypt_id, doc_id.hex().encode(), doc_id.hex().encode())
    return classic_trailer(b, root, extra=extra)


write("encrypted-aes-v4", aes_document())
write("encrypted-rc4-r2", encrypted_document(2, 5))
write("encrypted-rc4-r3", encrypted_document(3, 16))


# --- embedded font programs -----------------------------------------------
#
# A producer that subsets a font often omits /ToUnicode, on the grounds that
# the font itself already says which character each glyph draws. Reading it
# needs a TrueType parser — which the reference gets from `ttf-parser` and
# this port has to write out, so the comparison is the only thing keeping
# the two honest.

def truetype_font(mapping, num_glyphs):
    """A minimal TrueType font carrying a format-4 `cmap` and nothing else
    of substance. Enough tables for a parser to accept it; no outlines."""
    def be16(v):
        return struct.pack(">H", v & 0xFFFF)

    def be32(v):
        return struct.pack(">I", v & 0xFFFFFFFF)

    codes = sorted(mapping)
    segments = []
    start = previous = codes[0]
    for code in codes[1:]:
        if code == previous + 1 and mapping[code] - code == mapping[start] - start:
            previous = code
            continue
        segments.append((start, previous))
        start = previous = code
    segments.append((start, previous))
    segments.append((0xFFFF, 0xFFFF))

    body = b"".join(be16(end) for _, end in segments) + be16(0)
    body += b"".join(be16(begin) for begin, _ in segments)
    for begin, _ in segments:
        body += be16(1 if begin == 0xFFFF else (mapping[begin] - begin) & 0xFFFF)
    body += b"".join(be16(0) for _ in segments)
    subtable = (be16(4) + be16(14 + len(body)) + be16(0) + be16(len(segments) * 2)
                + be16(0) + be16(0) + be16(0) + body)
    cmap = be16(0) + be16(1) + be16(3) + be16(1) + be32(12) + subtable

    head = (be32(0x00010000) + be32(0x00010000) + be32(0) + be32(0x5F0F3CF5)
            + be16(0) + be16(1000) + b"\0" * 16 + be16(0) + be16(0) + be16(1000)
            + be16(1000) + be16(0) + be16(0) + be16(2) + be16(0) + be16(0))
    hhea = (be32(0x00010000) + be16(800) + be16(0xFF38) + be16(0) + be16(1000)
            + b"\0" * 22 + be16(num_glyphs))
    maxp = be32(0x00010000) + be16(num_glyphs) + b"\0" * 26
    hmtx = b"".join(be16(500) + be16(0) for _ in range(num_glyphs))
    loca = b"".join(be16(0) for _ in range(num_glyphs + 1))

    tables = {b"cmap": cmap, b"glyf": b"", b"head": head, b"hhea": hhea,
              b"hmtx": hmtx, b"loca": loca, b"maxp": maxp}
    tags = sorted(tables)
    offset = 12 + 16 * len(tags)
    directory = b""
    payload = b""
    for tag in tags:
        data = tables[tag]
        directory += tag + be32(0) + be32(offset) + be32(len(data))
        padded = data + b"\0" * ((4 - len(data) % 4) % 4)
        payload += padded
        offset += len(padded)
    return be32(0x00010000) + be16(len(tags)) + be16(0) + be16(0) + be16(0) + directory + payload


def embedded_font_document(b):
    """A Type0 font with an embedded program and **no** /ToUnicode, so the
    font's own cmap is the only route to the text."""
    font = truetype_font({0x48: 3, 0x69: 4, 0x21: 5, 0x54: 6, 0x65: 7, 0x78: 8}, 10)
    program = b.stream(b"/Length1 %d" % len(font), font)
    descriptor = b.add(
        b"<</Type/FontDescriptor/FontName/Test/Flags 4/ItalicAngle 0/Ascent 800"
        b"/Descent -200/CapHeight 700/StemV 80/FontBBox[0 0 1000 1000]"
        b"/FontFile2 %d 0 R>>" % program
    )
    descendant = b.add(
        b"<</Type/Font/Subtype/CIDFontType2/BaseFont/Test"
        b"/CIDSystemInfo<</Registry(Adobe)/Ordering(Identity)/Supplement 0>>"
        b"/FontDescriptor %d 0 R/DW 500/CIDToGIDMap/Identity>>" % descriptor
    )
    font_id = b.add(
        b"<</Type/Font/Subtype/Type0/BaseFont/Test/Encoding/Identity-H"
        b"/DescendantFonts[%d 0 R]>>" % descendant
    )
    content_id = b.stream(
        b"/Filter/FlateDecode",
        flate(b"BT /F1 24 Tf 72 700 Td <000300040005> Tj ET\n"
              b"BT /F1 12 Tf 72 660 Td <000600070008> Tj ET\n"),
    )
    page_id = b.reserve()
    pages_id = b.reserve()
    b.add(
        b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
        b"/Resources<</Font<</F1 %d 0 R>>>>/Contents %d 0 R>>"
        % (pages_id, font_id, content_id),
        page_id,
    )
    b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % page_id, pages_id)
    return b.add(b"<</Type/Catalog/Pages %d 0 R>>" % pages_id)


b = Builder()
write("font-embedded-cmap", classic_trailer(b, embedded_font_document(b)))


def opentype_font_document(b):
    """The same shape, but the program is an OpenType wrapper in
    `/FontFile3`. OpenType puts CFF outlines inside the *same* sfnt
    container, so its `cmap` is found by the same parser — which is why the
    reference reads both through one code path and this port must too."""
    font = bytearray(truetype_font({0x4F: 3, 0x54: 4, 0x70: 5, 0x65: 6}, 8))
    font[0:4] = b"OTTO"
    program = b.stream(b"/Subtype/OpenType", bytes(font))
    descriptor = b.add(
        b"<</Type/FontDescriptor/FontName/Test/Flags 4/ItalicAngle 0/Ascent 800"
        b"/Descent -200/CapHeight 700/StemV 80/FontBBox[0 0 1000 1000]"
        b"/FontFile3 %d 0 R>>" % program
    )
    descendant = b.add(
        b"<</Type/Font/Subtype/CIDFontType0/BaseFont/Test"
        b"/CIDSystemInfo<</Registry(Adobe)/Ordering(Identity)/Supplement 0>>"
        b"/FontDescriptor %d 0 R/DW 500>>" % descriptor
    )
    font_id = b.add(
        b"<</Type/Font/Subtype/Type0/BaseFont/Test/Encoding/Identity-H"
        b"/DescendantFonts[%d 0 R]>>" % descendant
    )
    content_id = b.stream(
        b"/Filter/FlateDecode",
        flate(b"BT /F1 24 Tf 72 700 Td <0003000400050006> Tj ET\n"),
    )
    page_id = b.reserve()
    pages_id = b.reserve()
    b.add(
        b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
        b"/Resources<</Font<</F1 %d 0 R>>>>/Contents %d 0 R>>"
        % (pages_id, font_id, content_id),
        page_id,
    )
    b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % page_id, pages_id)
    return b.add(b"<</Type/Catalog/Pages %d 0 R>>" % pages_id)


b = Builder()
write("font-opentype-cmap", classic_trailer(b, opentype_font_document(b)))


print("generated %d pdfs in %s" % (len([f for f in os.listdir(OUT) if f.endswith(".pdf")]), OUT))


# --- detector-only documents ------------------------------------------------
#
# The whole image half of `analyze_page_content` was unexercised until these:
# every other corpus document reports `hasImages=0 area=0 imgCount=0
# template=0`, so `PdfPageImages.swift` was verified by nothing at all.

# One small image: under the 500,000-pixel template threshold.
b = Builder()
write("image-small", classic_trailer(
    b, image_page(b, [(b"Im0", image_xobject(b, 100, 100))])))

# One large image: 800,000 pixels, over the threshold on its own.
b = Builder()
write("image-template", classic_trailer(
    b, image_page(b, [(b"Im0", image_xobject(b, 1000, 800))])))

# Twelve tiles of 200,000 pixels each. No single one is a template; 2.4M
# together is four times the threshold, which is the tiled-scan rule — a
# JBIG2 scanner emits pages exactly like this.
b = Builder()
write("image-tiled", classic_trailer(b, image_page(
    b, [(b"Im%d" % k, image_xobject(b, 500, 400)) for k in range(12)])))

# An image nested inside a Form XObject, which only the recursion finds.
b = Builder()
_inner = image_xobject(b, 900, 700)
_form = b.stream(
    b"/Type/XObject/Subtype/Form/BBox[0 0 200 200]"
    b"/Resources<</XObject<</Inner %d 0 R>>>>" % _inner,
    b"q 200 0 0 200 0 0 cm /Inner Do Q\n",
)
b_font = b.add(SIMPLE_FONT)
_content = b.stream(b"", line(b"Image inside a form.", 700) + b"q 1 0 0 1 72 300 cm /Fm0 Do Q\n")
_page = b.reserve()
_pages = b.reserve()
b.add(
    b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
    b"/Resources<</Font<</F1 %d 0 R>>/XObject<</Fm0 %d 0 R>>>>/Contents %d 0 R>>"
    % (_pages, b_font, _form, _content),
    _page,
)
b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % _page, _pages)
write("image-in-form", classic_trailer(
    b, b.add(b"<</Type/Catalog/Pages %d 0 R>>" % _pages)))

# Text drawn as filled outlines: thousands of path operators, one text
# operator, and almost no distinct letters. This is the `has_vector_text`
# case — a page that *looks* like text and has no text layer to extract.
_outlines = b"".join(
    b"%d %d m %d %d l %d %d l h f\n"
    % (72 + (k % 40) * 12, 700 - (k // 40) * 14,
       78 + (k % 40) * 12, 700 - (k // 40) * 14,
       78 + (k % 40) * 12, 710 - (k // 40) * 14)
    for k in range(1200)
)
b = Builder()
write("vector-text", classic_trailer(b, base_document(
    b, content=_outlines + b"BT /F1 10 Tf 72 100 Td (.) Tj ET\n")))

# A two-page document: an image-only first page and a text second page.
#
# This reaches `mixed` through the **template** branch, which was not the
# prediction — the reported confidence is 0.650, and only
# `0.5 + 0.3 * (1 - template_ratio)` with a ratio of 0.5 produces that. The
# per-page conditions are counted separately and combined at document level,
# so one page can supply the template and another the text; they do not have
# to hold on the same page, as a first reading of the code suggested.
b = Builder()
_img = image_xobject(b, 1000, 800)
_font = b.add(SIMPLE_FONT)
_c1 = b.stream(b"", b"q 400 0 0 300 72 300 cm /Im0 Do Q\n")
_c2 = b.stream(b"", b"".join(
    line(b"Line %d of ordinary readable prose on the second page." % k, 700 - k * 16)
    for k in range(12)))
_p1 = b.reserve()
_p2 = b.reserve()
_pages = b.reserve()
b.add(b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
      b"/Resources<</XObject<</Im0 %d 0 R>>>>/Contents %d 0 R>>"
      % (_pages, _img, _c1), _p1)
b.add(b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
      b"/Resources<</Font<</F1 %d 0 R>>>>/Contents %d 0 R>>"
      % (_pages, _font, _c2), _p2)
b.add(b"<</Type/Pages/Kids[%d 0 R %d 0 R]/Count 2>>" % (_p1, _p2), _pages)
write("mixed-image-and-text", classic_trailer(
    b, b.add(b"<</Type/Catalog/Pages %d 0 R>>" % _pages)))

# A page that draws nothing at all: no text, no images, no paths. The only
# route to the `no_text` OCR reason, which every other document misses
# because a page with an image reports `scanned` instead.
b = Builder()
_empty = b.stream(b"", b"")
_pages = b.reserve()
_page = b.reserve()
b.add(b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
      b"/Resources<<>>/Contents %d 0 R>>" % (_pages, _empty), _page)
b.add(b"<</Type/Pages/Kids[%d 0 R]/Count 1>>" % _page, _pages)
write("empty-page", classic_trailer(
    b, b.add(b"<</Type/Catalog/Pages %d 0 R>>" % _pages)))

# Five pages, three of them text: a ratio of exactly 0.60, which is the
# `text_page_ratio_threshold` itself. Added in wave 122 after flipping the
# comparison from `>=` to `>` changed nothing across 77 documents — no
# document sat on the boundary, so the comparison was untested. This one
# classifies as textBased only while the comparison is inclusive.
b = Builder()
_font = b.add(SIMPLE_FONT)
_img = image_xobject(b, 200, 150)
_img2 = image_xobject(b, 200, 150)
_pages = b.reserve()
_kids = []
for _k in range(5):
    if _k < 3:
        _c = b.stream(b"", b"".join(
            line(b"Page %d line %d of readable prose." % (_k, _j), 700 - _j * 16)
            for _j in range(12)))
        _res = b"<</Font<</F1 %d 0 R>>>>" % _font
    else:
        # **Two small** images, not one big one. A single large image makes
        # the page a template, and the template branch pre-empts the ratio
        # branch entirely — the first attempt at this document classified
        # `mixed` at 0.680 and tested nothing about the threshold.
        _c = b.stream(b"", b"q 60 0 0 40 72 300 cm /Im0 Do Q\n"
                            b"q 60 0 0 40 200 300 cm /Im1 Do Q\n")
        _res = b"<</XObject<</Im0 %d 0 R/Im1 %d 0 R>>>>" % (_img, _img2)
    _pg = b.add(b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
                b"/Resources%s/Contents %d 0 R>>" % (_pages, _res, _c))
    _kids.append(_pg)
b.add(b"<</Type/Pages/Kids[%s]/Count 5>>"
      % b" ".join(b"%d 0 R" % k for k in _kids), _pages)
write("ratio-exactly-threshold", classic_trailer(
    b, b.add(b"<</Type/Catalog/Pages %d 0 R>>" % _pages)))


# A bar chart: filled rectangles in a row, with value labels above them and
# category labels below. Every table detector reads the bars as cell borders
# and the labels as aligned columns, so without chart masking the figure is
# gridded into a phantom table. `detect_chart_regions` finds the bar cluster
# and its items are withheld from every detector — but **not** from the text,
# since deleting a chart's labels would lose the figure's content entirely.
#
# The geometry sits in a narrow window that a first attempt missed entirely.
# Clustering expands each rectangle by a 3pt tolerance, so two bars group only
# when their gap is under **6pt**; the bar-family test then demands a gap of
# at least **half the bar's breadth**. Together those bound the breadth under
# roughly 12pt. Forty-point bars on a sixty-point pitch — the obvious way to
# draw a chart — cluster into nothing at all, and the first draft of this
# document reported zero chart regions.
_bars = b"".join(
    b"%d %d 10 %d re f\n" % (100 + _k * 15, 300, 40 + _k * 18)
    for _k in range(8)
)
# Two *aligned* rows of data labels **inside** the bar region. Values stacked
# above bars of varying height sit at varying y and never form a row, so the
# heuristic ignores them and the masking has nothing to prevent — which is how
# the second draft of this document still tested nothing.
_values = b"".join(
    line(b"%d" % (10 + _k * 7), 320, x=98 + _k * 15, size=6) for _k in range(8)
) + b"".join(
    line(b"%d" % (99 - _k * 5), 340, x=98 + _k * 15, size=6) for _k in range(8)
) + b"".join(
    line(b"%d" % (40 + _k * 3), 360, x=98 + _k * 15, size=6) for _k in range(8)
)
_labels = b"".join(
    line(b"Q%d" % (_k + 1), 288, x=98 + _k * 15, size=6) for _k in range(8)
)
MD_BAR_CHART = (
    line(b"Quarterly revenue by segment.", 700)
    + _bars + _values + _labels
    + line(b"Figures are in millions of dollars.", 250)
)
b = Builder()
write("chart-bars", classic_trailer(b, base_document(b, content=MD_BAR_CHART)))


# A letter-spaced heading: each glyph drawn as its own `Tj` with a wide
# advance, which is how a designer tracks out a title. `fix_letterspaced_items`
# measures the page's word-gap bar from runs like these, and the bar it
# returns is well above the 0.10 default — which is the *only* input that
# reaches `should_join_items`' letter-spaced branch.
#
# Added in wave 129 after measuring that every other corpus page reports
# exactly 0.10, so the branch had no coverage at all.
def _tracked(word, x, y, size, step):
    out = b"BT /F1 %d Tf %d %d Td" % (size, x, y)
    for index, ch in enumerate(word):
        if index:
            out += b" %d 0 Td" % step
        out += b" (%s) Tj" % bytes([ch])
    return out + b" ET\n"


MD_LETTERSPACED = (
    _tracked(b"ANNUALREPORTING", 72, 700, 14, 13)
    + line(b"Ordinary body text follows the tracked heading above.", 640)
    + line(b"A second line of ordinary prose for the body size.", 624)
)
b = Builder()
write("letterspaced-heading", classic_trailer(b, base_document(b, content=MD_LETTERSPACED)))


# --- AES-256, revision 6 -----------------------------------------------------
#
# What Acrobat X and later write by default. The key is *not* derived from the
# password: the password unwraps /UE, which holds it. Getting there needs
# Algorithm 2.B, whose whole purpose is to be expensive — sixty-plus rounds of
# AES mixing and re-hashing, with the hash chosen per round by the data.

_AES_SBOX = None


def _aes_tables():
    global _AES_SBOX
    if _AES_SBOX is None:
        p = q = 1
        sbox = [0] * 256
        while True:
            p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
            q ^= q << 1
            q ^= q << 2
            q ^= q << 4
            q &= 0xFF
            if q & 0x80:
                q ^= 0x09
            x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6))
            x ^= ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))
            sbox[p] = (x ^ 0x63) & 0xFF
            if p == 1:
                break
        sbox[0] = 0x63
        _AES_SBOX = sbox
    return _AES_SBOX


def _gmul(a, b):
    result = 0
    for _ in range(8):
        if b & 1:
            result ^= a
        high = a & 0x80
        a = (a << 1) & 0xFF
        if high:
            a ^= 0x1B
        b >>= 1
    return result


def _aes_expand(key):
    sbox = _aes_tables()
    nk = len(key) // 4
    rounds = 10 if nk == 4 else 14
    words = [list(key[i * 4:i * 4 + 4]) for i in range(nk)]
    rcon = 1
    for i in range(nk, (rounds + 1) * 4):
        word = list(words[i - 1])
        if i % nk == 0:
            word = [sbox[b] for b in word[1:] + word[:1]]
            word[0] ^= rcon
            rcon = _gmul(rcon, 2)
        elif nk == 8 and i % nk == 4:
            word = [sbox[b] for b in word]
        words.append([words[i - nk][j] ^ word[j] for j in range(4)])
    return [sum(words[i * 4:i * 4 + 4], []) for i in range(rounds + 1)]


def _aes_encrypt_block(round_keys, block):
    sbox = _aes_tables()
    rounds = len(round_keys) - 1
    state = [block[i] ^ round_keys[0][i] for i in range(16)]
    for rnd in range(1, rounds + 1):
        state = [sbox[b] for b in state]
        shifted = list(state)
        for row in range(1, 4):
            for col in range(4):
                shifted[col * 4 + row] = state[((col + row) % 4) * 4 + row]
        state = shifted
        if rnd < rounds:
            mixed = list(state)
            for col in range(4):
                base = col * 4
                a = state[base:base + 4]
                mixed[base] = _gmul(a[0], 2) ^ _gmul(a[1], 3) ^ a[2] ^ a[3]
                mixed[base + 1] = a[0] ^ _gmul(a[1], 2) ^ _gmul(a[2], 3) ^ a[3]
                mixed[base + 2] = a[0] ^ a[1] ^ _gmul(a[2], 2) ^ _gmul(a[3], 3)
                mixed[base + 3] = _gmul(a[0], 3) ^ a[1] ^ a[2] ^ _gmul(a[3], 2)
            state = mixed
        state = [state[i] ^ round_keys[rnd][i] for i in range(16)]
    return bytes(state)


def aes_cbc_encrypt_raw(key, iv, data):
    """CBC with no padding and no prepended IV — Algorithm 2.B's mixer."""
    round_keys = _aes_expand(key)
    out = bytearray()
    previous = iv
    for start in range(0, len(data), 16):
        block = bytes(a ^ b for a, b in zip(data[start:start + 16], previous))
        previous = _aes_encrypt_block(round_keys, block)
        out += previous
    return bytes(out)


def hash_2b(password, salt, udata=b""):
    """ISO 32000-2 Algorithm 2.B."""
    k = hashlib.sha256(password + salt + udata).digest()
    rnd = 1
    while True:
        k1 = (password + k + udata) * 64
        e = aes_cbc_encrypt_raw(k[0:16], k[16:32], k1)
        remainder = sum(e[:16]) % 3
        k = [hashlib.sha256, hashlib.sha384, hashlib.sha512][remainder](e).digest()
        if rnd >= 64 and e[-1] <= rnd - 32:
            break
        rnd += 1
    return k[:32]


def aes256_document():
    """A `/V 5 /R 6` document with an empty user password."""
    file_key = bytes((i * 7 + 11) & 0xFF for i in range(32))
    user_vsalt = bytes(range(8))
    user_ksalt = bytes(range(8, 16))
    owner_vsalt = bytes(range(16, 24))
    owner_ksalt = bytes(range(24, 32))

    u = hash_2b(b"", user_vsalt) + user_vsalt + user_ksalt
    ue = aes_cbc_encrypt_raw(hash_2b(b"", user_ksalt), b"\x00" * 16, file_key)
    o = hash_2b(b"", owner_vsalt, u) + owner_vsalt + owner_ksalt
    oe = aes_cbc_encrypt_raw(hash_2b(b"", owner_ksalt, u), b"\x00" * 16, file_key)

    permissions = 0xFFFFFFFC
    perms_block = (
        bytes([permissions & 0xFF, (permissions >> 8) & 0xFF,
               (permissions >> 16) & 0xFF, (permissions >> 24) & 0xFF])
        + b"\xff\xff\xff\xff" + b"T" + b"adb" + b"\x00\x00\x00\x00"
    )
    perms = aes_cbc_encrypt_raw(file_key, b"\x00" * 16, perms_block)

    def encrypt_stream(data):
        iv = bytes((i * 3 + 5) & 0xFF for i in range(16))
        pad = 16 - len(data) % 16
        return iv + aes_cbc_encrypt_raw(file_key, iv, data + bytes([pad]) * pad)

    b = Builder()
    content = encrypt_stream(
        line(b"AES-256 protected document.", 700)
        + line(b"Revision six, empty user password.", 680))
    content_id = b.stream(b"", content)
    font_id = b.add(SIMPLE_FONT)
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
    encrypt_id = b.add(
        b"<</Filter/Standard/V 5/R 6/Length 256"
        b"/CF<</StdCF<</CFM/AESV3/AuthEvent/DocOpen/Length 32>>>>"
        b"/StmF/StdCF/StrF/StdCF"
        b"/U<%s>/UE<%s>/O<%s>/OE<%s>/Perms<%s>/P -4/EncryptMetadata true>>"
        % (u.hex().encode(), ue.hex().encode(), o.hex().encode(),
           oe.hex().encode(), perms.hex().encode())
    )
    return classic_trailer(b, root, extra=b"/Encrypt %d 0 R" % encrypt_id)


write("encrypted-aes-256", aes256_document())
