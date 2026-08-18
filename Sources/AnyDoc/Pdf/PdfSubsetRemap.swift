/// Recovering a `/ToUnicode` CMap written against pre-subsetting glyph ids,
/// ported from `try_remap_subset_cmap` in `tounicode.rs`.
///
/// A subsetting producer keeps only the glyphs a document actually uses and
/// renumbers them 1, 2, 3, … — then writes a `/ToUnicode` still keyed by the
/// *original* glyph ids. The content stream draws the new CIDs, the CMap has
/// no entry for any of them, and the page extracts as **nothing at all**.
/// That is the failure this repairs, and it is common enough that the
/// reference carries a whole scoring apparatus for it.
///
/// **The repair is a guess, so it is never applied outright.** It produces a
/// second candidate CMap; the caller decodes the same bytes through both and
/// keeps whichever reads more like language (`PdfSingleByteDecode.swift`
/// scores them). A wrong guess that silently replaced the declared mapping
/// would turn readable text into confident nonsense, which is the worst
/// outcome available here.
///
/// **Three conditions gate it**, and each rules out a font where the CMap is
/// simply correct:
///
/// - **Identity-H or Identity-V.** Any other encoding means the CIDs are not
///   glyph ids in the first place.
/// - **The CMap's lowest source CID is above 2.** A CMap that starts at 1 is
///   already sequential and needs nothing.
/// - **The `/W` array starts at CID 2 or below, and does not itself cover the
///   CMap's highest CID.** A `/W` array that reaches the CMap's own top is
///   evidence the two agree, which is the normal subset layout rather than a
///   mismatch — a sparse array starting at 0 for `.notdef` with high entries
///   matching the CMap is exactly that case, and skipping it here is what
///   keeps this from firing on healthy fonts.

/// The `/DescendantFonts[0]` dictionary of a Type 0 font.
private func pdfDescendantCidFont(_ document: inout PdfDocument, _ font: PdfDictionary)
    -> PdfDictionary?
{
    guard let descendants = document.value(font, "DescendantFonts")?.asArray,
        let first = descendants.first
    else { return nil }
    return document.resolve(first).asDictionary
}

/// The first CID the `/W` array mentions.
///
/// `/W` is `[ c [w …] c_first c_last w … ]`, so the first token is a CID
/// whichever of the two forms follows it.
func pdfWArrayStartCid(_ document: inout PdfDocument, _ cidFont: PdfDictionary) -> UInt16? {
    guard let array = document.value(cidFont, "W")?.asArray, let first = array.first,
        let value = document.resolve(first).asInteger
    else { return nil }
    return UInt16(truncatingIfNeeded: value)
}

/// Whether the `/W` array assigns a width to `target`.
///
/// Both forms are walked: `c [w1 … wn]` covers `c` through `c + n - 1`, and
/// `c_first c_last w` covers the range it names. An unrecognised token stops
/// the walk rather than skipping — a malformed array should not be read as
/// covering more than it does.
func pdfWArrayCoversCid(
    _ document: inout PdfDocument, _ cidFont: PdfDictionary, _ target: UInt16
) -> Bool {
    guard let array = document.value(cidFont, "W")?.asArray else { return false }
    let target = Int(target)

    var index = 0
    while index < array.count {
        guard let first = document.resolve(array[index]).asInteger else { break }
        index += 1
        guard index < array.count else { break }

        if let widths = document.resolve(array[index]).asArray {
            let last = Int(first) + widths.count - 1
            if target >= Int(first) && target <= last { return true }
            index += 1
        } else if let last = document.resolve(array[index]).asInteger {
            index += 1
            // The width value, when it is there. The reference advances past
            // it only if the array has not already ended, and the range test
            // happens either way.
            if index < array.count { index += 1 }
            if target >= Int(first) && target <= Int(last) { return true }
        } else {
            break
        }
    }
    return false
}

/// The remapped candidate for a font's CMap, or `nil` when the CMap is fine.
///
/// **Two repairs, tried in order.** An explicit `/CIDToGIDMap` is authority:
/// the font states which glyph each CID draws, so a glyph-keyed `/ToUnicode`
/// can be re-keyed exactly. Only when there is no such table, or it yields
/// nothing, does the sequential *guess* apply. `cid-to-gid-repair.pdf` and
/// `cid-to-gid-absent.pdf` differ in that table alone and read `PLEH` and
/// `HELP` respectively — the order matters, and a fixture with an ascending
/// table could not have shown it.
///
/// Wave 134 recorded a hypothesis that this repair was inert. That was about
/// a different path — applying the table to the embedded font program's own
/// `cmap`, which is `pdfApplyCidToGidMap` and remains unwired. For *this*
/// path the hypothesis is refuted by measurement.
func pdfTryRemapSubsetCmap(
    _ document: inout PdfDocument, _ font: PdfDictionary, _ cmap: PdfToUnicodeCMap
) -> PdfToUnicodeCMap? {
    let encoding = document.value(font, "Encoding")?.asName
        .map { String(decoding: $0, as: UTF8.self) }
    guard encoding == "Identity-H" || encoding == "Identity-V" else { return nil }

    guard let minimum = cmap.minSourceCid, minimum > 2 else { return nil }
    guard let cidFont = pdfDescendantCidFont(&document, font) else { return nil }

    // The explicit table first. A failure here falls through to the guess
    // rather than giving up — the table may be present and useless.
    if let cidToGid = pdfCidToGidMap(&document, cidFont),
        let rekeyed = cmap.rekeyedByCidToGid(cidToGid)
    {
        return rekeyed
    }

    guard let start = pdfWArrayStartCid(&document, cidFont), start <= 2 else { return nil }

    // The `/W` array reaching the CMap's own top means the two agree.
    if let maximum = cmap.maxSourceCid, pdfWArrayCoversCid(&document, cidFont, maximum) {
        return nil
    }

    return cmap.remapToSequential()
}

/// Which of the two decodings a page settled on for one font.
enum PdfCMapChoice {
    case primary
    case remapped
}

/// The per-page record of that decision, ported from `CMapDecisionCache`.
///
/// **The decision is made once and then sticks**, which is the point of the
/// type. Scoring every string on its own would let a document alternate
/// between the two mappings as short strings score noisily — a page reading
/// half one way and half the other. So the candidates are accumulated until
/// 240 bytes have been seen, judged together on that larger sample, and the
/// verdict reused for the rest of the page.
///
/// Two thresholds, both from the reference: the remapped decoding must beat
/// the primary by more than **5** to win the sticky decision, and by more
/// than **3** to win any single string before the decision is made. The
/// declared mapping is what the font itself claims, so a near-tie is not
/// evidence enough to overrule it.
///
/// Keyed by the `/ToUnicode` stream's object number, as the reference keys
/// it — two resource names sharing one CMap stream share the decision, and a
/// font with no `/ToUnicode` reference falls together under 0.
struct PdfCMapDecisions {
    private struct Entry {
        var sampleBytes = 0
        var primarySample = ""
        var remappedSample = ""
        var choice: PdfCMapChoice?
    }

    private var entries: [Int: Entry] = [:]

    /// The settled decision, if this font has one yet.
    func choice(_ key: Int) -> PdfCMapChoice? { entries[key]?.choice }

    /// Add one string's pair of decodings to the sample, and return the
    /// decision if there is now enough evidence for one.
    mutating func consider(
        _ key: Int, primary: String, remapped: String, byteCount: Int
    ) -> PdfCMapChoice? {
        let sampleTargetBytes = 240

        var entry = entries[key] ?? Entry()
        entry.sampleBytes += byteCount
        entry.primarySample += primary
        entry.remappedSample += remapped

        if entry.choice == nil && entry.sampleBytes >= sampleTargetBytes {
            entry.choice =
                pdfScoreText(entry.remappedSample) > pdfScoreText(entry.primarySample) + 5
                ? .remapped : .primary
        }

        entries[key] = entry
        return entry.choice
    }
}

/// Decode a run of bytes through one CMap, reading `codeByteLength` bytes at
/// a time.
///
/// **What happens to a code the map does not mention depends on its width,
/// and the asymmetry is the point.**
///
/// A single-byte code that is unmapped falls back to Latin-1 — the byte *is*
/// the character in every legacy encoding, so a `/ToUnicode` covering part of
/// the range still leaves the rest readable. Note this is plain Latin-1 and
/// not Windows-1252: `0x92` becomes U+0092, a C1 control, rather than a
/// curly quote. `pdfNormaliseCp1252Controls` gets its say later.
///
/// A two-byte code is dropped instead. Those are CIDs — font-internal glyph
/// indices with no relationship to Unicode — and rendering them produces the
/// confident CJK-looking nonsense this port exists to avoid.
///
/// A mapping that yields U+FFFD is treated as no mapping at all, in both
/// widths: the replacement character is the CMap admitting it does not know.
func pdfDecodeThroughCMap(_ cmap: PdfToUnicodeCMap, _ bytes: [UInt8]) -> String {
    var out = ""

    if cmap.codeByteLength == 1 {
        for byte in bytes {
            if let text = cmap.lookup(UInt32(byte)), !text.unicodeScalars.contains("\u{FFFD}") {
                out += text
            } else if byte >= 0x20 {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            }
        }
        return out
    }

    let width = cmap.codeByteLength
    var index = 0
    while index < bytes.count {
        var code: UInt32 = 0
        for offset in 0..<width where index + offset < bytes.count {
            code = (code << 8) | UInt32(bytes[index + offset])
        }
        if let text = cmap.lookup(code), !text.unicodeScalars.contains("\u{FFFD}") { out += text }
        index += width
    }
    return out
}

/// The three CMaps a font's `/ToUnicode` can produce, ported from
/// `CMapEntry` and `build_cmap_entry_from_stream` in `tounicode.rs`.
///
/// A declared `/ToUnicode` is not automatically the best answer available.
/// Beside it sit a **remapped** candidate — the subset repairs in this file —
/// and a **fallback** built from the embedded font's own `cmap` table. Which
/// of the three leads is decided here, before any text is decoded, and the
/// losers stay available to the decoder rather than being discarded.
struct PdfCMapEntry {
    var primary: PdfToUnicodeCMap
    var remapped: PdfToUnicodeCMap?
    var fallback: PdfToUnicodeCMap?
}

/// The fallback CMap for a Type 0 font: its embedded font program's own
/// `cmap` table, re-keyed by `/CIDToGIDMap` when the font carries one.
///
/// Gated on `Identity-H`/`Identity-V`, because only there is a CID the same
/// number as a glyph — the equivalence this whole substitution rests on.
func pdfType0FallbackCMap(_ document: inout PdfDocument, _ font: PdfDictionary)
    -> PdfToUnicodeCMap?
{
    guard document.value(font, "Subtype")?.asName.map({ String(decoding: $0, as: UTF8.self) })
        == "Type0"
    else { return nil }
    let encoding = document.value(font, "Encoding")?.asName
        .map { String(decoding: $0, as: UTF8.self) }
    guard encoding == "Identity-H" || encoding == "Identity-V" else { return nil }

    guard let cidFont = pdfDescendantCidFont(&document, font),
        let descriptor = document.value(cidFont, "FontDescriptor")?.asDictionary
    else { return nil }
    let program =
        document.value(descriptor, "FontFile2")?.asStream
        ?? document.value(descriptor, "FontFile3")?.asStream
    guard let program, let data = document.decodedStream(program) else { return nil }

    guard let parsed = pdfParseTrueTypeCMap(data), !parsed.isEmpty else { return nil }
    let cmap = PdfToUnicodeCMap(glyphToCharacter: parsed.glyphToCharacter)

    // The same table that repairs a declared CMap repairs this one.
    if let cidToGid = pdfCidToGidMap(&document, cidFont),
        let repaired = cmap.rekeyedByCidToGid(cidToGid)
    {
        return repaired
    }
    return cmap
}

/// Assemble the three candidates and decide which leads.
///
/// **Two reorderings, and each one exists because a plausible answer is
/// wrong.**
///
/// *A `/ToUnicode` with fewer than ten entries is not trusted to lead.* Some
/// producers write a stub map covering a handful of codes and leave the rest
/// of the document unmapped; the font's own table describes far more of it.
/// The stub becomes the remapped candidate rather than being thrown away,
/// since it may still be right about the codes it does cover.
///
/// *A font `cmap` with more entries than the primary outranks a sequential
/// remap.* This is the guard rail on `remapToSequential`, and the reference
/// states the reason outright: subset fonts number their glyphs **in the
/// order the document first uses them**, so sorting the old CIDs and dealing
/// them out in order produces text that is readable and scrambled — `HELP`
/// where the font says `WORD`. An embedded `cmap` is not a guess and wins
/// whenever it is the richer description. `cid-truetype-promoted.pdf` and
/// `cid-truetype-absent.pdf` are that pair, and before this rule was ported
/// this port answered `HELP` to both.
func pdfBuildCMapEntry(
    _ document: inout PdfDocument, _ font: PdfDictionary, _ parsed: PdfToUnicodeCMap,
    skipTrueTypeFallback: Bool = false
) -> PdfCMapEntry {
    var primary = parsed
    var remapped = pdfTryRemapSubsetCmap(&document, font, parsed)
    // Parsing the embedded program is the expensive part of building an
    // entry, which is why the reference has a mode that skips it.
    var fallback = skipTrueTypeFallback ? nil : pdfType0FallbackCMap(&document, font)

    let primaryEntries = primary.entryCount
    if primaryEntries < 10, let stand_in = fallback {
        fallback = nil
        remapped = primary
        primary = stand_in
    }

    if remapped != nil, let candidate = fallback, candidate.entryCount > primaryEntries {
        let displaced = remapped
        remapped = fallback
        fallback = displaced
    }

    return PdfCMapEntry(primary: primary, remapped: remapped, fallback: fallback)
}

/// Whether the fallback decoding should displace the one already chosen.
///
/// Three ways it can win, and the first two are about *coverage* rather than
/// quality. A chosen decoding that came out empty loses to anything. So does
/// one that produced fewer than half the characters the bytes should have
/// yielded — two bytes per CID, so `n` bytes should give `n / 2` characters,
/// and falling short of half that means the map is missing most of the
/// codes. Only then does the text itself get compared, where the fallback
/// needs the same margin of 3 that every other candidate does.
func pdfPrefersFallback(_ fallback: String, over decoded: String, byteCount: Int) -> Bool {
    guard !fallback.isEmpty else { return false }
    if decoded.isEmpty { return true }
    // Scalars, not characters: the reference counts Rust `char`s.
    let expected = byteCount / 2
    if expected > 0 && decoded.unicodeScalars.count * 2 < expected { return true }
    return pdfScoreText(fallback) > pdfScoreText(decoded) + 3
}
