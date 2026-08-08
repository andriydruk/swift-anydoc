/// Full STSH (style sheet) parsing per MS-DOC: STD records with their
/// `istdBase` inheritance chains and UPX formatting payloads, resolved into
/// effective per-style character formatting and paragraph properties.

private let istdNil: UInt16 = 0x0FFF

struct ResolvedStyle {
    /// Effective character formatting of the chain.
    var chp = Style.plain
    /// Effective paragraph properties of the chain.
    var pap = PapDelta()
    /// Heading level for built-in `heading N` styles.
    var heading: UInt8?
    /// The block container the style's name designates.
    var block: BlockStyle?
}

struct DocStylesheet {
    private var resolved: [UInt16: ResolvedStyle] = [:]
    private let fallback = ResolvedStyle()

    init() {}

    init(_ resolved: [UInt16: ResolvedStyle]) {
        self.resolved = resolved
    }

    func get(_ istd: UInt16) -> ResolvedStyle {
        resolved[istd] ?? fallback
    }
}

private struct Std {
    var sti: UInt16
    var istdBase: UInt16
    /// The block container this style's name designates.
    var block: BlockStyle?
    /// Paragraph style: the papx grpprl including its leading istd.
    var upxPapx: [UInt8]
    var upxChpx: [UInt8]
    var isParagraph: Bool
}

func parseDocStylesheet(_ wordDoc: [UInt8], _ table: [UInt8]) -> DocStylesheet {
    guard let fc = getU32(wordDoc, 0xA2).map(Int.init),
        let lcb = getU32(wordDoc, 0xA6).map(Int.init),
        fc <= table.count, fc + lcb <= table.count
    else { return DocStylesheet() }
    let stsh = table[fc..<(fc + lcb)]
    guard let cbStshi = sliceU16(stsh, 0), let cstd = sliceU16(stsh, 2),
        let cbStdBase = sliceU16(stsh, 4)
    else { return DocStylesheet() }

    var stds: [UInt16: Std] = [:]
    var pos = 2 + Int(cbStshi)
    for istd in 0..<cstd {
        guard let cbStd = sliceU16(stsh, pos) else { break }
        pos += 2
        if cbStd == 0 { continue }
        guard pos + Int(cbStd) <= stsh.count else { break }
        let record = stsh[(stsh.startIndex + pos)..<(stsh.startIndex + pos + Int(cbStd))]
        pos += Int(cbStd)
        if let std = parseStd(record, Int(cbStdBase)) {
            stds[istd] = std
        }
    }

    var memo: [UInt16: ResolvedStyle] = [:]
    var out: [UInt16: ResolvedStyle] = [:]
    for istd in stds.keys.sorted() {
        out[istd] = resolveStyle(istd, stds, &memo)
    }
    return DocStylesheet(out)
}

private func parseStd(_ record: ArraySlice<UInt8>, _ cbStdBase: Int) -> Std? {
    guard let first = sliceU16(record, 0), let second = sliceU16(record, 2) else { return nil }
    let sti = first & 0x0FFF
    let sgc = second & 0x000F  // 1 = paragraph, 2 = character
    let istdBase = (second >> 4) & 0x0FFF
    let cupx = (sliceU16(record, 4) ?? 0) & 0x000F

    // The name (Xstz) follows the fixed STDF area; UPX payloads follow the
    // name, each 2-byte aligned relative to the record start.
    let nameOff = max(cbStdBase, 10)
    guard let nameLen = sliceU16(record, nameOff).map(Int.init) else { return nil }
    let nameBytes = nameLen * 2
    var nameUnits: [UInt16] = []
    if nameOff + 2 + nameBytes <= record.count {
        let start = record.startIndex + nameOff + 2
        var i = start
        while i + 1 < start + nameBytes {
            nameUnits.append(UInt16(record[i]) | (UInt16(record[i + 1]) << 8))
            i += 2
        }
    }
    let name = decodeUtf16Units(nameUnits)
    var upxPos = nameOff + 4 + nameBytes

    var upx: [[UInt8]] = []
    for _ in 0..<cupx {
        if upxPos % 2 == 1 { upxPos += 1 }
        guard let cb = sliceU16(record, upxPos).map(Int.init),
            upxPos + 2 + cb <= record.count
        else { return nil }
        let start = record.startIndex + upxPos + 2
        upx.append(Array(record[start..<(start + cb)]))
        upxPos += 2 + cb
    }

    let isParagraph = sgc == 1
    let upxPapx = isParagraph ? (upx.first ?? []) : []
    let upxChpx = isParagraph ? (upx.count > 1 ? upx[1] : []) : (upx.first ?? [])
    return Std(
        sti: sti, istdBase: istdBase, block: blockStyleFromName(name), upxPapx: upxPapx,
        upxChpx: upxChpx, isParagraph: isParagraph)
}

/// Resolve one style's `istdBase` chain, memoized across styles. Cycles
/// (self-referencing bases exist in corrupt files) are cut by a visited set
/// and resolve from their acyclic prefix; valid chains of any depth resolve
/// fully.
private func resolveStyle(
    _ istd: UInt16, _ stds: [UInt16: Std], _ memo: inout [UInt16: ResolvedStyle]
) -> ResolvedStyle {
    if let hit = memo[istd] { return hit }
    // Walk root-ward collecting the unresolved suffix of the chain.
    var chain: [UInt16] = []
    var visiting: Set<UInt16> = []
    var base = ResolvedStyle()
    var cursor: UInt16? = istd
    while let cur = cursor {
        if let hit = memo[cur] {
            base = hit
            break
        }
        if !visiting.insert(cur).inserted {
            Log.warn("style istdBase cycle at istd \(cur)")
            break
        }
        guard let std = stds[cur] else { break }
        chain.append(cur)
        cursor = (std.istdBase != istdNil && std.istdBase != cur) ? std.istdBase : nil
    }
    // Apply the chain root-to-leaf over the resolved base.
    for cur in chain.reversed() {
        guard let std = stds[cur] else { continue }
        if std.isParagraph && std.upxPapx.count >= 2 {
            // The paragraph UPX starts with the style's own istd.
            var delta = PapDelta()
            applyPapSprms(std.upxPapx[2...], [], &delta)
            base.pap = base.pap.merge(delta)
        }
        base.chp = applyStyleChpx(std.upxChpx[...], base.chp)
        if std.sti >= 1 && std.sti <= 9 {
            base.heading = UInt8(std.sti)
        }
        base.block = std.block ?? base.block
        memo[cur] = base
    }
    return base
}

/// UTF-16 code units to a string, replacing unpaired surrogates — Rust's
/// `String::from_utf16_lossy`.
func decodeUtf16Units(_ units: [UInt16]) -> String {
    var out = String.UnicodeScalarView()
    var i = 0
    while i < units.count {
        let unit = units[i]
        if unit < 0xD800 || unit > 0xDFFF {
            out.append(Unicode.Scalar(unit)!)
            i += 1
        } else if unit >= 0xDC00 {
            out.append("\u{FFFD}")
            i += 1
        } else if i + 1 < units.count, (0xDC00...0xDFFF).contains(units[i + 1]) {
            let value = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(units[i + 1] - 0xDC00)
            out.append(Unicode.Scalar(value)!)
            i += 2
        } else {
            out.append("\u{FFFD}")
            i += 1
        }
    }
    return String(out)
}
