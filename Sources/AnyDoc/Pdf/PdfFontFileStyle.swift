/// The font program's own opinion of its style, ported from `fonts.rs` in
/// pdf-inspector: `descriptor_style_flags`, `get_font_file2_obj_num`,
/// `cff_font_name` and the two small accessors they lean on.
///
/// Wave 6 recovered emphasis from the `BaseFont` name, which fails on subset
/// fonts named `Tc1` or `ABCDEF+F1`. The `/FontDescriptor` is the second
/// opinion — but descriptors lie too: subset generators routinely write
/// `/ItalicAngle 0` for a genuinely italic face. So there is a third opinion,
/// the embedded font program itself, and the three are consulted in that
/// order with any one of them enough to decide.
///
/// The embedded program is also what identifies a CID font's CMap: an
/// Identity-H font with no `/ToUnicode` can only be read by looking inside
/// the font file, so the file's object number becomes the key that CMap is
/// stored under.

// MARK: - single-level resolution

/// An array from an object that may be one directly or a reference to one.
///
/// Single-level on purpose: the reference's `resolve_array` follows exactly
/// one reference, so a reference to a reference yields nothing. `resolve`
/// elsewhere in this port follows chains, which is why these two exist
/// separately rather than reusing it.
func pdfFontsResolveArray(_ document: inout PdfDocument, _ object: PdfObject) -> [PdfObject]? {
    switch object {
    case .array(let array):
        return array
    case .reference(let id):
        if case .array(let array) = document.object(id) { return array }
        return nil
    default:
        return nil
    }
}

/// A dictionary from an object that may be one directly or a reference to
/// one. Single-level, as `pdfFontsResolveArray` is.
func pdfFontsResolveDictionary(
    _ document: inout PdfDocument, _ object: PdfObject
) -> PdfDictionary? {
    switch object {
    case .dictionary(let dictionary):
        return dictionary
    case .reference(let id):
        return document.object(id).asDictionary
    default:
        return nil
    }
}

// MARK: - the embedded font program

/// The `/FontFile2` or `/FontFile3` stream reference on a descriptor.
///
/// `/FontFile2` is TrueType and `/FontFile3` is OpenType or bare CFF; the
/// first that is present *and a reference* wins. A directly embedded stream
/// is passed over, because what the callers want is the object number.
func pdfFontFileReference(_ descriptor: PdfDictionary) -> PdfObjectId? {
    if let reference = descriptor["FontFile2"]?.asReference { return reference }
    return descriptor["FontFile3"]?.asReference
}

/// The decompressed bytes of an embedded font program.
///
/// A stream that will not decode falls back to its raw content rather than
/// failing — the reference's `unwrap_or_else`, which matters because a font
/// program stored uncompressed has no filter to fail at.
func pdfFontFileData(_ document: inout PdfDocument, _ reference: PdfObjectId) -> [UInt8]? {
    guard let stream = document.object(reference).asStream else { return nil }
    if let decoded = document.decodedStream(stream) { return decoded }
    return document.rawStream(stream)?.content
}

/// The first PostScript name in a bare CFF font's Name INDEX (CFF spec §7).
///
/// `/FontFile3` may hold CFF with no sfnt wrapper, which a TrueType parser
/// cannot open — but the Name INDEX still carries the real PostScript name,
/// `XXXXXX+Amplitude-LightItalic`, even when the descriptor was rewritten to
/// claim upright. Reading four bytes of header and one INDEX is enough to
/// recover it.
///
/// The offsets are the fiddly part: CFF stores them 1-based from the byte
/// *before* the object data, so the base is one less than the end of the
/// offset array. A first offset of 0 is invalid by that rule and rejected.
func pdfCffFontName(_ data: [UInt8]) -> String? {
    // Header: major, minor, hdrSize, offSize. Only major 1 exists.
    guard data.count >= 4, data[0] == 1 else { return nil }
    let headerSize = Int(data[2])

    func byte(_ index: Int) -> UInt8? {
        index >= 0 && index < data.count ? data[index] : nil
    }

    // Name INDEX: count(u16), offSize(u8), offsets[count + 1], data.
    guard let high = byte(headerSize), let low = byte(headerSize + 1) else { return nil }
    let count = Int(UInt16(high) << 8 | UInt16(low))
    if count == 0 { return nil }
    guard let offsetSizeByte = byte(headerSize + 2) else { return nil }
    let offsetSize = Int(offsetSizeByte)
    guard (1...4).contains(offsetSize) else { return nil }

    func readOffset(_ index: Int) -> Int? {
        let at = headerSize + 3 + index * offsetSize
        guard at >= 0, at + offsetSize <= data.count else { return nil }
        var value = 0
        for offset in 0..<offsetSize { value = (value << 8) | Int(data[at + offset]) }
        return value
    }

    guard let start = readOffset(0), let end = readOffset(1) else { return nil }
    if start == 0 || end < start { return nil }

    let objectsBase = headerSize + 3 + (count + 1) * offsetSize - 1
    let nameStart = objectsBase + start
    let nameEnd = objectsBase + end
    guard nameStart >= 0, nameEnd >= nameStart, nameEnd <= data.count else { return nil }
    // `from_utf8_lossy`: invalid bytes become replacement characters rather
    // than rejecting the name, which is what `String(decoding:as:)` does too.
    return String(decoding: data[nameStart..<nameEnd], as: UTF8.self)
}

/// The style flags an embedded font program declares.
///
/// **Partial.** The reference tries a TrueType/OpenType parse first — OS/2
/// `fsSelection` for italic and bold, the `post` table for the slant angle —
/// and only falls back to the CFF Name INDEX when that parse fails. That
/// first branch rests on `ttf_parser`'s whole-font validation, which is not
/// yet ported, so only the CFF branch runs here.
///
/// The deferral cannot produce a *wrong* answer, only a missing one: an sfnt
/// font begins `00 01 00 00` or `OTTO`, and `pdfCffFontName` requires a
/// leading `01`, so a well-formed sfnt falls straight through to no flags
/// rather than being misread as CFF. What is lost is the rescue of a
/// TrueType face whose descriptor lied.
func pdfEmbeddedStyleFlags(
    _ document: inout PdfDocument, _ reference: PdfObjectId
) -> PdfFontStyle {
    guard let data = pdfFontFileData(&document, reference) else { return PdfFontStyle() }
    guard let name = pdfCffFontName(data) else { return PdfFontStyle() }
    return pdfStyleFromFontName(name)
}

/// Memo of embedded-font style flags, keyed by the font program's object id.
///
/// The same font program is referenced from every page that uses the font,
/// and decompressing and parsing it dominates the cost — so without this the
/// work repeats per page whenever the descriptor leaves a flag unset, which
/// is the common case, since a regular font declares neither italic nor bold.
struct PdfFontStyleCache {
    var byFontFile: [PdfObjectId: PdfFontStyle] = [:]

    init() {}
}

/// The style a font's descriptor and embedded program declare together.
///
/// Three details are the reference's and are easy to get wrong:
///   - the descriptor is taken from the font dictionary *first*, and only a
///     font that has none looks at `/DescendantFonts[0]`. A Type0 dictionary
///     carrying both keeps its own.
///   - `/ItalicAngle` and `/Flags` are read **unresolved**, so an indirect
///     value reads as absent — 0 and no flags respectively.
///   - `/Flags` must be an integer. A real-valued `64.0` contributes nothing.
///
/// The font program is consulted only when the descriptor left something
/// unset, and it can only ever add: neither flag is taken away by it.
func pdfDescriptorStyleFlags(
    _ document: inout PdfDocument, _ font: PdfDictionary, cache: inout PdfFontStyleCache
) -> PdfFontStyle {
    var descriptor = font["FontDescriptor"].flatMap { pdfFontsResolveDictionary(&document, $0) }
    if descriptor == nil {
        descriptor =
            font["DescendantFonts"]
            .flatMap { pdfFontsResolveArray(&document, $0) }
            .flatMap { $0.first }
            .flatMap { pdfFontsResolveDictionary(&document, $0) }
            .flatMap { $0["FontDescriptor"] }
            .flatMap { pdfFontsResolveDictionary(&document, $0) }
    }
    guard let descriptor else { return PdfFontStyle() }

    var italicAngle: Float = 0
    switch descriptor["ItalicAngle"] {
    case .integer(let value): italicAngle = Float(value)
    case .real(let value): italicAngle = value
    default: break
    }
    var flags: Int64 = 0
    if case .integer(let value) = descriptor["Flags"] { flags = value }

    // Bit 7 (value 64) is Italic; bit 19 (value 1 << 18) is ForceBold. Four
    // degrees is the bar for a declared slant to count as a style rather
    // than a token one.
    var style = PdfFontStyle(
        bold: flags & (1 << 18) != 0,
        italic: abs(italicAngle) >= 4 || flags & (1 << 6) != 0)

    if !style.italic || !style.bold, let reference = pdfFontFileReference(descriptor) {
        let embedded: PdfFontStyle
        if let hit = cache.byFontFile[reference] {
            embedded = hit
        } else {
            embedded = pdfEmbeddedStyleFlags(&document, reference)
            cache.byFontFile[reference] = embedded
        }
        style.italic = style.italic || embedded.italic
        style.bold = style.bold || embedded.bold
    }
    return style
}

// MARK: - the CMap lookup key

/// The object number an Identity-H CID font's CMap is stored under.
///
/// A font with no `/ToUnicode` can still be read if its own program carries a
/// character map, so the program's object number becomes the key. Failing
/// that, a Type0 font falls back to the descendant font's own object number,
/// which is where a mapping derived from `/CIDSystemInfo` goes instead.
///
/// That fallback is narrower than it looks: it sits *after* the descriptor
/// has been resolved, so a descendant font with no `/FontDescriptor` returns
/// nothing at all rather than falling back to its own number.
func pdfFontFileObjectNumber(
    _ document: inout PdfDocument, _ font: PdfDictionary
) -> UInt32? {
    let subtype = font["Subtype"]?.asName

    if subtype == Array("Type0".utf8) {
        // Only the identity encodings map CIDs to glyph indices directly;
        // any other CMap needs a different route entirely.
        guard let encoding = font["Encoding"]?.asName else { return nil }
        guard encoding == Array("Identity-H".utf8) || encoding == Array("Identity-V".utf8) else {
            return nil
        }
        guard let descendantsObject = font["DescendantFonts"],
            let descendants = pdfFontsResolveArray(&document, descendantsObject),
            let first = descendants.first,
            let cidFont = pdfFontsResolveDictionary(&document, first),
            let descriptorObject = cidFont["FontDescriptor"],
            let descriptor = pdfFontsResolveDictionary(&document, descriptorObject)
        else { return nil }

        if let reference = pdfFontFileReference(descriptor) { return reference.number }
        if case .reference(let id) = first { return id.number }
        return nil
    }

    guard let descriptorObject = font["FontDescriptor"],
        let descriptor = pdfFontsResolveDictionary(&document, descriptorObject)
    else { return nil }
    return pdfFontFileReference(descriptor)?.number
}
