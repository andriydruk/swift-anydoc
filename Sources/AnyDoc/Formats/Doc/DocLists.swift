/// Word binary list tables: `PlfLst` (list definitions with per-level
/// formats) and `PlfLfo` (list format overrides referenced by `sprmPIlfo`),
/// resolved per MS-DOC: each list keeps its identity (`lsid`) so numbering
/// state is shared by every LFO referencing the same list, levels keep their
/// restart limits (`fNoRestart`/`ilvlRestartLim`), LFOLVL start-at overrides
/// apply when their LFO is first used, and the number text (`xst` with
/// `rgbxchNums` placeholders) is preserved for composite markers.

let docListLevels = 9

struct DocLevelDef {
    var marker: MarkerKind? = .bullet
    var start: UInt64 = 1
    /// Restart rule, as in WordprocessingML `lvlRestart`: `nil` = restart
    /// after any more significant level (`fNoRestart` clear), `0` = never
    /// restart, `n` = restart when a level with ilvl < n is used
    /// (`fNoRestart` set with `ilvlRestartLim`).
    var restart: UInt32?
    /// The level's number text (`xst` with `rgbxchNums` placeholders and
    /// LVLF `fLegal`); empty for bullets and malformed levels.
    var pattern = NumberPattern()
}

struct DocListDef {
    /// List identity: numbering state is keyed by this, not the ilfo, so
    /// every override referencing the same list continues its sequence.
    var lsid: UInt32
    var levels: [DocLevelDef]
    /// LFOLVL start-at overrides; each restarts the shared sequence at its
    /// value when this LFO is first used at that level.
    var startOverride: [UInt64?]

    /// Fallback definition for an ilfo with no parsed list behind it; the
    /// synthetic identity keeps it distinct from every real `lsid`.
    static func unknown(_ ilfo: UInt16) -> DocListDef {
        DocListDef(
            lsid: UInt32.max ^ UInt32(ilfo),
            levels: Array(repeating: DocLevelDef(), count: docListLevels),
            startOverride: Array(repeating: nil, count: docListLevels))
    }
}

struct DocLists {
    /// 1-based ilfo -> resolved definition.
    private var byIlfo: [UInt16: DocListDef] = [:]

    init() {}

    init(_ byIlfo: [UInt16: DocListDef]) {
        self.byIlfo = byIlfo
    }

    func get(_ ilfo: UInt16) -> DocListDef? {
        byIlfo[ilfo]
    }
}

/// FIB offsets (Word 97+): fcPlfLst/lcbPlfLst at 0x2E2, fcPlfLfo at 0x2EA.
func parseDocLists(_ wordDoc: [UInt8], _ table: [UInt8]) -> DocLists {
    let lstFc = Int(getU32(wordDoc, 0x2E2) ?? 0)
    let lstLcb = Int(getU32(wordDoc, 0x2E6) ?? 0)
    let lfoFc = Int(getU32(wordDoc, 0x2EA) ?? 0)
    let lfoLcb = Int(getU32(wordDoc, 0x2EE) ?? 0)

    if lstLcb == 0 { return DocLists() }
    // lcbPlfLst covers only the LSTF array; each list's LVL structures
    // follow it in the table stream, uncounted.
    let byLsid = parsePlfLst(table, lstFc, lstLcb)
    guard lfoFc <= table.count, lfoFc + lfoLcb <= table.count else { return DocLists() }
    return parsePlfLfo(table[lfoFc..<(lfoFc + lfoLcb)], byLsid)
}

private let lstfSize = 28

private func parsePlfLst(_ table: [UInt8], _ fc: Int, _ lcb: Int) -> [UInt32: [DocLevelDef]] {
    var out: [UInt32: [DocLevelDef]] = [:]
    guard fc <= table.count else { return out }
    let plf = table[fc...]
    guard let count = sliceU16(plf, 0).map(Int.init) else { return out }
    var lstfs: [(lsid: UInt32, simple: Bool)] = []
    lstfs.reserveCapacity(count)
    var pos = 2
    for _ in 0..<count {
        guard pos + lstfSize <= plf.count, let lsid = sliceU32(plf, pos) else { return out }
        let simple = plf[plf.startIndex + pos + 26] & 0x01 != 0
        lstfs.append((lsid: lsid, simple: simple))
        pos += lstfSize
    }
    // The LVL array begins where lcbPlfLst ends, still relative to `plf`.
    pos = lcb
    for entry in lstfs {
        let nLevels = entry.simple ? 1 : docListLevels
        var levels = [DocLevelDef](repeating: DocLevelDef(), count: docListLevels)
        for slot in 0..<nLevels {
            guard let (def, next) = parseLvl(plf, pos) else { return out }
            levels[slot] = def
            pos = next
        }
        if entry.simple {
            // A simple list applies its single level everywhere.
            levels = [DocLevelDef](repeating: levels[0], count: docListLevels)
        }
        out[entry.lsid] = levels
    }
    return out
}

/// One LVL: an LVLF header, then PAPX and CHPX grpprls, then the number text.
private func parseLvl(_ plf: ArraySlice<UInt8>, _ pos: Int) -> (DocLevelDef, Int)? {
    let lvlfSize = 28
    guard pos >= 0, pos <= plf.count else { return nil }
    let record = plf.dropFirst(pos)
    guard record.count >= lvlfSize else { return nil }
    let base = record.startIndex
    guard let start = sliceU32(record, 0).map(UInt64.init) else { return nil }
    let nfc = record[base + 4]
    let flags = record[base + 5]
    let legal = flags & 0x04 != 0
    let noRestart = flags & 0x08 != 0
    // rgbxchNums: one-based offsets of number placeholders within xst,
    // zero-terminated unless full.
    var placeholderOffsets: [UInt8] = []
    for i in 6..<15 {
        let byte = record[base + i]
        if byte == 0 { break }
        placeholderOffsets.append(byte)
    }
    let restartLim = record[base + 26]
    let cbPapx = Int(record[base + 25])
    let cbChpx = Int(record[base + 24])
    var next = lvlfSize + cbPapx + cbChpx
    guard let xchCount = sliceU16(record, next).map(Int.init) else { return nil }
    next += 2
    let marker = markerForNfc(nfc)
    var text: [NumberText] = []
    if marker?.ordered == true {
        for i in 0..<xchCount {
            guard let ch = sliceU16(record, next + i * 2) else { return nil }
            if ch <= 0x08, placeholderOffsets.contains(UInt8(truncatingIfNeeded: i + 1)) {
                text.append(.level(UInt8(ch)))
            } else if let scalar = Unicode.Scalar(UInt32(ch)),
                scalar.properties.generalCategory != .control
            {
                if case .literal(let s) = text.last {
                    text[text.count - 1] = .literal(s + String(scalar))
                } else {
                    text.append(.literal(String(scalar)))
                }
            }
        }
    }
    next += xchCount * 2
    return (
        DocLevelDef(
            marker: marker, start: start, restart: noRestart ? UInt32(restartLim) : nil,
            pattern: NumberPattern(text: text, legal: legal)),
        pos + next
    )
}

private let lfoSize = 16

private func parsePlfLfo(_ plf: ArraySlice<UInt8>, _ byLsid: [UInt32: [DocLevelDef]]) -> DocLists {
    var out: [UInt16: DocListDef] = [:]
    guard let count = sliceU32(plf, 0).map(Int.init) else { return DocLists() }
    var lfos: [(lsid: UInt32, clfolvl: Int)] = []
    lfos.reserveCapacity(count)
    var pos = 4
    for _ in 0..<count {
        guard pos + lfoSize <= plf.count, let lsid = sliceU32(plf, pos) else {
            return DocLists(out)
        }
        lfos.append((lsid: lsid, clfolvl: Int(plf[plf.startIndex + pos + 12])))
        pos += lfoSize
    }
    for (i, lfo) in lfos.enumerated() {
        let ilfo = UInt16(truncatingIfNeeded: i + 1)
        var def: DocListDef
        if let levels = byLsid[lfo.lsid] {
            def = DocListDef(
                lsid: lfo.lsid, levels: levels,
                startOverride: Array(repeating: nil, count: docListLevels))
        } else {
            def = DocListDef.unknown(ilfo)
        }
        for _ in 0..<lfo.clfolvl {
            guard pos + 8 <= plf.count, let startAt = sliceU32(plf, pos) else { break }
            let bits = plf[plf.startIndex + pos + 4]
            let ilvl = Int(bits & 0x0F)
            let fStartAt = bits & 0x10 != 0
            let fFormatting = bits & 0x20 != 0
            pos += 8
            if fFormatting {
                // The override embeds a full LVL; its own start wins.
                guard let (lvlDef, next) = parseLvl(plf, pos) else { break }
                if ilvl < docListLevels {
                    if fStartAt {
                        def.startOverride[ilvl] = lvlDef.start
                    }
                    def.levels[ilvl] = lvlDef
                }
                pos = next
            } else if fStartAt, ilvl < docListLevels {
                def.levels[ilvl].start = UInt64(startAt)
                def.startOverride[ilvl] = UInt64(startAt)
            }
        }
        out[ilfo] = def
    }
    return DocLists(out)
}

/// MS-OSHARED numbering format codes.
private func markerForNfc(_ nfc: UInt8) -> MarkerKind? {
    switch nfc {
    case 0: return .decimal
    case 1: return .upperRoman
    case 2: return .lowerRoman
    case 3: return .upperAlpha
    case 4: return .lowerAlpha
    case 23: return .bullet
    case 0xFF: return nil
    default: return .decimal
    }
}
