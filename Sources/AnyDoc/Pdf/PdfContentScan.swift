/// The content-stream scanner, ported from `detector.rs`:
/// `scan_content_for_text_operators`, `extract_font_name_before_tf`,
/// `collect_text_chars_before` and `hex_val`.
///
/// Detection has to decide whether a page carries real text before anything
/// is decoded, and it does so by reading the raw content stream as bytes —
/// no object graph, no fonts, no decompression beyond what the caller
/// already did. It counts text operators against path operators, because a
/// page whose "text" is vector outlines has thousands of the latter and
/// almost none of the former.
///
/// Along the way it collects the distinct bytes that appear inside string
/// operands, which is what later tells an Identity-H page with no ToUnicode
/// from a page of ordinary text.
///
/// This is the pure, byte-level half of the detector. The half that walks
/// the document — resources, font dictionaries, image XObjects — is not
/// ported.

/// What a scan found.
struct PdfContentScan: Equatable {
    var textOperators: UInt32 = 0
    /// **Always zero.** The reference returns a field here and never
    /// increments it: `Do` invokes any XObject, including forms that hold
    /// text, so images are counted by walking the resource dictionary
    /// instead. Kept so the shape matches.
    var imageCount: UInt32 = 0
    var pathOperators: UInt32 = 0
    var fontChanges: UInt32 = 0
}

/// Rust's `u8::is_ascii_whitespace`: space, tab, newline, form feed and
/// carriage return — and **not** the null byte, which PDF also treats as
/// white space.
func pdfIsAsciiWhitespaceByte(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
}

/// The numeric value of a hex digit.
func pdfHexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: return byte - 0x30
    case 0x61...0x66: return byte - 0x61 + 10
    case 0x41...0x46: return byte - 0x41 + 10
    default: return nil
    }
}

/// Scan a content stream for the operators detection cares about.
///
/// - Parameters:
///   - uniqueCharacters: accumulates the distinct bytes seen inside string
///     operands, across every stream scanned for a page.
///   - usedFontNames: accumulates the font names named by `Tf`.
func pdfScanContentForTextOperators(
    _ content: [UInt8], uniqueCharacters: inout Set<UInt8>, usedFontNames: inout Set<[UInt8]>
) -> PdfContentScan {
    var scan = PdfContentScan()

    func isWordStart(_ position: Int) -> Bool {
        position == 0 || pdfIsAsciiWhitespaceByte(content[position - 1])
    }
    func isWordEnd(_ position: Int) -> Bool {
        position + 1 >= content.count || pdfIsAsciiWhitespaceByte(content[position + 1])
    }

    var index = 0
    while index < content.count {
        let byte = content[index]

        if byte == UInt8(ascii: "T"), index + 1 < content.count {
            let next = content[index + 1]
            if next == UInt8(ascii: "j") || next == UInt8(ascii: "J") {
                // `\n` and `\r` are named again here even though
                // `is_ascii_whitespace` already covers them — harmless, and
                // kept so the condition reads as the reference's does.
                if index + 2 >= content.count || pdfIsAsciiWhitespaceByte(content[index + 2])
                    || content[index + 2] == UInt8(ascii: "\n")
                    || content[index + 2] == UInt8(ascii: "\r")
                {
                    scan.textOperators += 1
                    pdfCollectTextCharactersBefore(content, at: index, into: &uniqueCharacters)
                }
            } else if next == UInt8(ascii: "f") {
                // Some writers run `Tf` straight into the next operand with
                // no space — `25 Tf[<01>…` — so an opening delimiter counts
                // as a terminator too.
                let followers: Set<UInt8> = [
                    UInt8(ascii: "["), UInt8(ascii: "("), UInt8(ascii: "<"), UInt8(ascii: "/"),
                ]
                if index + 2 >= content.count || pdfIsAsciiWhitespaceByte(content[index + 2])
                    || content[index + 2] == UInt8(ascii: "\n")
                    || content[index + 2] == UInt8(ascii: "\r")
                    || followers.contains(content[index + 2])
                {
                    scan.fontChanges += 1
                    if let name = pdfExtractFontNameBeforeTf(content, at: index) {
                        usedFontNames.insert(name)
                    }
                }
            }
        }

        // Path operators, which are what a page of outlined text is made of.
        // Single-byte ones must stand alone as words.
        switch byte {
        case UInt8(ascii: "m"), UInt8(ascii: "l"), UInt8(ascii: "c"), UInt8(ascii: "h"),
            UInt8(ascii: "f"), UInt8(ascii: "S"), UInt8(ascii: "s"), UInt8(ascii: "B"),
            UInt8(ascii: "F"):
            if isWordStart(index) && isWordEnd(index) { scan.pathOperators += 1 }
        case UInt8(ascii: "r"):
            // `re`, whose terminator is only tested for white space — an
            // `re` run into a delimiter is not counted.
            if index + 1 < content.count, content[index + 1] == UInt8(ascii: "e"),
                isWordStart(index),
                index + 2 >= content.count || pdfIsAsciiWhitespaceByte(content[index + 2])
            {
                scan.pathOperators += 1
            }
        default:
            break
        }
        // `f*` is checked separately because `f` already matched above; a
        // lone `f` and an `f*` are both one path operator, never two.
        if byte == UInt8(ascii: "f"), index + 1 < content.count,
            content[index + 1] == UInt8(ascii: "*"), isWordStart(index),
            index + 2 >= content.count || pdfIsAsciiWhitespaceByte(content[index + 2])
        {
            scan.pathOperators += 1
        }

        index += 1
    }
    return scan
}

/// The font name in `/Name size Tf`, without its slash.
///
/// Scans backward from the `T` past white space, the size, and more white
/// space, then expects a `/`. Anything else in the way — a bracket, a space
/// inside what should be the name — abandons the search rather than
/// guessing.
func pdfExtractFontNameBeforeTf(_ content: [UInt8], at tfPosition: Int) -> [UInt8]? {
    var index = tfPosition
    while index > 0, pdfIsAsciiWhitespaceByte(content[index - 1]) { index -= 1 }
    while index > 0,
        (content[index - 1] >= 0x30 && content[index - 1] <= 0x39)
            || content[index - 1] == UInt8(ascii: ".") || content[index - 1] == UInt8(ascii: "-")
    {
        index -= 1
    }
    while index > 0, pdfIsAsciiWhitespaceByte(content[index - 1]) { index -= 1 }

    let nameEnd = index
    while index > 0, content[index - 1] != UInt8(ascii: "/") {
        if pdfIsAsciiWhitespaceByte(content[index - 1]) || content[index - 1] == UInt8(ascii: "(")
            || content[index - 1] == UInt8(ascii: ")")
        {
            return nil
        }
        index -= 1
    }
    if index == 0 || content[index - 1] != UInt8(ascii: "/") { return nil }
    return index < nameEnd ? Array(content[index..<nameEnd]) : nil
}

/// Collect the distinct bytes of the string operand before a `Tj`/`TJ`.
///
/// Three operand shapes are handled: a literal `(…)`, a hex `<…>`, and a
/// `[…]` array holding any number of both. White space is never collected,
/// and a hex pair decoding to nul, space, tab or newline is dropped as well
/// — a distinction the literal branch does not make.
func pdfCollectTextCharactersBefore(
    _ content: [UInt8], at operatorPosition: Int, into uniqueCharacters: inout Set<UInt8>
) {
    var index = operatorPosition
    while index > 0 {
        index -= 1
        if !pdfIsAsciiWhitespaceByte(content[index]) { break }
    }
    if index == 0 { return }

    /// Hex digits between two positions, decoded in pairs.
    func collectHex(from start: Int, to end: Int) {
        let clean = content[start..<end].filter { !pdfIsAsciiWhitespaceByte($0) }
        var pair = 0
        while pair + 1 < clean.count {
            if let high = pdfHexValue(clean[pair]), let low = pdfHexValue(clean[pair + 1]) {
                let byte = (high << 4) | low
                if byte != 0, byte != 0x20, byte != 0x09, byte != 0x0A {
                    uniqueCharacters.insert(byte)
                }
            }
            pair += 2
        }
    }

    let closing = content[index]
    if closing == UInt8(ascii: ")") {
        // Nested parentheses count, and a backslash before either escapes
        // it. Note the reference tests only the immediately preceding byte,
        // so `\\)` — an escaped backslash then a close — reads as escaped.
        var depth = 1
        var scan = index
        while scan > 0 && depth > 0 {
            scan -= 1
            if content[scan] == UInt8(ascii: ")"),
                scan == 0 || content[scan - 1] != UInt8(ascii: "\\")
            {
                depth += 1
            } else if content[scan] == UInt8(ascii: "("),
                scan == 0 || content[scan - 1] != UInt8(ascii: "\\")
            {
                depth -= 1
            }
        }
        if depth == 0, scan + 1 < index {
            for character in content[(scan + 1)..<index]
            where !pdfIsAsciiWhitespaceByte(character) {
                uniqueCharacters.insert(character)
            }
        }
    } else if closing == UInt8(ascii: ">") {
        var scan = index
        while scan > 0 {
            scan -= 1
            if content[scan] == UInt8(ascii: "<") { break }
        }
        if content[scan] == UInt8(ascii: "<"), scan + 1 < index {
            collectHex(from: scan + 1, to: index)
        }
    } else if closing == UInt8(ascii: "]") {
        var scan = index
        while scan > 0 {
            scan -= 1
            if content[scan] == UInt8(ascii: "[") { break }
        }
        guard content[scan] == UInt8(ascii: "[") else { return }
        // Forward through the array, taking every string it holds.
        var position = scan + 1
        while position < index {
            if content[position] == UInt8(ascii: "(") {
                let start = position + 1
                var depth = 1
                position += 1
                while position < index && depth > 0 {
                    if content[position] == UInt8(ascii: ")"),
                        content[position - 1] != UInt8(ascii: "\\")
                    {
                        depth -= 1
                    } else if content[position] == UInt8(ascii: "("),
                        content[position - 1] != UInt8(ascii: "\\")
                    {
                        depth += 1
                    }
                    if depth > 0 { position += 1 }
                }
                for character in content[start..<position]
                where !pdfIsAsciiWhitespaceByte(character) {
                    uniqueCharacters.insert(character)
                }
            } else if content[position] == UInt8(ascii: "<") {
                let hexStart = position + 1
                position += 1
                while position < index, content[position] != UInt8(ascii: ">") { position += 1 }
                collectHex(from: hexStart, to: position)
            }
            position += 1
        }
    }
}
