/// `/CIDToGIDMap`, ported from `get_cid_to_gid_map` and
/// `build_cmap_with_cid_to_gid_map` in `tounicode.rs`.
///
/// **Ported and deliberately not wired.** By the specification a
/// `CIDFontType2` addresses glyphs by CID, and a subsetting producer may
/// renumber them, so applying this map before consulting the embedded
/// `cmap` looks obviously right. Wiring it that way made the port diverge
/// from the reference, which is the only specification that counts here.
///
/// The measurement is a matched pair. `font-cid-to-gid.pdf` and
/// `font-embedded-cmap.pdf` are the same document with the same content
/// stream and the same embedded font; they differ only in that one declares
/// `/CIDToGIDMap /Identity` and the other supplies a stream permuting CIDs
/// 1–6 onto GIDs 3–8. **Both convert to exactly `Hi!` and `Tex`.** The
/// reference does not apply the map.
///
/// It does contain this repair, in `build_fallback_cmap_for_type0`, whose
/// entry conditions the document meets — so the repair is presumably inert
/// there too. The likeliest reason is that `build_cmap_from_truetype`
/// returns a map keyed by character code rather than glyph id, leaving the
/// `lookup(gid)` inside the repair with nothing to find. That is a
/// hypothesis, not a measurement, and it is the first thing to check if this
/// is picked up again.
///
/// Kept unwired because the finding is worth more than the code: the paired
/// documents pin the reference's actual behaviour, so a future wave starts
/// from evidence rather than from the specification's plain reading.

/// A font's `/CIDToGIDMap`, when it is a stream rather than `/Identity`.
///
/// `/Identity` yields nil, which is the same answer as an absent entry:
/// both mean the CID *is* the glyph index.
func pdfCidToGidMap(_ document: inout PdfDocument, _ cidFont: PdfDictionary) -> [UInt16]? {
    guard let entry = cidFont["CIDToGIDMap"] else { return nil }
    // Read raw first: a `/Identity` name must not be resolved into anything.
    if let name = entry.asName, name == Array("Identity".utf8) { return nil }
    guard let stream = document.resolve(entry).asStream,
        let data = document.decodedStream(stream), data.count >= 2
    else { return nil }

    var map: [UInt16] = []
    map.reserveCapacity(data.count / 2)
    var index = 0
    while index + 1 < data.count {
        map.append(UInt16(data[index]) << 8 | UInt16(data[index + 1]))
        index += 2
    }
    return map.isEmpty ? nil : map
}

/// Re-key a glyph-indexed character map by CID.
///
/// The embedded font's `cmap` answers questions about glyph indices; the
/// content stream asks about CIDs. This composes the two so the lookup takes
/// the code the page actually wrote.
func pdfApplyCidToGidMap(_ glyphToCharacter: [UInt16: Unicode.Scalar], map: [UInt16])
    -> [UInt16: Unicode.Scalar]
{
    var out: [UInt16: Unicode.Scalar] = [:]
    for (cid, gid) in map.enumerated() {
        guard let scalar = glyphToCharacter[gid] else { continue }
        out[UInt16(truncatingIfNeeded: cid)] = scalar
    }
    return out
}
