/// The ToUnicode string helpers, ported from `tounicode.rs`:
/// `parse_hex_u16`, `hex_to_unicode_string`, `normalize_tounicode_destination`,
/// `hex_to_unicode_scalar` and `find_usecmap_name`.
///
/// A CMap's destinations are UTF-16BE hex strings, and turning one into text
/// is less mechanical than it looks: surrogate pairs must survive, a
/// one-byte destination is accepted although no specification allows it, and
/// some producers write a *list* of alternatives into a single destination,
/// which has to be collapsed back to one character.
///
/// These sit on the path `PdfToUnicode.swift` already implements as a byte
/// scanner. That scanner does **not** apply the normalisation below — see
/// the note on `pdfNormalizeToUnicodeDestination`.

/// A hex string as a 16-bit code, trimmed first.
func pdfParseHexU16(_ hex: String) -> UInt16? {
    UInt16(hex.rustTrim(), radix: 16)
}

/// A UTF-16BE hex destination as text.
///
/// White space anywhere in the hex is ignored, and an odd number of digits
/// is rejected outright. Pairs of bytes become UTF-16 code units, so
/// `D83CDF1F` is one emoji rather than two dropped halves.
///
/// A **single** byte that decodes to something printable is accepted as a
/// last resort. Nothing in the specification permits a one-byte destination,
/// but producers emit them, and the reference would rather have the
/// character than nothing.
func pdfHexToUnicodeString(_ hex: String) -> String? {
    let cleaned = hex.unicodeScalars.filter { !pdfIsAsciiWhitespaceScalar($0) }
        .map(Character.init)
    if cleaned.isEmpty || !cleaned.count.isMultiple(of: 2) { return nil }

    var bytes: [UInt8] = []
    var index = 0
    while index < cleaned.count {
        guard let byte = UInt8(String(cleaned[index...(index + 1)]), radix: 16) else { return nil }
        bytes.append(byte)
        index += 2
    }

    if bytes.count.isMultiple(of: 2) {
        var units: [UInt16] = []
        var position = 0
        while position + 1 < bytes.count {
            units.append(UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1]))
            position += 2
        }
        // `String::from_utf16` *fails* on an unpaired surrogate rather than
        // substituting — so a destination naming half a pair falls through
        // to the one-byte path below and, being two bytes, to nothing.
        if let result = pdfStringFromUtf16(units), !result.isEmpty {
            return pdfNormalizeToUnicodeDestination(result)
        }
    }

    if bytes.count == 1 {
        let scalar = Unicode.Scalar(bytes[0])
        let character = Character(scalar)
        // Rust's `char::is_control` covers both C0 and C1; tab and newline
        // are readmitted by name.
        if !pdfIsControlScalar(scalar) || character == "\t" || character == "\n" {
            return String(character)
        }
    }
    return nil
}

/// Collapse a destination that names a list of alternatives.
///
/// Some producers put every acceptable whitespace codepoint, or every
/// acceptable hyphen, into one destination. Left alone that yields a run of
/// characters where the document has one. The signature is narrow on
/// purpose: an ordinary multi-character mapping — a ligature expanding to
/// `ffi`, say — must survive untouched.
///
/// **`PdfToUnicode.swift`'s scanner does not call this.** Routing it through
/// here is a correctness fix that needs its own wave, since the two reach
/// destinations by different paths.
func pdfNormalizeToUnicodeDestination(_ text: String) -> String {
    // "More than one character" as the reference asks it: is there a second?
    var iterator = text.makeIterator()
    _ = iterator.next()
    let isMultiCharacter = iterator.next() != nil
    guard isMultiCharacter else { return text }

    // All white space, and at least one of it a control — which is what
    // distinguishes the malformed list from a run of ordinary spaces.
    if text.allSatisfy(\.isWhitespace)
        && text.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" })
    {
        return text.contains("\t") ? "\t" : " "
    }

    // A hyphen list must actually contain the soft hyphen to qualify.
    let hyphens: Set<Character> = ["-", "\u{00ad}", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2212}"]
    if text.contains("\u{00ad}") && text.allSatisfy({ hyphens.contains($0) }) { return "-" }

    return text
}

/// A destination that is exactly one scalar, as that scalar.
///
/// Anything longer is rejected rather than truncated — a range's base must
/// be a single character for the arithmetic that follows to mean anything.
func pdfHexToUnicodeScalar(_ hex: String) -> UInt32? {
    guard let text = pdfHexToUnicodeString(hex) else { return nil }
    var iterator = text.unicodeScalars.makeIterator()
    guard let first = iterator.next(), iterator.next() == nil else { return nil }
    return first.value
}

/// The name a CMap defers to with `usecmap`, without its slash.
///
/// Read line by line, taking the token *before* the operator. A `usecmap`
/// with nothing before it on the line is ignored, and only a name beginning
/// with `/` counts.
func pdfFindUsecmapName(_ text: String) -> String? {
    for line in text.rustLines() where line.contains("usecmap") {
        let parts = line.rustSplitWhitespace()
        for (index, part) in parts.enumerated() where part == "usecmap" && index > 0 {
            let name = String(parts[index - 1]).rustTrim()
            if name.hasPrefix("/") { return String(name.dropFirst()) }
        }
    }
    return nil
}

/// Rust's `char::is_whitespace` for a scalar, restricted to ASCII — which is
/// what `is_ascii_whitespace` filters in the hex cleaner.
private func pdfIsAsciiWhitespaceScalar(_ scalar: Unicode.Scalar) -> Bool {
    scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\u{0C}" || scalar == "\r"
}

/// Rust's `char::is_control`: the C0 and C1 ranges.
private func pdfIsControlScalar(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value <= 0x1F || (scalar.value >= 0x7F && scalar.value <= 0x9F)
}

/// `String::from_utf16`, which rejects unpaired surrogates rather than
/// replacing them.
private func pdfStringFromUtf16(_ units: [UInt16]) -> String? {
    var scalars = String.UnicodeScalarView()
    var index = 0
    while index < units.count {
        let unit = units[index]
        if unit >= 0xD800 && unit <= 0xDBFF {
            guard index + 1 < units.count, units[index + 1] >= 0xDC00, units[index + 1] <= 0xDFFF
            else { return nil }
            let value = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(units[index + 1] - 0xDC00)
            guard let scalar = Unicode.Scalar(value) else { return nil }
            scalars.append(scalar)
            index += 2
            continue
        }
        if unit >= 0xDC00 && unit <= 0xDFFF { return nil }
        guard let scalar = Unicode.Scalar(unit) else { return nil }
        scalars.append(scalar)
        index += 1
    }
    return String(scalars)
}
