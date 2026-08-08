/// Glyph metrics (ISO 32000-1 §9.7-9.8), ported from pdf-inspector's
/// `fonts.rs`.
///
/// Widths are what turn a shown string into a distance: without them a
/// run's advance is unknown, so every position after the first in a text
/// object is a guess. Simple fonts carry `/Widths` indexed from
/// `/FirstChar`; composite (Type0/CID) fonts carry a `/W` array of runs with
/// a `/DW` default.

struct PdfFontWidths {
    /// Width in font units, by character code (or CID).
    var widths: [UInt16: UInt16] = [:]
    /// Width for codes absent from the table. Only composite fonts define
    /// one; a simple font's missing glyph is zero-width.
    var defaultWidth: UInt16 = 0
    /// The space glyph's width, used to decide when a positioning gap is
    /// wide enough to be a word break.
    var spaceWidth: UInt16 = 250
    /// Composite fonts address glyphs with two-byte codes.
    var isCid = false
    /// Font units to text space. 1/1000 for everything but Type 3, which
    /// declares its own grid through `/FontMatrix`.
    var unitsScale: Float = 0.001
    /// 0 horizontal, 1 vertical.
    var writingMode: UInt8 = 0

    /// The width of one code in font units.
    func width(of code: UInt16) -> UInt16 {
        widths[code] ?? defaultWidth
    }
}

/// Read a font dictionary's metrics, dispatching on `/Subtype`.
func pdfParseFontWidths(_ document: inout PdfDocument, _ font: PdfDictionary) -> PdfFontWidths? {
    guard let subtype = font["Subtype"]?.asName else { return nil }
    switch String(decoding: subtype, as: UTF8.self) {
    case "Type0":
        return parseCompositeFontWidths(&document, font)
    case "Type1", "TrueType", "MMType1", "Type3":
        return parseSimpleFontWidths(&document, font)
    default:
        return nil
    }
}

/// Simple fonts: `/Widths` is indexed from `/FirstChar` up to `/LastChar`.
private func parseSimpleFontWidths(_ document: inout PdfDocument, _ font: PdfDictionary)
    -> PdfFontWidths?
{
    guard let firstChar = document.value(font, "FirstChar")?.asInteger,
        let lastChar = document.value(font, "LastChar")?.asInteger,
        let widthsArray = document.value(font, "Widths")?.asArray
    else { return nil }

    var info = PdfFontWidths()
    var spaceWidth: UInt16 = 0
    for (index, entry) in widthsArray.enumerated() {
        let code = firstChar + Int64(index)
        if code > lastChar { break }
        guard code >= 0, code <= Int64(UInt16.max) else { continue }
        guard let value = document.resolve(entry).asNumber else { continue }
        // Widths are non-negative; a negative or absurd one is not a width.
        guard value >= 0, value <= Double(UInt16.max) else { continue }
        let width = UInt16(value)
        let codeValue = UInt16(code)
        if codeValue == 32 { spaceWidth = width }
        info.widths[codeValue] = width
    }

    // Type 3 fonts declare their own coordinate grid.
    if let matrix = document.value(font, "FontMatrix")?.asArray, let first = matrix.first,
        let scale = document.resolve(first).asNumber
    {
        info.unitsScale = Float(abs(scale))
    }

    if spaceWidth == 0 {
        // No space in the table: 250 is calibrated for the standard
        // 1000-unit grid, so a font on another grid estimates from its own
        // average glyph instead.
        if !info.widths.isEmpty, abs(info.unitsScale - 0.001) > 0.0005 {
            let sum = info.widths.values.reduce(0) { $0 + UInt32($1) }
            let average = Float(sum) / Float(info.widths.count)
            spaceWidth = UInt16(max(1, min(Float(UInt16.max), average * 0.45)))
        } else {
            spaceWidth = 250
        }
    }
    info.spaceWidth = spaceWidth
    info.defaultWidth = 0
    info.isCid = false
    return info
}

/// Composite fonts: the metrics live on the descendant CIDFont, as a `/W`
/// array of runs over a `/DW` default.
private func parseCompositeFontWidths(_ document: inout PdfDocument, _ font: PdfDictionary)
    -> PdfFontWidths?
{
    guard let descendants = document.value(font, "DescendantFonts")?.asArray,
        let first = descendants.first,
        let cidFont = document.resolve(first).asDictionary
    else { return nil }

    var info = PdfFontWidths()
    info.isCid = true
    info.unitsScale = 0.001
    let declaredDefault = document.value(cidFont, "DW")?.asNumber
    info.defaultWidth =
        declaredDefault.flatMap { $0 >= 0 && $0 <= Double(UInt16.max) ? UInt16($0) : nil } ?? 1000

    if let wArray = document.value(cidFont, "W")?.asArray {
        parseCidWidthArray(&document, wArray, into: &info.widths)
    }
    // CID 32 is the space in most CID fonts; 3 is the other common choice.
    info.spaceWidth =
        info.widths[32] ?? info.widths[3]
        ?? (info.defaultWidth > 0 ? info.defaultWidth / 4 : 250)
    if let mode = document.value(font, "WMode")?.asInteger, mode >= 0, mode <= 1 {
        info.writingMode = UInt8(mode)
    }
    return info
}

/// A `/W` array is a sequence of two shapes:
///   `c [w1 w2 ...]`   consecutive widths starting at CID `c`
///   `cFirst cLast w`  one width across a CID range
func parseCidWidthArray(
    _ document: inout PdfDocument, _ array: [PdfObject], into widths: inout [UInt16: UInt16]
) {
    var index = 0
    while index < array.count {
        guard let start = document.resolve(array[index]).asNumber else {
            index += 1
            continue
        }
        index += 1
        guard index < array.count else { break }
        let next = document.resolve(array[index])
        if let list = next.asArray {
            index += 1
            for (offset, entry) in list.enumerated() {
                let cid = start + Double(offset)
                guard cid >= 0, cid <= Double(UInt16.max),
                    let value = document.resolve(entry).asNumber,
                    value >= 0, value <= Double(UInt16.max)
                else { continue }
                widths[UInt16(cid)] = UInt16(value)
            }
            continue
        }
        // The range form needs a third number.
        guard let last = next.asNumber else {
            index += 1
            continue
        }
        index += 1
        guard index < array.count, let value = document.resolve(array[index]).asNumber else { break }
        index += 1
        guard start >= 0, last >= start, last <= Double(UInt16.max), value >= 0,
            value <= Double(UInt16.max)
        else { continue }
        // A range spanning the whole code space is a crafted file.
        let count = Int(last - start) + 1
        guard count <= 65_536 else { continue }
        for offset in 0..<count {
            widths[UInt16(start + Double(offset))] = UInt16(value)
        }
    }
}

/// The text-space width a shown string advances, including the character
/// and word spacing that apply per glyph.
func pdfStringWidth(
    _ bytes: [UInt8], _ font: PdfFontWidths, fontSize: Float, charSpacing: Float,
    wordSpacing: Float
) -> Float {
    var total: Float = 0
    var spaces = 0
    var glyphs = 0
    if font.isCid {
        var i = 0
        while i + 1 < bytes.count {
            let cid = UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
            total += Float(font.width(of: cid))
            if cid == 32 { spaces += 1 }
            glyphs += 1
            i += 2
        }
    } else {
        for byte in bytes {
            total += Float(font.width(of: UInt16(byte)))
            if byte == 0x20 { spaces += 1 }
            glyphs += 1
        }
    }
    return total * font.unitsScale * fontSize + Float(glyphs) * charSpacing
        + Float(spaces) * wordSpacing
}
