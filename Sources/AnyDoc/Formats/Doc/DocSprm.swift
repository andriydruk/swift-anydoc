/// Sprm (single property modifier) walking and application, per MS-DOC:
/// character toggles resolve against the style-chain base (0 = off, 1 = on,
/// 0x80 = style's value, 0x81 = style's value inverted).

/// How many operand bytes a sprm carries. The high three bits of the opcode
/// name a fixed size; the variable class reads its length from the operand.
private func sprmOperandLen(_ sprm: UInt16, _ operand: ArraySlice<UInt8>) -> Int {
    switch sprm >> 13 {
    case 0, 1: return 1
    case 2, 4, 5: return 2
    case 3: return 4
    case 7: return 3
    default:
        if sprm == 0xD608 {
            guard let cb = sliceU16(operand, 0) else { return 0 }
            return Int(cb) + 1
        }
        guard let cb = operand.first else { return 0 }
        return Int(cb) + 1
    }
}

func walkSprms(_ grpprl: ArraySlice<UInt8>, _ visit: (UInt16, ArraySlice<UInt8>) -> Void) {
    var pos = 0
    while pos + 2 <= grpprl.count {
        guard let sprm = sliceU16(grpprl, pos) else { break }
        pos += 2
        let rest = grpprl.dropFirst(pos)
        let len = sprmOperandLen(sprm, rest)
        guard len <= rest.count else { break }
        visit(sprm, rest.prefix(len))
        pos += len
    }
}

/// Resolve a toggle operand against the style-chain base value.
private func toggle(_ operand: ArraySlice<UInt8>, _ base: Bool) -> Bool? {
    switch operand.first {
    case 0: return false
    case 1: return true
    case 0x80: return base
    case 0x81: return !base
    default: return nil
    }
}

/// The `sprmCIstd` character-style reference in a CHPX, if any.
func chpxIstd(_ grpprl: ArraySlice<UInt8>) -> UInt16? {
    var istd: UInt16?
    walkSprms(grpprl) { sprm, operand in
        if sprm == 0x4A30 { istd = sliceU16(operand, 0) }
    }
    return istd
}

/// The `sprmCPicLocation` Data-stream offset in a CHPX, if any: where an
/// inline picture's PICF + OfficeArt data begins.
func chpxPicLocation(_ grpprl: ArraySlice<UInt8>) -> UInt32? {
    var location: UInt32?
    walkSprms(grpprl) { sprm, operand in
        if sprm == 0x6A03 { location = sliceU32(operand, 0) }
    }
    return location
}

/// Apply a CHPX grpprl over `current`, resolving toggle operands against the
/// style chain's value (`styleBase`), per the published algorithm.
func applyChpx(_ grpprl: ArraySlice<UInt8>, _ current: Style, _ styleBase: Style) -> Style {
    var style = current
    walkSprms(grpprl) { sprm, operand in
        // sprmCFBold / sprmCFItalic / sprmCFStrike are toggles.
        switch sprm {
        case 0x0835:
            if let v = toggle(operand, styleBase.bold) { style.bold = v }
        case 0x0836:
            if let v = toggle(operand, styleBase.italic) { style.italic = v }
        case 0x0837:
            if let v = toggle(operand, styleBase.strike) { style.strike = v }
        default:
            break
        }
    }
    return style
}

/// A CHPX grpprl interpreted as a character-style *definition* layer: the
/// parent's value is the base for its toggles.
func applyStyleChpx(_ grpprl: ArraySlice<UInt8>, _ parent: Style) -> Style {
    applyChpx(grpprl, parent, parent)
}

/// Merge flags of one cell (TC80 `tcgrf` / `sprmTVertMerge`).
struct TapCell {
    var horzFirst = false
    var horzCont = false
    var vertRestart = false
    var vertCont = false
}

/// A row's table properties from `sprmTDefTable` and its companion table
/// sprms in the row-end PAPX (TAPX).
struct Tap {
    /// Cell boundary positions in twips (`rgdxaCenter`), one more entry than
    /// the cell count.
    var boundaries: [Int16] = []
    var cells: [TapCell] = []
    /// `sprmTTableHeader`: the row repeats as a header row.
    var header = false
}

/// Paragraph properties a PAPX (or style PAPX) contributes. Every field is
/// tri-state so a later layer can leave an earlier one standing.
struct PapDelta {
    var inTable: Bool?
    var ttp: Bool?
    /// Doubly optional: the sprm can explicitly say "no outline level".
    var outline: UInt8??
    var ilfo: UInt16?
    var ilvl: UInt8?
    /// `sprmPItap` table depth (1 = a regular table).
    var itap: Int32?
    /// `sprmPFInnerTableCell` / `sprmPFInnerTtp`: nested-table cell/row
    /// terminators.
    var innerCell: Bool?
    var innerTtp: Bool?
    /// Row properties, present on TTP marks.
    var tap: Tap?

    func merge(_ over: PapDelta) -> PapDelta {
        PapDelta(
            inTable: over.inTable ?? inTable,
            ttp: over.ttp ?? ttp,
            outline: over.outline ?? outline,
            ilfo: over.ilfo ?? ilfo,
            ilvl: over.ilvl ?? ilvl,
            itap: over.itap ?? itap,
            innerCell: over.innerCell ?? innerCell,
            innerTtp: over.innerTtp ?? innerTtp,
            tap: over.tap ?? tap)
    }
}

func applyPapSprms(_ grpprl: ArraySlice<UInt8>, _ data: [UInt8], _ delta: inout PapDelta) {
    // The closure mutates through a local, then copies back: Swift will not
    // let an inout parameter be captured by an escaping-shaped closure.
    var out = delta
    walkSprms(grpprl) { sprm, operand in
        switch sprm {
        // sprmPFInTable / sprmPFTtp
        case 0x2416: out.inTable = (operand.first ?? 0) != 0
        case 0x2417: out.ttp = (operand.first ?? 0) != 0
        // sprmPHugePapx: the real grpprl lives length-prefixed in Data.
        case 0x6646:
            if let off = sliceU32(operand, 0).map(Int.init), let cb = getU16(data, off).map(Int.init),
                off + 2 + cb <= data.count
            {
                applyPapSprms(data[(off + 2)..<(off + 2 + cb)], [], &out)
            }
        // sprmPOutLvl
        case 0x2640:
            if let v = operand.first {
                out.outline = .some(v < 9 ? UInt8(v + 1) : nil)
            }
        // sprmPIlvl / sprmPIlfo
        case 0x260A: out.ilvl = operand.first
        case 0x460B: out.ilfo = sliceU16(operand, 0)
        // sprmPItap / sprmPDtap: table nesting depth.
        case 0x6649: out.itap = sliceU32(operand, 0).map { Int32(bitPattern: $0) }
        case 0x664A:
            if let d = sliceU32(operand, 0).map({ Int32(bitPattern: $0) }) {
                out.itap = (out.itap ?? 0).addingReportingOverflow(d).overflow
                    ? (d > 0 ? Int32.max : Int32.min) : (out.itap ?? 0) &+ d
            }
        // sprmPFInnerTableCell / sprmPFInnerTtp
        case 0x244B: out.innerCell = (operand.first ?? 0) != 0
        case 0x244C: out.innerTtp = (operand.first ?? 0) != 0
        // sprmTDefTable: the row's cell boundaries and TC80 merge flags.
        case 0xD608:
            if var tap = parseTdefTable(operand) {
                tap.header = out.tap?.header ?? false
                out.tap = tap
            }
        // sprmTTableHeader
        case 0x3404:
            let on = (operand.first ?? 0) != 0
            if out.tap != nil {
                out.tap!.header = on
            } else if on {
                out.tap = Tap(header: true)
            }
        // sprmTVertMerge: per-cell vertical merge state.
        case 0xD62B:
            let i = operand.startIndex
            guard operand.count >= 3, out.tap != nil else { break }
            let itc = Int(operand[i + 1])
            let flag = operand[i + 2]
            guard itc < out.tap!.cells.count else { break }
            // VerticalMergeFlag: 1 = continuation, 3 = restart.
            out.tap!.cells[itc].vertCont = flag == 0x01
            out.tap!.cells[itc].vertRestart = flag == 0x03
        default:
            break
        }
    }
    delta = out
}

/// Parse a `TDefTableOperand`: cb, NumberOfColumns, `rgdxaCenter`
/// boundaries, then TC80 records (which may be fewer than the columns).
private func parseTdefTable(_ operand: ArraySlice<UInt8>) -> Tap? {
    let tc80Size = 20
    guard operand.count > 2 else { return nil }
    let columns = Int(operand[operand.startIndex + 2])
    if columns > 63 { return nil }
    var boundaries: [Int16] = []
    boundaries.reserveCapacity(columns + 1)
    for i in 0...columns {
        guard let value = sliceU16(operand, 3 + i * 2) else { return nil }
        boundaries.append(Int16(bitPattern: value))
    }
    var cells = [TapCell](repeating: TapCell(), count: columns)
    let tcBase = 3 + (columns + 1) * 2
    for i in 0..<columns {
        // Fewer TC80s than columns: defaults apply to the rest.
        guard let tcgrf = sliceU16(operand, tcBase + i * tc80Size) else { break }
        // TCGRF: horzMerge (bits 0-1), textFlow (2-4), vertMerge (5-6).
        let horz = tcgrf & 0x3
        cells[i].horzCont = horz == 1
        cells[i].horzFirst = horz >= 2
        let vert = (tcgrf >> 5) & 0x3
        cells[i].vertCont = vert == 1
        cells[i].vertRestart = vert == 3
    }
    return Tap(boundaries: boundaries, cells: cells, header: false)
}
