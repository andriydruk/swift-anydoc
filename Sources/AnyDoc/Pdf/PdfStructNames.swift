/// Repair for malformed structure-element names, ported from
/// `fix_bare_struct_names` in pdf-inspector's `structure_tree.rs`, together
/// with `sort_line_items` from `text_utils.rs`.
///
/// Some generators — fpdf2 notably — write `/S Code` where the PDF grammar
/// requires `/S /Code`. A bare token makes the whole dictionary unparseable,
/// so the structure element is silently dropped and a tagged PDF quietly loses
/// its tagging. This patches the bytes before parsing.

/// The structure types that may appear as a bare token.
///
/// Only real structure types are repaired: patching any bare word after `/S`
/// would corrupt dictionaries where `S` means something else entirely.
///
/// The order matters less than it appears. `H` precedes `H1`, but a bare `H1`
/// does not match `H` — the delimiter check sees the `1` and rejects it, so
/// the longer name is reached. The same saves `L` against `LI` and `LBody`.
private let pdfKnownStructNames: [[UInt8]] = [
    "Document", "Part", "Art", "Sect", "Div", "BlockQuote", "Caption", "TOC", "TOCI",
    "Index", "NonStruct", "Private", "H", "H1", "H2", "H3", "H4", "H5", "H6", "P", "L",
    "LI", "Lbl", "LBody", "Table", "TR", "TH", "TD", "THead", "TBody", "TFoot", "Span",
    "Quote", "Note", "Reference", "BibEntry", "Code", "Link", "Annot", "Figure",
    "Formula", "Form", "Ruby", "RB", "RT", "RP", "Warichu", "WT", "WP",
].map { Array($0.utf8) }

/// Prepend the missing `/` to bare structure names, or return the input
/// unchanged.
///
/// Nothing is copied unless a repair is needed, and the output buffer's own
/// length doubles as the cursor for how much of the input has been consumed.
///
/// **That cursor is the reference's bug, and it is reproduced here.** Each
/// repair writes one more byte than it reads — the inserted `/` — so the
/// cursor runs one byte ahead of the input from then on, and *the byte
/// immediately after every repaired name is deleted*:
///
///     /S Code>          →  /S /Code          (the `>` is gone)
///     /S Code\nNEXT     →  /S /CodeNEXT      (the newline is gone)
///     /S Code /S Table  →  /S /Code/S /Table (the space is gone)
///
/// Verified against the reference binary directly, not inferred. It usually
/// goes unnoticed because the deleted byte is the whitespace that terminated
/// the bare name, which the lexer does not miss — but when the terminator is
/// `>` or `/` it corrupts the very dictionary the function set out to repair.
/// Reproduced deliberately: a port that silently fixed it would disagree with
/// the reference on exactly the malformed files this exists for.
func pdfFixBareStructNames(_ buffer: [UInt8]) -> [UInt8] {
    let root = Array("/StructTreeRoot".utf8)
    guard pdfFindBytes(buffer, root) != nil else { return buffer }

    let pattern = Array("/S ".utf8)
    var result: [UInt8]?
    var position = 0

    // Strictly less than, as the reference has it: a `/S ` ending the buffer
    // has nothing after it to repair anyway.
    while position + pattern.count < buffer.count {
        guard let index = pdfFindBytes(buffer, pattern, from: position) else { break }
        let after = index + pattern.count

        // Already a proper name.
        if after < buffer.count && buffer[after] == UInt8(ascii: "/") {
            position = after
            continue
        }

        var matched = false
        for name in pdfKnownStructNames {
            let end = after + name.count
            guard end <= buffer.count, Array(buffer[after..<end]) == name else { continue }
            // The name must end at a delimiter, or `H` would swallow the `H`
            // of `H1`.
            let endsCleanly =
                end >= buffer.count
                || buffer[end] == UInt8(ascii: "\n") || buffer[end] == UInt8(ascii: "\r")
                || buffer[end] == UInt8(ascii: " ") || buffer[end] == UInt8(ascii: "/")
                || buffer[end] == UInt8(ascii: ">")
            guard endsCleanly else { continue }

            if result == nil { result = Array(buffer[0..<after]) }
            if result!.count < after {
                result!.append(contentsOf: buffer[result!.count..<after])
            }
            result!.append(UInt8(ascii: "/"))
            result!.append(contentsOf: name)
            position = end
            matched = true
            break
        }

        if !matched { position = after }
    }

    guard var out = result else { return buffer }
    if out.count < buffer.count { out.append(contentsOf: buffer[out.count...]) }
    return out
}

/// Order a line's items for reading.
///
/// Left to right normally, right to left when the line is right-to-left —
/// decided by counting the whole line rather than each item, so a Latin word
/// embedded in Arabic does not flip the line's direction.
///
/// Sorted stably, since the reference's sort is: two items at the same x keep
/// the order the extractor produced them in.
func pdfSortLineItems(_ items: inout [PdfLayoutItem]) {
    let rightToLeft = pdfIsRtlText(items.map(\.text))
    items =
        items.enumerated()
        .sorted {
            $0.element.x != $1.element.x
                ? (rightToLeft ? $0.element.x > $1.element.x : $0.element.x < $1.element.x)
                : $0.offset < $1.offset
        }
        .map(\.element)
}
