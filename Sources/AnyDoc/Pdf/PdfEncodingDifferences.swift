/// The `/Differences` encoding array, ported from
/// `parse_encoding_dictionary` and its helpers in pdf-inspector's
/// `extractor/fonts.rs`.
///
/// A simple font maps byte codes to glyphs through an encoding, and
/// `/Differences` is how a document overrides that: a flat array mixing
/// numbers and names, where a number sets the next code and each name that
/// follows takes the code after the last. So `[65 /A /B 200 /eacute]` assigns
/// 65, 66 and 200.
///
/// Wave 57's glyph table is what turns those names into characters.

/// What a `/Differences` array yielded.
struct PdfEncodingDifferences: Equatable {
    /// Byte code to character, for the names that resolved.
    var map: [UInt8: Unicode.Scalar] = [:]
    /// Codes whose glyph was named `gidNNNNN`. Those are raw glyph indices
    /// into the embedded font's own tables and mean nothing without it, so
    /// they are recorded rather than mapped — a caller can tell that the text
    /// is undecodable without a `/ToUnicode` map rather than silently wrong.
    var gidCodes: [UInt8] = []
}

/// Whether a character is one of the five Latin ligatures the reference
/// counts. It only logs them, so the count has no effect on the result.
func pdfIsLigatureScalar(_ scalar: Unicode.Scalar) -> Bool {
    (0xFB00...0xFB04).contains(scalar.value)
}

/// A font name with any subset prefix removed: `ABCDEF+Aptos` is `Aptos`.
func pdfStripSubsetPrefix(_ fontName: String) -> String {
    guard let plus = fontName.firstIndex(of: "+") else { return fontName }
    return String(fontName[fontName.index(after: plus)...])
}

/// Glyph names that mean something only in a particular font.
///
/// Deliberately font-scoped: `/gNNN` names are private, so the same name in
/// another font means something else entirely. The reference carries exactly
/// one such case, for Aptos subsets out of Office, which expose the `ff`
/// ligature as `/g431` with no `/ToUnicode` map to explain it.
func pdfPrivateGlyphToScalar(_ glyphName: String, baseFontName: String?) -> Unicode.Scalar? {
    guard let baseFontName else { return nil }
    let stripped = pdfStripSubsetPrefix(baseFontName)
    if stripped.asciiLowercased() == "aptos" && glyphName == "g431" {
        return Unicode.Scalar(0xFB00)
    }
    return nil
}

/// Whether a glyph name is a raw glyph index, `gid` followed by digits.
func pdfIsGidGlyphName(_ name: String) -> Bool {
    let scalars = Array(name.unicodeScalars)
    guard name.hasPrefix("gid"), scalars.count >= 4 else { return false }
    return scalars[3...].allSatisfy { $0 >= "0" && $0 <= "9" }
}

/// Parse a `/Differences` array into a code-to-character map.
///
/// Entries the glyph table cannot resolve are simply left out of the map, so
/// the byte keeps whatever the base encoding gave it rather than becoming a
/// replacement character.
func pdfParseEncodingDifferences(
    _ differences: [PdfObject], baseFontName: String? = nil
) -> PdfEncodingDifferences {
    var result = PdfEncodingDifferences()
    var currentCode: UInt8 = 0

    for item in differences {
        switch item {
        case .integer(let value):
            // Truncated to a byte exactly as `n as u8` does, so a code past
            // 255 wraps rather than being rejected.
            currentCode = UInt8(truncatingIfNeeded: value)
        case .name(let nameBytes):
            let glyphName = String(decoding: nameBytes, as: UTF8.self)
            let scalar =
                pdfGlyphToScalar(glyphName)
                ?? pdfPrivateGlyphToScalar(glyphName, baseFontName: baseFontName)

            if pdfIsGidGlyphName(glyphName) { result.gidCodes.append(currentCode) }
            if let scalar { result.map[currentCode] = scalar }

            // Wrapping, again as the reference has it: a name at code 255 is
            // followed by code 0.
            currentCode = currentCode &+ 1
        default:
            // Anything else in the array is ignored *without* advancing the
            // code, so a stray value does not shift the names after it.
            break
        }
    }
    return result
}

