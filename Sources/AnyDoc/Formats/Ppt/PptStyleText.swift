/// `StyleTextPropAtom` and `TxMasterStyleAtom` parsing: paragraph and
/// character formatting runs keyed by text range, per MS-PPT's
/// TextPFException / TextCFException layouts. Parsing is defensive — a
/// malformed exception aborts styling for that atom (logged), never the text.

struct PptParaProps {
    var count: Int = 0
    var depth: UInt16 = 0
    /// From bulletFlags' fHasBullet, when present.
    var bullet: Bool?
}

/// Character-run exception: each property is tri-state — `nil` inherits the
/// master's per-level default.
struct PptCharProps {
    var count: Int = 0
    var bold: Bool?
    var italic: Bool?
}

/// One indent level's defaults from a `TxMasterStyleAtom`, tri-state.
struct PptMasterLevel {
    var bullet: Bool?
    var bold: Bool?
    var italic: Bool?
}

struct PptStyleRuns {
    var paragraphs: [PptParaProps] = []
    var chars: [PptCharProps] = []
}

// Bounds-checked little-endian reads over a record body.

func sliceU16(_ b: ArraySlice<UInt8>, _ off: Int) -> UInt16? {
    guard off >= 0, b.count - off >= 2 else { return nil }
    let i = b.startIndex + off
    return UInt16(b[i]) | UInt16(b[i + 1]) << 8
}

func sliceU32(_ b: ArraySlice<UInt8>, _ off: Int) -> UInt32? {
    guard off >= 0, b.count - off >= 4 else { return nil }
    let i = b.startIndex + off
    return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
}

/// Parse a `StyleTextPropAtom` body for text of `textLen` UTF-16 units.
func parseStyleText(_ body: ArraySlice<UInt8>, textLen: Int) -> PptStyleRuns {
    var runs = PptStyleRuns()
    var pos = 0
    // Paragraph runs cover textLen + 1 (the implicit final paragraph mark).
    var covered = 0
    while covered <= textLen {
        guard let count = sliceU32(body, pos).map(Int.init), let depth = sliceU16(body, pos + 4)
        else { break }
        pos += 6
        guard let (bullet, next) = parsePfException(body, pos) else {
            Log.debug("unparseable paragraph style run; keeping styling parsed so far")
            return runs
        }
        pos = next
        runs.paragraphs.append(PptParaProps(count: count, depth: depth, bullet: bullet))
        covered += count
        if count == 0 { break }
    }
    covered = 0
    while covered <= textLen {
        guard let count = sliceU32(body, pos).map(Int.init) else { break }
        pos += 4
        guard let (cf, next) = parseCfException(body, pos) else {
            Log.debug("unparseable character style run; dropping remaining styling")
            break
        }
        pos = next
        runs.chars.append(PptCharProps(count: count, bold: cf.bold, italic: cf.italic))
        covered += count
        if count == 0 { break }
    }
    return runs
}

/// TextPFException: mask + fields in mask-bit order. Returns the bullet
/// state (if the mask carried bulletFlags) and the next offset.
private func parsePfException(_ body: ArraySlice<UInt8>, _ start: Int) -> (Bool?, Int)? {
    guard let mask = sliceU32(body, start) else { return nil }
    var pos = start + 4
    var bullet: Bool?
    // masks.bulletFlags: any of hasBullet/bulletHasFont/bulletHasColor/
    // bulletHasSize present -> a 16-bit bulletFlags field. The fHasBullet
    // value is specified only when masks.hasBullet itself is set.
    if mask & 0x000F != 0 {
        guard let flags = sliceU16(body, pos) else { return nil }
        if mask & 0x0001 != 0 {
            bullet = flags & 0x0001 != 0
        }
        pos += 2
    }
    if mask & 0x0080 != 0 { pos += 2 }  // bulletChar
    if mask & 0x0010 != 0 { pos += 2 }  // bulletFontRef
    if mask & 0x0040 != 0 { pos += 2 }  // bulletSize
    if mask & 0x0020 != 0 { pos += 4 }  // bulletColor
    if mask & 0x0800 != 0 { pos += 2 }  // textAlignment
    if mask & 0x1000 != 0 { pos += 2 }  // lineSpacing
    if mask & 0x2000 != 0 { pos += 2 }  // spaceBefore
    if mask & 0x4000 != 0 { pos += 2 }  // spaceAfter
    if mask & 0x0100 != 0 { pos += 2 }  // leftMargin
    if mask & 0x0400 != 0 { pos += 2 }  // indent
    if mask & 0x8000 != 0 { pos += 2 }  // defaultTabSize
    if mask & 0x0010_0000 != 0 {
        // tabStops: count-prefixed array of 4-byte stops.
        guard let count = sliceU16(body, pos).map(Int.init) else { return nil }
        pos += 2 + count * 4
    }
    if mask & 0x0001_0000 != 0 { pos += 2 }  // fontAlign
    // charWrap/wordWrap/overflow share one wrapFlags field.
    if mask & 0x000E_0000 != 0 { pos += 2 }
    if mask & 0x0020_0000 != 0 { pos += 2 }  // textDirection
    if pos > body.count { return nil }
    return (bullet, pos)
}

/// Tri-state character style bits from a TextCFException.
private struct PptCfStyle {
    var bold: Bool?
    var italic: Bool?
}

/// TextCFException: mask (+ optional style bitfield) + sized fields. Each
/// style bit is specified only when its own mask bit is set (per-bit
/// tri-state); strike-through is not in the 97-2003 style bits.
private func parseCfException(_ body: ArraySlice<UInt8>, _ start: Int) -> (PptCfStyle, Int)? {
    guard let mask = sliceU32(body, start) else { return nil }
    var pos = start + 4
    var bold: Bool?
    var italic: Bool?
    if mask & 0xFFFF != 0 {
        guard let style = sliceU16(body, pos) else { return nil }
        if mask & 0x0001 != 0 { bold = style & 0x0001 != 0 }
        if mask & 0x0002 != 0 { italic = style & 0x0002 != 0 }
        pos += 2
    }
    if mask & 0x0001_0000 != 0 { pos += 2 }  // fontRef
    if mask & 0x0020_0000 != 0 { pos += 2 }  // oldEAFontRef
    if mask & 0x0040_0000 != 0 { pos += 2 }  // ansiFontRef
    if mask & 0x0080_0000 != 0 { pos += 2 }  // symbolFontRef
    if mask & 0x0002_0000 != 0 { pos += 2 }  // size
    if mask & 0x0004_0000 != 0 { pos += 4 }  // color
    if mask & 0x0008_0000 != 0 { pos += 2 }  // position
    if pos > body.count { return nil }
    return (PptCfStyle(bold: bold, italic: italic), pos)
}

/// A `TxMasterStyleAtom`: per-indent-level tri-state defaults (index = depth).
func parseMasterStyle(_ body: ArraySlice<UInt8>, instance: UInt16) -> [PptMasterLevel] {
    guard let levels = sliceU16(body, 0).map(Int.init) else { return [] }
    var pos = 2
    var out: [PptMasterLevel] = []
    for _ in 0..<min(levels, 10) {
        // Levels for body-family text types carry a leading depth field in
        // format version >= 9 atoms; instances >= 5 always do.
        if instance >= 5 { pos += 2 }
        guard let (bullet, afterPf) = parsePfException(body, pos) else { break }
        pos = afterPf
        guard let (cf, afterCf) = parseCfException(body, pos) else { break }
        pos = afterCf
        out.append(PptMasterLevel(bullet: bullet, bold: cf.bold, italic: cf.italic))
    }
    return out
}
