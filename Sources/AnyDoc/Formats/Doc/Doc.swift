/// Legacy Word 97-2003 binary (`.doc`), implementing the published
/// resolution algorithms: OLE2 container, FIB, piece table with `Prm`s,
/// CHPX/PAPX runs applied over the STSH style chains in specification order,
/// and the PlfLst/PlfLfo list tables. Character positions are counted in
/// UTF-16 units, matching the CP-indexed PLC structures.

func parseDoc(_ bytes: [UInt8]) throws -> Document {
    let ole: CompoundFile
    do {
        ole = try CompoundFile(bytes: bytes)
    } catch ConvertError.malformed(_, let detail) {
        // The container error is quoted verbatim: wrapping its rendered
        // message would repeat the "malformed document" prefix.
        throw ConvertError.malformed("not an OLE2 compound file: \(detail)")
    }

    let wordDoc = try readOleStream(ole, "WordDocument")
    guard getU16(wordDoc, 0) == 0xA5EC else {
        throw ConvertError.malformedPart("WordDocument", "invalid FIB magic")
    }
    let flags = getU16(wordDoc, 0x0A) ?? 0
    if flags & 0x0100 != 0 {
        throw ConvertError.encrypted
    }
    let tableName = flags & 0x0200 != 0 ? "1Table" : "0Table"
    let otherTable = flags & 0x0200 != 0 ? "0Table" : "1Table"
    let table =
        ((try? readOleStream(ole, tableName)) ?? (try? readOleStream(ole, otherTable))) ?? []

    let ccpText = Int(getU32(wordDoc, 0x4C) ?? 0)
    let ccpFtn = Int(getU32(wordDoc, 0x50) ?? 0)
    let ccpHdd = Int(getU32(wordDoc, 0x54) ?? 0)
    let ccpMcr = Int(getU32(wordDoc, 0x58) ?? 0)
    let ccpAtn = Int(getU32(wordDoc, 0x5C) ?? 0)
    let ccpEdn = Int(getU32(wordDoc, 0x60) ?? 0)
    let fcClx = Int(getU32(wordDoc, 0x1A2) ?? 0)
    let lcbClx = Int(getU32(wordDoc, 0x1A6) ?? 0)

    let pieces: [DocPiece]
    var prcs: [[UInt8]]
    if lcbClx > 0 {
        (pieces, prcs) = try parseClx(table, fcClx, lcbClx)
    } else {
        pieces = legacySinglePiece(wordDoc)
        prcs = []
    }
    let totalCp = ccpText + ccpFtn + ccpHdd + ccpMcr + ccpAtn + ccpEdn
    // Compressed (8-bit) piece text decodes in the document's ANSI code
    // page: FibBase.lid, or FibRgW97.lidFE when fFarEast is set.
    let lid: UInt16
    if flags & 0x4000 != 0 {
        lid = getU16(wordDoc, 0x3C).flatMap { $0 != 0 ? $0 : nil } ?? getU16(wordDoc, 0x06) ?? 0
    } else {
        lid = getU16(wordDoc, 0x06) ?? 0
    }
    let encoding = lidEncoding(lid)
    let text = extractText(wordDoc, pieces, totalCp, encoding)

    let data = (try? readOleStream(ole, "Data")) ?? []
    let chpxRuns = parseFkps(wordDoc, table, 0xFA, .chpx, data)
    let papxRuns = parseFkps(wordDoc, table, 0x102, .papx, data)
    let stylesheet = parseDocStylesheet(wordDoc, table)
    let listTables = parseDocLists(wordDoc, table)

    // Note references (CP-indexed) and note body ranges.
    var noteRefs: [Int: String] = [:]
    var noteRanges: [(lo: Int, hi: Int, id: String, kind: NoteKind)] = []
    let ftnBase = ccpText
    let ednBase = ccpText + ccpFtn + ccpHdd + ccpMcr + ccpAtn
    let noteTables:
        [(refOff: Int, txtOff: Int, base: Int, prefix: String, kind: NoteKind)] = [
            (0xAA, 0xB2, ftnBase, "fn", .footnote),
            (0x20A, 0x212, ednBase, "en", .endnote),
        ]
    for spec in noteTables {
        let (refCps, nRefs) = parsePlc(wordDoc, table, spec.refOff, 2)
        let (txtCps, _) = parsePlc(wordDoc, table, spec.txtOff, 0)
        for i in 0..<nRefs where i < refCps.count {
            noteRefs[text.indexOfCp(Int(refCps[i]))] = "\(spec.prefix)\(i)"
            if i + 1 < txtCps.count {
                let lo = text.indexOfCp(spec.base + Int(txtCps[i]))
                let hi = text.indexOfCp(spec.base + Int(txtCps[i + 1]))
                noteRanges.append((lo: lo, hi: hi, id: "\(spec.prefix)\(i)", kind: spec.kind))
            }
        }
    }
    let mainEnd = text.indexOfCp(ccpText)

    var assembler = DocAssembler(
        text: text, chpx: DocRuns(chpxRuns), papx: DocRuns(papxRuns), stylesheet: stylesheet,
        lists: listTables, prcs: prcs, pieceProps: pieces.map(\.prmPrc), noteRefs: noteRefs,
        data: data)
    let blocks = try assembler.buildBlocks(0, mainEnd)
    var notes: [Note] = []
    for range in noteRanges {
        let lo = min(range.lo, assembler.text.chars.count)
        let hi = min(range.hi, assembler.text.chars.count)
        if lo >= hi { continue }
        notes.append(
            Note(id: range.id, kind: range.kind, blocks: try assembler.buildBlocks(lo, hi)))
    }
    return Document(blocks: blocks, notes: notes, assets: assembler.assets.assets)
}

/// Read a PLC's CP array; `n` is the number of data elements.
private func parsePlc(
    _ wordDoc: [UInt8], _ table: [UInt8], _ fibOff: Int, _ dataSize: Int
) -> ([UInt32], Int) {
    let fc = Int(getU32(wordDoc, fibOff) ?? 0)
    let lcb = Int(getU32(wordDoc, fibOff + 4) ?? 0)
    guard lcb >= 8, fc <= table.count, fc + lcb <= table.count else { return ([], 0) }
    let plc = table[fc..<(fc + lcb)]
    let n = dataSize == 0 ? lcb / 4 - 1 : (lcb - 4) / (4 + dataSize)
    var cps: [UInt32] = []
    cps.reserveCapacity(n + 1)
    for i in 0...n {
        cps.append(sliceU32(plc, i * 4) ?? 0)
    }
    return (cps, n)
}

// MARK: - Piece table

private struct DocPiece {
    var cpStart: Int
    var cpEnd: Int
    var fc: Int
    var compressed: Bool
    /// Property modifier: an index into the Clx `Prc` array, when complex.
    var prmPrc: Int?
}

private func parseClx(_ table: [UInt8], _ fc: Int, _ lcb: Int) throws -> ([DocPiece], [[UInt8]]) {
    guard fc <= table.count, fc + lcb <= table.count else {
        throw ConvertError.malformed("Clx out of bounds")
    }
    let clx = table[fc..<(fc + lcb)]
    var prcs: [[UInt8]] = []
    var pos = 0
    while true {
        guard pos < clx.count else { throw ConvertError.malformed("malformed Clx") }
        let rest = clx.dropFirst(pos)
        switch rest.first {
        case 1:
            guard let cb = sliceU16(rest, 1).map(Int.init) else {
                throw ConvertError.malformed("bad Prc")
            }
            if 3 + cb <= rest.count {
                let start = rest.startIndex + 3
                prcs.append(Array(rest[start..<(start + cb)]))
            }
            pos += 3 + cb
        case 2:
            guard let lcbPlc = sliceU32(rest, 1).map(Int.init) else {
                throw ConvertError.malformed("bad Pcdt")
            }
            guard 5 + lcbPlc <= rest.count else {
                throw ConvertError.malformed("PlcPcd out of bounds")
            }
            let start = rest.startIndex + 5
            let pieces = try parsePlcPcd(rest[start..<(start + lcbPlc)], &prcs)
            return (pieces, prcs)
        default:
            throw ConvertError.malformed("malformed Clx")
        }
    }
}

private func parsePlcPcd(_ plc: ArraySlice<UInt8>, _ prcs: inout [[UInt8]]) throws -> [DocPiece] {
    guard plc.count >= 4 + 12 else { throw ConvertError.malformed("empty piece table") }
    let n = (plc.count - 4) / 12
    var pieces: [DocPiece] = []
    pieces.reserveCapacity(n)
    for i in 0..<n {
        guard let cpStart = sliceU32(plc, i * 4).map(Int.init),
            let cpEnd = sliceU32(plc, (i + 1) * 4).map(Int.init)
        else { throw ConvertError.malformed("bad cp") }
        let pcdOff = (n + 1) * 4 + i * 8
        guard let fcRaw = sliceU32(plc, pcdOff + 2) else {
            throw ConvertError.malformed("bad pcd")
        }
        let prm = sliceU16(plc, pcdOff + 6) ?? 0
        let compressed = fcRaw & 0x4000_0000 != 0
        var fc = Int(fcRaw & 0x3FFF_FFFF)
        if compressed { fc /= 2 }
        // Prm: the complex form points into the Prc array; the compressed
        // form (Prm0) carries one (isprm, val) pair that decodes to a
        // one-sprm grpprl.
        var prmPrc: Int?
        if prm & 1 != 0 {
            let idx = Int(prm >> 1)
            prmPrc = idx < prcs.count ? idx : nil
        } else if prm != 0 {
            if let grpprl = prm0Grpprl(prm) {
                prcs.append(grpprl)
                prmPrc = prcs.count - 1
            } else {
                Log.debug("Prm0 sprm outside the converted model: 0x\(hexU16(prm))")
            }
        }
        pieces.append(
            DocPiece(cpStart: cpStart, cpEnd: cpEnd, fc: fc, compressed: compressed, prmPrc: prmPrc))
    }
    return pieces
}

private func hexU16(_ value: UInt16) -> String {
    var text = String(value, radix: 16, uppercase: true)
    while text.count < 4 { text = "0" + text }
    return text
}

/// Decode a `Prm0` (compressed piece Prm): the 7-bit `isprm` selects a Sprm
/// per the MS-DOC Prm0 table, `val` is its one-byte operand. Only sprms
/// whose properties the converter models materialize; the rest have no
/// representable effect.
func prm0Grpprl(_ prm: UInt16) -> [UInt8]? {
    let isprm = (prm >> 1) & 0x7F
    let val = UInt8(truncatingIfNeeded: prm >> 8)
    let sprm: UInt16
    switch isprm {
    case 0x0C: sprm = 0x260A  // sprmPIlvl
    case 0x18: sprm = 0x2416  // sprmPFInTable
    case 0x19: sprm = 0x2417  // sprmPFTtp
    case 0x55: sprm = 0x0835  // sprmCFBold
    case 0x56: sprm = 0x0836  // sprmCFItalic
    case 0x57: sprm = 0x0837  // sprmCFStrike
    case 0x78: sprm = 0x2640  // sprmPOutLvl
    default: return nil
    }
    return [UInt8(truncatingIfNeeded: sprm), UInt8(truncatingIfNeeded: sprm >> 8), val]
}

private func legacySinglePiece(_ wordDoc: [UInt8]) -> [DocPiece] {
    let fcMin = Int(getU32(wordDoc, 0x18) ?? 0)
    let fcMac = Int(getU32(wordDoc, 0x1C) ?? 0)
    if fcMac <= fcMin { return [] }
    return [
        DocPiece(cpStart: 0, cpEnd: fcMac - fcMin, fc: fcMin, compressed: true, prmPrc: nil)
    ]
}

// MARK: - Text extraction (CPs count UTF-16 units, chars are decoded scalars)

struct TextStream {
    var chars: [Unicode.Scalar] = []
    var fcs: [UInt32] = []
    /// CP of each char (running UTF-16 unit count).
    var cps: [UInt32] = []
    /// Piece index of each char, for Prm application.
    var pieceOf: [UInt32] = []

    /// First char index at or after the given CP (`chars.count` when the CP
    /// is past the end).
    func indexOfCp(_ cp: Int) -> Int {
        partitionPoint(cps) { Int($0) < cp }
    }
}

/// A document code page and whether it is double-byte, which decides how
/// compressed-piece CPs are counted.
struct DocEncoding {
    var encoding: LegacyEncoding
    /// The nominal code page, kept even when the decoder is substituted, so
    /// character-position accounting stays right.
    var leadBytes: LeadByteRange

    enum LeadByteRange {
        case none
        case shiftJis
        case wide
    }
}

/// The ANSI code page for a Word language id (MS-LCID primary language;
/// Chinese needs the region to pick Simplified vs Traditional).
func lidEncoding(_ lid: UInt16) -> DocEncoding {
    switch lid & 0x03FF {
    case 0x11: return DocEncoding(encoding: .shiftJis, leadBytes: .shiftJis)  // 932
    case 0x12: return DocEncoding(encoding: codepageEncoding(949), leadBytes: .wide)
    case 0x04:
        // 950 for Traditional Chinese regions, 936 otherwise.
        let traditional = lid == 0x0404 || lid == 0x0C04 || lid == 0x1404 || lid == 0x7C04
        return DocEncoding(
            encoding: codepageEncoding(traditional ? 950 : 936), leadBytes: .wide)
    case 0x01, 0x20, 0x29:
        return DocEncoding(encoding: .windows1256, leadBytes: .none)  // Arabic script
    case 0x02, 0x19, 0x22, 0x23:
        return DocEncoding(encoding: .windows1251, leadBytes: .none)  // Cyrillic
    case 0x05, 0x0E, 0x15, 0x18, 0x1A, 0x1B, 0x24:
        return DocEncoding(encoding: .windows1250, leadBytes: .none)
    case 0x08: return DocEncoding(encoding: .windows1253, leadBytes: .none)  // Greek
    case 0x0D: return DocEncoding(encoding: .windows1255, leadBytes: .none)  // Hebrew
    case 0x1E: return DocEncoding(encoding: .windows874, leadBytes: .none)  // Thai
    case 0x1F, 0x2C: return DocEncoding(encoding: .windows1254, leadBytes: .none)  // Turkic
    case 0x25, 0x26, 0x27: return DocEncoding(encoding: .windows1257, leadBytes: .none)  // Baltic
    case 0x2A: return DocEncoding(encoding: .windows1258, leadBytes: .none)  // Vietnamese
    default: return DocEncoding(encoding: .windows1252, leadBytes: .none)
    }
}

/// Whether `b` starts a two-byte sequence in a double-byte code page.
private func isLeadByte(_ encoding: DocEncoding, _ b: UInt8) -> Bool {
    switch encoding.leadBytes {
    case .none: return false
    case .shiftJis: return (0x81...0x9F).contains(b) || (0xE0...0xFC).contains(b)
    case .wide: return (0x81...0xFE).contains(b)
    }
}

private func extractText(
    _ wordDoc: [UInt8], _ pieces: [DocPiece], _ totalCp: Int, _ encoding: DocEncoding
) -> TextStream {
    var text = TextStream()
    var cp = 0
    for (pieceIdx, piece) in pieces.enumerated() {
        if cp >= totalCp { break }
        let len = min(piece.cpEnd >= piece.cpStart ? piece.cpEnd - piece.cpStart : 0, totalCp - cp)
        if piece.compressed {
            guard piece.fc <= wordDoc.count, piece.fc + len <= wordDoc.count else { continue }
            let bytes = wordDoc[piece.fc..<(piece.fc + len)]
            // Byte-accurate accounting: in a compressed piece each CP is one
            // byte, so a double-byte character occupies two CPs and its FC is
            // the lead byte's.
            var i = 0
            while i < bytes.count {
                let base = bytes.startIndex
                let seq = isLeadByte(encoding, bytes[base + i]) && i + 1 < bytes.count ? 2 : 1
                let decoded = encoding.encoding.decode(Array(bytes[(base + i)..<(base + i + seq)]))
                for scalar in decoded.unicodeScalars {
                    text.chars.append(scalar)
                    text.fcs.append(UInt32(truncatingIfNeeded: piece.fc + i))
                    text.cps.append(UInt32(truncatingIfNeeded: cp))
                    text.pieceOf.append(UInt32(truncatingIfNeeded: pieceIdx))
                }
                cp += seq
                i += seq
            }
        } else {
            let byteLen = len * 2
            guard piece.fc <= wordDoc.count, piece.fc + byteLen <= wordDoc.count else { continue }
            var units: [UInt16] = []
            units.reserveCapacity(len)
            var i = piece.fc
            while i + 1 < piece.fc + byteLen {
                units.append(UInt16(wordDoc[i]) | (UInt16(wordDoc[i + 1]) << 8))
                i += 2
            }
            var unitIdx = 0
            for scalar in decodeUtf16Units(units).unicodeScalars {
                let width = scalar.value > 0xFFFF ? 2 : 1
                text.chars.append(scalar)
                text.fcs.append(UInt32(truncatingIfNeeded: piece.fc + unitIdx * 2))
                text.cps.append(UInt32(truncatingIfNeeded: cp))
                text.pieceOf.append(UInt32(truncatingIfNeeded: pieceIdx))
                unitIdx += width
                cp += width
            }
        }
    }
    return text
}

// MARK: - Formatting runs (CHPX / PAPX out of FKP pages)

private enum FkpKind {
    case chpx
    case papx
}

struct DocRunProps {
    /// Raw CHPX grpprl (application depends on the style base).
    var chpx: [UInt8] = []
    var istd: UInt16 = 0
    var pap = PapDelta()
}

struct DocRun {
    var fcStart: UInt32
    var fcEnd: UInt32
    var props: DocRunProps
}

struct DocRuns {
    private var runs: [DocRun]

    init(_ runs: [DocRun]) {
        self.runs = runs.sorted { $0.fcStart < $1.fcStart }
    }

    func lookup(_ fc: UInt32) -> DocRunProps? {
        let idx = partitionPoint(runs) { $0.fcStart <= fc }
        guard idx > 0 else { return nil }
        let run = runs[idx - 1]
        return fc < run.fcEnd ? run.props : nil
    }
}

private func parseFkps(
    _ wordDoc: [UInt8], _ table: [UInt8], _ fibOff: Int, _ kind: FkpKind, _ data: [UInt8]
) -> [DocRun] {
    var runs: [DocRun] = []
    let fc = Int(getU32(wordDoc, fibOff) ?? 0)
    let lcb = Int(getU32(wordDoc, fibOff + 4) ?? 0)
    guard fc <= table.count, fc + lcb <= table.count, lcb >= 8 else { return runs }
    let plc = table[fc..<(fc + lcb)]
    let n = (lcb - 4) / 8
    for i in 0..<n {
        guard let pnRaw = sliceU32(plc, (n + 1) * 4 + i * 4) else { continue }
        let pn = Int(pnRaw & 0x3F_FFFF)
        let pageOff = pn * 512
        guard pageOff >= 0, pageOff + 512 <= wordDoc.count else { continue }
        parseFkpPage(wordDoc[pageOff..<(pageOff + 512)], kind, data, &runs)
    }
    return runs
}

private func parseFkpPage(
    _ page: ArraySlice<UInt8>, _ kind: FkpKind, _ data: [UInt8], _ runs: inout [DocRun]
) {
    let base = page.startIndex
    let count = Int(page[base + 511])
    if count == 0 { return }
    let entrySize = kind == .papx ? 13 : 1
    for k in 0..<count {
        guard let fcStart = sliceU32(page, k * 4), let fcEnd = sliceU32(page, (k + 1) * 4) else {
            continue
        }
        let bOffsetPos = (count + 1) * 4 + k * entrySize
        guard bOffsetPos < page.count else { continue }
        let bOffset = Int(page[base + bOffsetPos])
        var props = DocRunProps()
        if bOffset != 0 {
            let off = bOffset * 2
            switch kind {
            case .chpx:
                if off < page.count {
                    let cb = Int(page[base + off])
                    if off + 1 + cb <= page.count {
                        props.chpx = Array(page[(base + off + 1)..<(base + off + 1 + cb)])
                    }
                }
            case .papx:
                if off < page.count {
                    let cb = Int(page[base + off])
                    let start: Int
                    let len: Int
                    if cb == 0 {
                        let cb2 = off + 1 < page.count ? Int(page[base + off + 1]) : 0
                        start = off + 2
                        len = cb2 * 2
                    } else {
                        start = off + 1
                        len = cb * 2 - 1
                    }
                    if start + len <= page.count, len >= 2 {
                        let grpprl = page[(base + start)..<(base + start + len)]
                        props.istd = sliceU16(grpprl, 0) ?? 0
                        applyPapSprms(grpprl.dropFirst(2), data, &props.pap)
                    }
                }
            }
        }
        runs.append(DocRun(fcStart: fcStart, fcEnd: fcEnd, props: props))
    }
}

// MARK: - Numbering counters (MS-DOC number sequence semantics)

struct DocCounters {
    /// Numbering state keyed by list identity (`lsid`): every LFO
    /// referencing the same list continues its sequence.
    private var values: [UInt32: [UInt64]] = [:]
    private var started: [UInt32: [Bool]] = [:]
    /// (ilfo, level) pairs whose first-use start-at override has fired.
    private var overridden: Set<UInt64> = []

    /// Advance the sequence for a paragraph numbered by (`ilfo`, `level`)
    /// and return its effective number plus, when the level's number text is
    /// not reproducible from the marker kind alone, the composite label.
    mutating func next(_ ilfo: UInt16, _ list: DocListDef, _ level: Int)
        -> (number: UInt64, label: String?)
    {
        let level = min(level, docListLevels - 1)
        let def = list.levels[level]
        let key = UInt64(ilfo) << 32 | UInt64(level)
        let firstUse = overridden.insert(key).inserted
        var vals = values[list.lsid] ?? Array(repeating: 0, count: docListLevels)
        var seen = started[list.lsid] ?? Array(repeating: false, count: docListLevels)
        let value: UInt64
        if let override = list.startOverride[level], firstUse {
            // An LFO start-at override restarts the shared sequence at its
            // value the first time that LFO numbers this level.
            value = override
        } else if seen[level] {
            value = vals[level].saturatingAdding(1)
        } else {
            value = def.start
        }
        vals[level] = value
        seen[level] = true
        // Using this level restarts deeper levels according to their own
        // restart rules (fNoRestart/ilvlRestartLim).
        for deeper in (level + 1)..<docListLevels {
            let triggered: Bool
            switch list.levels[deeper].restart {
            case nil: triggered = true
            case .some(let lim): triggered = UInt32(level) < lim
            }
            if triggered { seen[deeper] = false }
        }
        values[list.lsid] = vals
        started[list.lsid] = seen
        return (value, docCompositeLabel(list, vals, seen, level))
    }
}

/// Render a level's number text against the current sequence values; `nil`
/// when it matches the default label the renderer produces anyway.
private func docCompositeLabel(
    _ list: DocListDef, _ values: [UInt64], _ started: [Bool], _ level: Int
) -> String? {
    guard let marker = list.levels[level].marker else { return nil }
    return compositeLabel(
        list.levels[level].pattern,
        ownMarker: marker,
        ownValue: values[level],
        levelMarker: { list.levels[min($0, docListLevels - 1)].marker ?? .decimal },
        levelValue: {
            let l = min($0, docListLevels - 1)
            return started[l] ? values[l] : list.levels[l].start
        })
}

// MARK: - Assembly: text stream + formatting runs -> model

/// A paragraph's resolved properties: the style chain's contribution merged
/// with the PAPX and any piece `Prm`.
private struct EffectivePap {
    var istd: UInt16
    var effective: PapDelta
}

private struct ParaBuilder {
    var inlines: [Inline] = []
    var fields: [FieldFrame] = []
    var text = ""
    var style = Style.plain

    mutating func flushText() {
        if text.isEmpty { return }
        let inline = Inline.text(text, style: style)
        text = ""
        if let last = fields.last, !last.inResult {
            fields[fields.count - 1].instr += inlinesToPlainText([inline])
        } else if !fields.isEmpty {
            fields[fields.count - 1].inlines.append(inline)
        } else {
            inlines.append(inline)
        }
    }

    mutating func pushChar(_ scalar: Unicode.Scalar, _ newStyle: Style) {
        if newStyle != style {
            flushText()
            style = newStyle
        }
        text.unicodeScalars.append(scalar)
    }

    mutating func pushInline(_ inline: Inline) {
        flushText()
        if let last = fields.last, !last.inResult {
            return
        } else if !fields.isEmpty {
            fields[fields.count - 1].inlines.append(inline)
        } else {
            inlines.append(inline)
        }
    }

    mutating func fieldBegin() {
        flushText()
        fields.append(FieldFrame())
    }

    mutating func fieldSeparate() {
        flushText()
        if !fields.isEmpty { fields[fields.count - 1].inResult = true }
    }

    mutating func fieldEnd() {
        flushText()
        guard let frame = fields.popLast() else { return }
        for inline in fieldResult(frame.instr, frame.inlines) {
            if let last = fields.last, !last.inResult {
                continue
            } else if !fields.isEmpty {
                fields[fields.count - 1].inlines.append(inline)
            } else {
                inlines.append(inline)
            }
        }
    }

    mutating func finish() -> [Inline] {
        flushText()
        while !fields.isEmpty { fieldEnd() }
        return inlines
    }
}

/// One accumulated table row: cell contents plus the TAP from the row-end
/// mark (absent for rows without `sprmTDefTable`).
private struct DocTableRow {
    var cells: [[Block]]
    var tap: Tap?

    func intoGridRow() -> GridRow {
        let header = tap?.header ?? false
        let tap = self.tap ?? Tap()
        let cells = self.cells.enumerated().map { (k, blocks) -> ([Block], CellProp) in
            let tc = k < tap.cells.count ? tap.cells[k] : TapCell()
            // Without a TAP boundary, a synthetic index-based edge keeps the
            // flat column behavior.
            let right =
                k + 1 < tap.boundaries.count
                ? Int64(tap.boundaries[k + 1]) : Int64(k + 1) * 1000
            return (
                blocks,
                CellProp(
                    mergeFirst: tc.horzFirst, mergeCont: tc.horzCont,
                    vmergeFirst: tc.vertRestart, vmergeCont: tc.vertCont, right: right)
            )
        }
        return GridRow(cells: cells.map { (blocks: $0.0, prop: $0.1) }, header: header)
    }
}

struct DocAssembler {
    var text: TextStream
    var chpx: DocRuns
    var papx: DocRuns
    var stylesheet: DocStylesheet
    var lists: DocLists
    var prcs: [[UInt8]]
    var pieceProps: [Int?]
    var noteRefs: [Int: String]
    var counters = DocCounters()
    /// The Data stream, for `sprmCPicLocation` picture payloads.
    var data: [UInt8]
    var assets = AssetSink()

    mutating func buildBlocks(_ lo: Int, _ hi: Int) throws -> [Block] {
        var blocks: [Block] = []
        var listRun: [ListEntry] = []
        var styled = StyledRun()
        var cellBlocks: [Block] = []
        var cellStyled = StyledRun()
        var row: [[Block]] = []
        var tableRows: [DocTableRow] = []
        var para = ParaBuilder()

        var i = lo
        let end = min(hi, text.chars.count)
        while i < end {
            let c = text.chars[i]
            let fc = text.fcs[i]
            if let id = noteRefs[i] {
                para.pushInline(.noteRef(id))
                i += 1
                continue
            }
            switch c {
            case "\r", "\u{7}", "\u{c}", "\u{e}":
                let pap = effectivePap(fc, i)
                let inlines = para.finish()
                para = ParaBuilder()
                let isCellMark = c == "\u{7}"
                if pap.effective.inTable ?? false || isCellMark {
                    // A table is a hard boundary for top-level list and
                    // styled runs, even while its rows are accumulated.
                    styled.flush(&blocks)
                    flushList(&blocks, &listRun)
                    // Nested-table content (table depth > 1, inner cell/row
                    // terminators) flattens into the outer cell as paragraphs.
                    let inner =
                        (pap.effective.itap ?? 1) > 1 || (pap.effective.innerCell ?? false)
                        || (pap.effective.innerTtp ?? false)
                    if inner {
                        emitCellParagraph(pap, inlines, &cellBlocks, &cellStyled)
                    } else if isCellMark && (pap.effective.ttp ?? false) {
                        cellStyled.flush(&cellBlocks)
                        // Row end: the TTP mark's PAPX carries the TAP
                        // (boundaries, merge flags, header row).
                        if !row.isEmpty {
                            tableRows.append(DocTableRow(cells: row, tap: pap.effective.tap))
                            row = []
                        }
                    } else if isCellMark {
                        emitCellParagraph(pap, inlines, &cellBlocks, &cellStyled)
                        cellStyled.flush(&cellBlocks)
                        row.append(cellBlocks)
                        cellBlocks = []
                    } else {
                        emitCellParagraph(pap, inlines, &cellBlocks, &cellStyled)
                    }
                } else {
                    try Self.flushTable(&blocks, &tableRows, &row, &cellBlocks)
                    emitParagraph(pap, inlines, &blocks, &listRun, &styled)
                }
            case "\u{b}":
                para.pushInline(.lineBreak)
            case "\u{13}":
                para.fieldBegin()
            case "\u{14}":
                para.fieldSeparate()
            case "\u{15}":
                para.fieldEnd()
            case "\t":
                para.pushChar(" ", charStyle(fc, i))
            case "\u{1e}":
                para.pushChar("-", charStyle(fc, i))
            // Inline picture special character: extract the payload pointed
            // at by sprmCPicLocation.
            case "\u{1}":
                if let image = try pictureAt(fc) {
                    para.pushInline(image)
                }
            case "\u{2}", "\u{5}", "\u{8}", "\u{1f}":
                break
            default:
                if c.properties.generalCategory == .control { break }
                para.pushChar(c, charStyle(fc, i))
            }
            i += 1
        }
        let inlines = para.finish()
        cellStyled.flush(&cellBlocks)
        try Self.flushTable(&blocks, &tableRows, &row, &cellBlocks)
        if !inlinesAreEmpty(inlines) {
            styled.flush(&blocks)
            flushList(&blocks, &listRun)
            blocks.append(.paragraph(inlines))
        }
        styled.flush(&blocks)
        flushList(&blocks, &listRun)
        return blocks
    }

    /// Effective character style in specification order: paragraph/character
    /// style chain -> CHPX (toggles vs the style base) -> piece Prm.
    private func charStyle(_ fc: UInt32, _ charIndex: Int) -> Style {
        let paraIstd = papx.lookup(fc)?.istd ?? 0
        let chpxGrpprl = chpx.lookup(fc)?.chpx ?? []
        let istd = chpxIstd(chpxGrpprl[...]) ?? paraIstd
        let base = stylesheet.get(istd).chp
        var style = applyChpx(chpxGrpprl[...], base, base)
        if charIndex < text.pieceOf.count,
            let piecePrc = piecePrm(Int(text.pieceOf[charIndex]))
        {
            style = applyChpx(piecePrc[...], style, base)
        }
        return style
    }

    private func piecePrm(_ pieceIdx: Int) -> [UInt8]? {
        guard pieceIdx < pieceProps.count, let prcIdx = pieceProps[pieceIdx],
            prcIdx < prcs.count
        else { return nil }
        return prcs[prcIdx]
    }

    /// Paragraph properties in specification order: style chain -> PAPX ->
    /// piece Prm.
    private func effectivePap(_ fc: UInt32, _ charIndex: Int) -> EffectivePap {
        let istd: UInt16
        let papxDelta: PapDelta
        if let props = papx.lookup(fc) {
            istd = props.istd
            papxDelta = props.pap
        } else {
            istd = 0
            papxDelta = PapDelta()
        }
        var effective = stylesheet.get(istd).pap.merge(papxDelta)
        if charIndex < text.pieceOf.count, let prm = piecePrm(Int(text.pieceOf[charIndex])) {
            var prmDelta = PapDelta()
            applyPapSprms(prm[...], [], &prmDelta)
            effective = effective.merge(prmDelta)
        }
        return EffectivePap(istd: istd, effective: effective)
    }

    private mutating func emitParagraph(
        _ pap: EffectivePap, _ inlines: [Inline], _ blocks: inout [Block],
        _ listRun: inout [ListEntry], _ styled: inout StyledRun
    ) {
        let style = stylesheet.get(pap.istd)
        // A styled container absorbs its blank paragraphs: they are the
        // blank lines of a code block.
        if let block = style.block {
            flushList(&blocks, &listRun)
            styled.push(block, inlines, &blocks)
            return
        }
        if inlinesAreEmpty(inlines) {
            styled.flush(&blocks)
            flushList(&blocks, &listRun)
            return
        }
        let heading = style.heading ?? (pap.effective.outline.flatMap { $0 })
        if let level = heading {
            styled.flush(&blocks)
            flushList(&blocks, &listRun)
            var content = inlines
            rebaseEmphasis(&content, base: style.chp)
            // A numbered heading advances its sequence and keeps its number
            // visible — headings have no native numbering in the output.
            if let label = headingLabel(pap) {
                content.insert(.text(label, style: .plain), at: 0)
            }
            blocks.append(.heading(level: Int(level), anchor: nil, content: content))
            return
        }
        // ilfo 0xF801 marks a paragraph whose list numbering is suppressed.
        let ilfo = pap.effective.ilfo ?? 0
        if ilfo != 0 && ilfo != 0xF801 {
            let ilvl = Int(pap.effective.ilvl ?? 0)
            let list = lists.get(ilfo) ?? DocListDef.unknown(ilfo)
            let def = list.levels[min(ilvl, docListLevels - 1)]
            if let marker = def.marker {
                var number: UInt64 = 0
                var label: String?
                if marker.ordered {
                    let advanced = counters.next(ilfo, list, ilvl)
                    number = advanced.number
                    label = advanced.label
                }
                styled.flush(&blocks)
                listRun.append(
                    ListEntry(
                        level: ilvl, key: ListKey(instance: UInt64(list.lsid), marker: marker),
                        number: number, label: label, blocks: [.paragraph(inlines)]))
                return
            }
            // Marker "none": numbering suppressed, plain paragraph.
        }
        styled.flush(&blocks)
        flushList(&blocks, &listRun)
        blocks.append(.paragraph(inlines))
    }

    /// Emit one paragraph into the current table cell. Styled runs are
    /// scoped to the cell and are flushed before ordinary cell content.
    private func emitCellParagraph(
        _ pap: EffectivePap, _ inlines: [Inline], _ blocks: inout [Block],
        _ styled: inout StyledRun
    ) {
        if let block = stylesheet.get(pap.istd).block {
            styled.push(block, inlines, &blocks)
        } else {
            styled.flush(&blocks)
            if !inlinesAreEmpty(inlines) {
                blocks.append(.paragraph(inlines))
            }
        }
    }

    /// Extract the inline picture whose PICF + OfficeArt data the character's
    /// CHPX points at (`sprmCPicLocation`), retaining it as an asset.
    /// Unsupported or unreachable payloads degrade with a log.
    private mutating func pictureAt(_ fc: UInt32) throws -> Inline? {
        guard let grpprl = chpx.lookup(fc)?.chpx,
            let offset = chpxPicLocation(grpprl[...]).map(Int.init)
        else { return nil }
        guard let lcb = getU32(data, offset).map(Int.init),
            let cbHeader = getU16(data, offset + 4).map(Int.init)
        else { return nil }
        guard offset <= data.count, offset + lcb <= data.count else {
            Log.debug("picture data out of bounds in the Data stream")
            return nil
        }
        let picf = data[offset..<(offset + lcb)]
        let art = picf.dropFirst(min(cbHeader, picf.count))
        guard let blip = firstBlip(art, maxBytes: Int(Limits.maxEntryBytes)) else {
            Log.debug("skipping picture with no supported blip payload")
            return nil
        }
        let id = try assets.add(
            mediaType: blip.mediaType, originPart: "data/pic\(offset).\(blip.extension)",
            bytes: blip.bytes)
        return .image(alt: "", source: .asset(id))
    }

    /// The visible number label of a numbered heading paragraph, with its
    /// trailing separator; advances the list sequence.
    private mutating func headingLabel(_ pap: EffectivePap) -> String? {
        let ilfo = pap.effective.ilfo ?? 0
        if ilfo == 0 || ilfo == 0xF801 { return nil }
        let ilvl = Int(pap.effective.ilvl ?? 0)
        guard let list = lists.get(ilfo) else { return nil }
        guard let marker = list.levels[min(ilvl, docListLevels - 1)].marker, marker.ordered
        else { return nil }
        let advanced = counters.next(ilfo, list, ilvl)
        return (advanced.label ?? marker.label(advanced.number)) + " "
    }

    private static func flushTable(
        _ blocks: inout [Block], _ tableRows: inout [DocTableRow], _ row: inout [[Block]],
        _ cellBlocks: inout [Block]
    ) throws {
        if !cellBlocks.isEmpty {
            row.append(cellBlocks)
            cellBlocks = []
        }
        if !row.isEmpty {
            tableRows.append(DocTableRow(cells: row, tap: nil))
            row = []
        }
        if tableRows.isEmpty { return }
        let rows = tableRows.map { $0.intoGridRow() }
        tableRows = []
        if let block = try buildEdgeTable(rows) {
            blocks.append(block)
        }
    }
}
