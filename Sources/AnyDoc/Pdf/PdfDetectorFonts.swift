/// Whether a page's fonts can produce readable text at all, ported from the
/// font half of `detector.rs`.
///
/// This is what stands between a document being extracted and a document
/// being sent to OCR, and it is the port's defence against its own worst
/// failure mode. A page whose only font is Identity-H with no `/ToUnicode`
/// extracts *something* — a stream of raw CIDs that is well-formed, looks
/// like text to every check that does not read it, and is nonsense. So does
/// a Type 3 page, where each glyph is a drawing procedure with no character
/// behind it. Recognising those is the difference between failing loudly and
/// failing invisibly.
///
/// **Usage-based, not resource-based.** The question is not what fonts the
/// page *declares* but which ones its `Tf` operators actually select. A
/// resource dictionary routinely lists fonts no content stream touches, and
/// judging the page on those misreads it. The reference keeps two versions
/// of each check for exactly this reason and marks the resource-based ones
/// `#[cfg(test)]`; only the usage-based ones are ported here.
///
/// Fonts are keyed by **object id**, never by name. `/F1` in two resource
/// dictionaries is legally two different fonts, and a name-keyed map silently
/// merges them.

/// What the detector needs to know about one font.
struct PdfDetectorFontInfo {
    var subtype: [UInt8]?
    var encoding: [UInt8]?
    var hasToUnicode: Bool
    /// The font dictionary itself, which the fallback checks re-read for
    /// `/DescendantFonts` and the embedded font program.
    var dict: PdfDictionary
}

/// A page's resource dictionaries, most specific first.
///
/// A page inherits `/Resources` from its `/Pages` ancestors, and a name
/// defined closer to the page shadows the same name above it (ISO 32000-1
/// §7.7.3.4). The order here *is* the shadowing rule: the first dictionary
/// that defines a name wins.
///
/// The walk is depth-capped. A malformed file can make `/Parent` a cycle,
/// and a detector that hangs on a hostile document is worse than one that
/// misreads it.
func pdfPageResourceChain(_ document: inout PdfDocument, _ page: PdfDictionary) -> [PdfDictionary] {
    var chain: [PdfDictionary] = []
    if let own = document.value(page, "Resources")?.asDictionary { chain.append(own) }

    var node = page
    for _ in 0..<32 {
        guard let parent = document.value(node, "Parent")?.asDictionary else { break }
        if let resources = document.value(parent, "Resources")?.asDictionary {
            chain.append(resources)
        }
        node = parent
    }
    return chain
}

/// The `/Font` sub-dictionary of a resource dictionary, followed through a
/// reference if that is how it was written.
private func pdfFontDictionary(_ document: inout PdfDocument, _ resources: PdfDictionary)
    -> PdfDictionary?
{
    document.value(resources, "Font")?.asDictionary
}

/// Record every font a resource dictionary names, keyed by object id.
///
/// Inline font dictionaries are skipped: they have no object id, so there is
/// nothing to key them by and nothing for a `Tf` name to resolve to. They are
/// vanishingly rare, and the reference skips them too.
func pdfCollectFontsFromResources(
    _ document: inout PdfDocument, _ resources: PdfDictionary,
    into fonts: inout [PdfObjectId: PdfDetectorFontInfo]
) {
    guard let fontDictionary = pdfFontDictionary(&document, resources) else { return }
    for key in fontDictionary.keys {
        guard let id = fontDictionary[key]?.asReference else { continue }
        if fonts[id] != nil { continue }
        guard let dict = document.object(id).asDictionary else { continue }
        fonts[id] = PdfDetectorFontInfo(
            subtype: document.value(dict, "Subtype")?.asName,
            encoding: document.value(dict, "Encoding")?.asName,
            hasToUnicode: document.value(dict, "ToUnicode") != nil,
            dict: dict)
    }
}

/// The object id a font name resolves to in one resource dictionary.
func pdfLookupFontId(
    _ document: inout PdfDocument, _ resources: PdfDictionary, _ name: [UInt8]
) -> PdfObjectId? {
    guard let fontDictionary = pdfFontDictionary(&document, resources) else { return nil }
    return fontDictionary[name]?.asReference
}

/// Resolve the font names a content stream used, honouring shadowing.
///
/// Each name is looked up down the chain and stops at its first hit — which
/// is the whole of the inheritance rule.
func pdfResolveFontNames(
    _ document: inout PdfDocument, chain: [PdfDictionary], names: Set<[UInt8]>,
    into used: inout Set<PdfObjectId>
) {
    for name in names {
        for resources in chain {
            if let id = pdfLookupFontId(&document, resources, name) {
                used.insert(id)
                break
            }
        }
    }
}

/// Whether a CID font's `/W` array suggests its CIDs are really Unicode.
///
/// Chromium and wkhtmltopdf emit Identity-H where the CID *is* the codepoint,
/// so the text extracts correctly with no `/ToUnicode` at all. A subsetted
/// font instead numbers its glyphs from zero. The median CID separates them:
/// at or above `0x41` these are letters, below it they are glyph indices.
///
/// `/W` must be a direct array. A reference here yields `false` — the
/// reference matches on the object rather than resolving it, and a font that
/// writes `/W` indirectly is judged to have no fallback.
func pdfCidValuesLookLikeUnicode(_ document: inout PdfDocument, _ cidFont: PdfDictionary) -> Bool {
    guard case .array(let widths)? = cidFont["W"] else { return false }

    // `/W` is either `[cid [w1 w2 …]]` or `[first last w]`, and the two forms
    // interleave freely in one array.
    var cids: [UInt16] = []
    var index = 0
    while index < widths.count {
        guard let raw = widths[index].asInteger else {
            index += 1
            continue
        }
        // The CID is recorded before anything is known about what follows it,
        // so a truncated `/W` still contributes its last entry. The range
        // form below then records it a *second* time, since its own loop is
        // inclusive of the start — reproduced deliberately, because the
        // verdict is a median and a repeated value shifts it.
        let cid = UInt16(truncatingIfNeeded: raw)
        cids.append(cid)

        guard index + 1 < widths.count else {
            index += 1
            continue
        }
        if let list = widths[index + 1].asArray {
            // `[cid [w1 w2 …]]` — consecutive CIDs, one width each.
            for offset in stride(from: 1, to: list.count, by: 1) {
                cids.append(cid &+ UInt16(truncatingIfNeeded: offset))
            }
            index += 2
        } else if index + 2 < widths.count {
            // `[first last w]`.
            if let last = widths[index + 1].asInteger {
                let end = UInt16(truncatingIfNeeded: last)
                if cid <= end {
                    for value in cid...end { cids.append(value) }
                }
            }
            index += 3
        } else {
            index += 1
        }
    }

    if cids.isEmpty { return false }
    cids.sort()
    return cids[cids.count / 2] >= 0x41
}

/// Whether an embedded font program carries a usable Unicode `cmap`.
///
/// The reference asks `ttf-parser`; this asks the parser wave 110 wrote. A
/// font with a Unicode subtable holding at least one mapping can recover its
/// own text, which is what makes an otherwise-undecodable Identity-H font
/// readable after all.
func pdfEmbeddedFontHasCmap(_ document: inout PdfDocument, _ fontFile: PdfObjectId) -> Bool {
    guard let stream = document.object(fontFile).asStream,
        let data = document.decodedStream(stream)
    else { return false }
    // **The `cmap` table specifically**, not `pdfParseTrueTypeCMap`, which
    // falls back to the `post` table's glyph names. The reference draws the
    // same line: its detector asks `face.tables().cmap` while its extractor
    // is free to recover text however it can.
    //
    // The distinction is not pedantic. A font readable only through glyph
    // names is still one the *detector* should call undecodable, because
    // that verdict feeds the OCR recommendation — and wiring the fallback
    // in here silently flipped four probes while the Markdown went on
    // matching.
    guard let table = pdfTrueTypeTables(data)["cmap"] else { return false }
    var result = PdfTrueTypeCMap()
    guard let subtableCount = pdfReadCMapSubtableCount(data, table.lowerBound) else {
        return false
    }
    for index in 0..<subtableCount {
        let record = table.lowerBound + 4 + index * 8
        guard let offset = pdfReadCMapSubtableOffset(data, record) else { break }
        pdfParseCMapSubtable(data, table.lowerBound + offset, into: &result)
        if !result.isEmpty { return true }
    }
    return false
}

/// Whether an Identity-H font can be decoded despite having no `/ToUnicode`.
func pdfIdentityHFontHasFallback(_ document: inout PdfDocument, _ font: PdfDictionary) -> Bool {
    guard let descendants = document.value(font, "DescendantFonts")?.asArray,
        let first = descendants.first
    else { return false }
    let cidFont: PdfDictionary?
    if let id = first.asReference {
        cidFont = document.object(id).asDictionary
    } else {
        cidFont = first.asDictionary
    }
    guard let cidFont else { return false }

    // Fallback one: the CIDs are already Unicode.
    if pdfCidValuesLookLikeUnicode(&document, cidFont) { return true }

    // Fallback two: the embedded program can map its own glyphs.
    guard let descriptor = document.value(cidFont, "FontDescriptor")?.asDictionary else {
        return false
    }
    // Read **raw**, not resolved. `document.value` follows a reference and
    // hands back the stream, at which point `asReference` is nil and every
    // embedded font looks absent — which is exactly what happened, and what
    // the `--pagefonts` probe caught on two corpus documents.
    let program =
        descriptor["FontFile2"]?.asReference ?? descriptor["FontFile3"]?.asReference
    guard let program else { return false }
    return pdfEmbeddedFontHasCmap(&document, program)
}

/// Whether the page's used fonts are undecodable Identity-H and nothing else.
///
/// The `and nothing else` is the point. An undecodable font *alongside* a
/// readable one is supplementary — a symbol set, a logo face — and the page
/// still has text worth extracting. Only when every used font is undecodable
/// does the page need OCR.
func pdfUsedFontsHaveIdentityHNoToUnicode(
    _ document: inout PdfDocument, used: Set<PdfObjectId>,
    fonts: [PdfObjectId: PdfDetectorFontInfo]
) -> Bool {
    var hasUndecodableIdentityH = false
    var hasDecodableFont = false

    for id in used {
        guard let info = fonts[id] else { continue }
        switch info.subtype.map({ String(decoding: $0, as: UTF8.self) }) {
        case "Type0":
            let encoding = info.encoding.map { String(decoding: $0, as: UTF8.self) }
            guard encoding == "Identity-H" || encoding == "Identity-V" else {
                hasDecodableFont = true
                continue
            }
            if info.hasToUnicode || pdfIdentityHFontHasFallback(&document, info.dict) {
                hasDecodableFont = true
                continue
            }
            hasUndecodableIdentityH = true
        case "Type3":
            // Judged by the Type 3 check instead, which has its own rule.
            break
        default:
            // Type1, TrueType, MMType1 — decodable as a class.
            hasDecodableFont = true
        }
    }
    return hasUndecodableIdentityH && !hasDecodableFont
}

/// Whether every used font is a Type 3 without `/ToUnicode`.
///
/// A Type 3 glyph is a drawing procedure, so its character code means only
/// what the font says it means. With a `/ToUnicode` it is readable; without
/// one there is nothing behind the code at all. A single `/ToUnicode`
/// disqualifies the whole page, because then that font's text is recoverable.
func pdfUsedFontsAreOnlyType3(
    used: Set<PdfObjectId>, fonts: [PdfObjectId: PdfDetectorFontInfo]
) -> Bool {
    if used.isEmpty { return false }
    var hasType3 = false
    for id in used {
        guard let info = fonts[id] else { continue }
        guard info.subtype.map({ String(decoding: $0, as: UTF8.self) }) == "Type3" else {
            return false
        }
        if info.hasToUnicode { return false }
        hasType3 = true
    }
    return hasType3
}

/// Whether at least one used font can produce Unicode.
///
/// This is the counterweight to the raw-byte statistics elsewhere in the
/// detector. A CID font with a `/ToUnicode` extracts perfectly well while
/// producing almost no recognisable *bytes* in the content stream, so a page
/// judged on bytes alone looks scanned when it is not.
func pdfUsedFontsHaveDecodableText(
    _ document: inout PdfDocument, used: Set<PdfObjectId>,
    fonts: [PdfObjectId: PdfDetectorFontInfo]
) -> Bool {
    for id in used {
        guard let info = fonts[id] else { continue }
        if info.hasToUnicode { return true }
        switch info.subtype.map({ String(decoding: $0, as: UTF8.self) }) {
        case "Type1", "TrueType", "MMType1":
            return true
        case "Type0":
            if pdfIdentityHFontHasFallback(&document, info.dict) { return true }
        default:
            break
        }
    }
    return false
}
