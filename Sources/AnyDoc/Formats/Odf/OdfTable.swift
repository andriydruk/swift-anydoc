/// ODF tables: canonical grid construction with covered-cell consumption,
/// repeats honored in every container, a hard expansion budget for
/// repeat expansion, and typed value-attribute fallback for cells without
/// display text.
///
/// Empty filler runs *inside* the used range materialize fully so every
/// later cell keeps its source coordinates; only trailing filler (empty rows
/// at the end, empty cells at a row's end) is elided. All materialization is
/// charged against the fixed expansion budget.

func parseTable(_ elem: XmlElement, _ ctx: OdfCtx) throws -> [Block] {
    var state = TableState()
    try walkRows(elem, ctx, &state, true)
    var table = state.builder.finish(.data)
    if table.grid.isEmpty {
        return []
    }
    table.headerRows = resolveHeaderRows(table, declared: state.headerRows)
    return [.table(table)]
}

private struct TableState {
    var builder = GridBuilder()
    /// Grid slots produced by expansion, checked against the fixed budget.
    var expansion: UInt64 = 0
    /// Text bytes duplicated by expansion, checked against their own budget.
    var expansionBytes: UInt64 = 0
    var pendingRows: UInt64 = 0
    var headerRows = 0
    var rowsEmitted = 0

    mutating func charge(_ cells: UInt64) throws {
        expansion = expansion.saturatingAdding(cells)
        if expansion > Limits.maxExpansion {
            throw ConvertError.resourceLimit(
                limit: "max_expansion",
                detail: "table repeat expansion exceeds the content budget")
        }
    }

    /// Charge text bytes that repeat expansion duplicates: the slot budget
    /// bounds positions, this bounds the amplified content itself.
    mutating func chargeBytes(_ bytes: UInt64) throws {
        expansionBytes = expansionBytes.saturatingAdding(bytes)
        if expansionBytes > Limits.maxExpansionTextBytes {
            throw ConvertError.resourceLimit(
                limit: "max_expansion_text_bytes",
                detail: "table repeat expansion duplicates more text than the budget")
        }
    }
}

/// One parsed cell of a row template, reused across row repeats.
private enum RowCell {
    case covered(repeats: UInt64)
    case cell(repeats: UInt64, colSpan: UInt32, rowSpan: UInt32, blocks: [Block], bytes: UInt64)
}

/// Approximate retained text bytes of parsed cell content.
private func blockBytes(_ blocks: [Block]) -> UInt64 {
    func inlineBytes(_ inlines: [Inline]) -> UInt64 {
        var sum: UInt64 = 0
        for inline in inlines {
            switch inline {
            case .text(let text, _):
                sum = sum.saturatingAdding(UInt64(text.utf8.count))
            case .link(let content, let target):
                let targetLen: UInt64
                switch target {
                case .external(let s), .relative(let s), .anchor(let s):
                    targetLen = UInt64(s.utf8.count)
                }
                sum = sum.saturatingAdding(inlineBytes(content)).saturatingAdding(targetLen)
            case .image(let alt, _):
                sum = sum.saturatingAdding(UInt64(alt.utf8.count))
            case .anchor(let id), .noteRef(let id):
                sum = sum.saturatingAdding(UInt64(id.utf8.count))
            case .lineBreak:
                sum = sum.saturatingAdding(1)
            }
        }
        return sum
    }
    var sum: UInt64 = 0
    for block in blocks {
        let piece: UInt64
        switch block {
        case .paragraph(let inlines), .heading(_, _, let inlines):
            piece = inlineBytes(inlines)
        case .list(let list):
            var total: UInt64 = 0
            for item in list.items {
                total = total.saturatingAdding(blockBytes(item.blocks))
            }
            piece = total
        case .table(let table):
            var total: UInt64 = 0
            for row in table.grid {
                for slot in row {
                    if case .origin(let cell) = slot {
                        total = total.saturatingAdding(blockBytes(cell.blocks))
                    }
                }
            }
            piece = total
        case .blockQuote(let inner):
            piece = blockBytes(inner)
        case .codeBlock(_, let text):
            piece = UInt64(text.utf8.count)
        case .rule:
            piece = 0
        }
        sum = sum.saturatingAdding(piece)
    }
    return sum
}

private func walkRows(
    _ container: XmlElement,
    _ ctx: OdfCtx,
    _ state: inout TableState,
    _ top: Bool
) throws {
    for child in container.childElements {
        guard child.ns == Ns.table else {
            continue
        }
        switch child.local {
        case "table-header-rows":
            let before = state.rowsEmitted
            try walkRows(child, ctx, &state, false)
            if top, state.headerRows == 0 {
                state.headerRows = state.rowsEmitted - before
            }
        case "table-rows", "table-row-group":
            try walkRows(child, ctx, &state, false)
        case "table-row":
            let repeats = max(
                child.attr(Ns.table, "number-rows-repeated").flatMap { UInt64($0) } ?? 1, 1)
            try emitRow(child, ctx, &state, repeats)
        default:
            break
        }
    }
}

private func emitRow(
    _ row: XmlElement,
    _ ctx: OdfCtx,
    _ state: inout TableState,
    _ repeats: UInt64
) throws {
    if rowIsEmpty(row) {
        state.pendingRows = state.pendingRows.saturatingAdding(repeats)
        return
    }
    // Materialize any buffered empty gap first, in full: rows after the gap
    // keep their source coordinates. The rows are charged so a pathological
    // gap hits the budget instead of memory.
    if state.pendingRows > 0 {
        try state.charge(state.pendingRows)
        for _ in 0..<state.pendingRows {
            state.builder.nextRow()
            state.rowsEmitted += 1
        }
        state.pendingRows = 0
    }
    // Parse the row template exactly once: repeated rows clone the parsed
    // cells instead of reparsing, so per-parse side effects (notes, assets)
    // happen once and the duplicated text bytes are charged up front.
    let cells = try parseRowCells(row, ctx)
    try state.charge(repeats.saturatingSubtracting(1))
    for cell in cells {
        if case .cell(let cellRepeats, _, _, _, let bytes) = cell {
            let copies = repeats.saturatingMultiplying(cellRepeats).saturatingSubtracting(1)
            try state.chargeBytes(bytes.saturatingMultiplying(copies))
        }
    }
    for _ in 0..<repeats {
        state.builder.nextRow()
        state.rowsEmitted += 1
        try emitParsedCells(cells, &state)
    }
}

/// Parse one row's cells into the reusable template.
private func parseRowCells(_ row: XmlElement, _ ctx: OdfCtx) throws -> [RowCell] {
    var out: [RowCell] = []
    for cell in row.childElements {
        let repeats = max(
            cell.attr(Ns.table, "number-columns-repeated").flatMap { UInt64($0) } ?? 1, 1)
        if cell.named(Ns.table, "covered-table-cell") {
            out.append(.covered(repeats: repeats))
            continue
        }
        if !cell.named(Ns.table, "table-cell") {
            continue
        }
        let colSpan = max(
            cell.attr(Ns.table, "number-columns-spanned").flatMap { UInt32($0) } ?? 1, 1)
        let rowSpan = max(
            cell.attr(Ns.table, "number-rows-spanned").flatMap { UInt32($0) } ?? 1, 1)
        let blocks = try cellBlocks(cell, ctx)
        let bytes = blockBytes(blocks)
        out.append(
            .cell(repeats: repeats, colSpan: colSpan, rowSpan: rowSpan, blocks: blocks,
                bytes: bytes))
    }
    return out
}

private func emitParsedCells(_ cells: [RowCell], _ state: inout TableState) throws {
    var pendingCells: UInt64 = 0
    for cell in cells {
        switch cell {
        case .covered(let repeats):
            try flushGap(&state, &pendingCells)
            // One explicitly written covered position each; a stray one
            // (no span accounts for it) becomes an empty cell inside
            // covered().
            try state.charge(repeats)
            for _ in 0..<repeats {
                if !state.builder.covered() {
                    Log.debug("covered table cell without a spanning origin")
                }
            }
        case .cell(let repeats, let colSpan, let rowSpan, let blocks, _):
            if blocks.isEmpty, colSpan == 1, rowSpan == 1 {
                pendingCells = pendingCells.saturatingAdding(repeats)
                continue
            }
            try flushGap(&state, &pendingCells)
            try state.charge(repeats.saturatingMultiplying(UInt64(colSpan)))
            for _ in 0..<repeats {
                try state.builder.place(
                    Cell.spanning(blocks, colSpan: colSpan, rowSpan: rowSpan))
            }
        }
    }
}

/// Materialize a buffered empty-cell run in full so the next cell lands on
/// its source column. Trailing runs are never flushed and stay elided.
private func flushGap(_ state: inout TableState, _ pending: inout UInt64) throws {
    if pending == 0 {
        return
    }
    try state.charge(pending)
    for _ in 0..<pending {
        try state.builder.place(Cell())
    }
    pending = 0
}

/// A cell's blocks: its text content, or a typed value-attribute fallback
/// when the producer wrote no display text.
private func cellBlocks(_ cell: XmlElement, _ ctx: OdfCtx) throws -> [Block] {
    let blocks = try parseContainer(cell, ctx)
    let hasContent = blocks.contains { block in
        if case .paragraph(let inlines) = block {
            return !inlinesAreEmpty(inlines)
        }
        return true
    }
    if hasContent {
        return blocks
    }
    switch valueText(cell) {
    case .some(let text): return [.paragraph([.plain(text)])]
    case nil: return []
    }
}

private func valueText(_ cell: XmlElement) -> String? {
    guard let valueType = cell.attr(Ns.office, "value-type") else {
        return nil
    }
    switch valueType {
    case "percentage":
        guard let v = cell.attr(Ns.office, "value").flatMap(parseRustF64) else { return nil }
        return "\(trimFloat(v * 100.0))%"
    case "currency":
        guard let raw = cell.attr(Ns.office, "value") else { return nil }
        let cur = cell.attr(Ns.office, "currency") ?? ""
        guard let v = parseRustF64(raw) else { return nil }
        if cur.isEmpty {
            return trimFloat(v)
        } else {
            return "\(trimFloat(v)) \(cur)"
        }
    case "float":
        guard let v = cell.attr(Ns.office, "value").flatMap(parseRustF64) else { return nil }
        return trimFloat(v)
    case "date":
        return cell.attr(Ns.office, "date-value")
    case "time":
        return cell.attr(Ns.office, "time-value").map(durationText)
    case "boolean":
        return cell.attr(Ns.office, "boolean-value").map { $0 == "true" ? "TRUE" : "FALSE" }
    case "string":
        return cell.attr(Ns.office, "string-value")
    default:
        return nil
    }
}

/// Shortest round-trip float formatting - no fixed-precision rounding.
///
/// Rust `{}` (Display) prints an f64's shortest round-trip digits in plain
/// positional notation; Swift's `description` derives the same shortest
/// digits but switches to exponent form outside a fixed range, so the digits
/// are re-rendered positionally here.
// PARITY: both sides print the unique shortest correctly-rounded digit
// string (Grisu in Rust, SwiftDtoa here), so the digits agree; only the
// notation had to be normalized.
private func trimFloat(_ v: Double) -> String {
    if v.isNaN {
        return "NaN"
    }
    if v.isInfinite {
        return v < 0 ? "-inf" : "inf"
    }
    let desc = "\(v)"
    var scalars = ArraySlice(Array(desc.unicodeScalars))
    var sign = ""
    if scalars.first == "-" {
        sign = "-"
        scalars = scalars.dropFirst()
    }
    var digits: [Unicode.Scalar] = []
    var pointIndex: Int? = nil
    var exponent = 0
    while let c = scalars.first {
        scalars = scalars.dropFirst()
        if c == "." {
            pointIndex = digits.count
        } else if c == "e" || c == "E" {
            var expNegative = false
            if let s = scalars.first, s == "+" || s == "-" {
                expNegative = s == "-"
                scalars = scalars.dropFirst()
            }
            var e = 0
            while let d = scalars.first, d.isAsciiDigit {
                e = e * 10 + Int(d.value - Unicode.Scalar("0").value)
                scalars = scalars.dropFirst()
            }
            exponent = expNegative ? -e : e
            break
        } else {
            digits.append(c)
        }
    }
    var point = (pointIndex ?? digits.count) + exponent
    while digits.first == "0" {
        digits.removeFirst()
        point -= 1
    }
    while digits.last == "0" {
        digits.removeLast()
    }
    if digits.isEmpty {
        return sign + "0"
    }
    if point <= 0 {
        return sign + "0." + String(repeating: "0", count: -point)
            + String(String.UnicodeScalarView(digits))
    }
    if point >= digits.count {
        return sign + String(String.UnicodeScalarView(digits))
            + String(repeating: "0", count: point - digits.count)
    }
    return sign + String(String.UnicodeScalarView(digits[..<point])) + "."
        + String(String.UnicodeScalarView(digits[point...]))
}

/// Rust `f64::from_str`: the decimal grammar (`parsesAsRustF64`) plus the
/// `inf`/`infinity`/`nan` spellings, case-insensitive. Swift's own
/// `Double.init` additionally accepts hex floats, which Rust rejects, so the
/// grammar is checked first.
private func parseRustF64(_ text: String) -> Double? {
    var rest = Substring(text)
    var negative = false
    if let first = rest.first, first == "+" || first == "-" {
        negative = first == "-"
        rest = rest.dropFirst()
    }
    switch String(rest).asciiLowercased() {
    case "inf", "infinity":
        return negative ? -Double.infinity : Double.infinity
    case "nan":
        return Double.nan
    default:
        break
    }
    guard parsesAsRustF64(text) else {
        return nil
    }
    return Double(text)
}

/// Full ISO 8601 duration -> clock text: `P1DT2H` -> `26:00:00`,
/// `PT26H30M15S` -> `26:30:15`, weeks are 7 days, and fractional values are
/// valid on any component (`PT1.5H` -> `1:30:00`). Year/month components
/// have no fixed length, and unrepresentably large values overflow the
/// clock format, so both keep their raw ISO text.
private func durationText(_ iso: String) -> String {
    var total = 0.0  // seconds
    var number = ""
    var inTime = false
    var negative = false
    for c in iso.unicodeScalars {
        switch c {
        case "-" where total == 0.0 && number.isEmpty:
            negative = true
        case "P":
            break
        case "T":
            inTime = true
            number = ""
        case "Y" where !inTime, "M" where !inTime:
            if let n = parseRustF64(number), n != 0.0 {
                return iso
            }
            number = ""
        case "W" where !inTime, "D" where !inTime:
            let unit = c == "W" ? 604_800.0 : 86_400.0
            total += (parseRustF64(number) ?? 0.0) * unit
            number = ""
        case "H" where inTime, "M" where inTime, "S" where inTime:
            let unit: Double
            switch c {
            case "H": unit = 3600.0
            case "M": unit = 60.0
            default: unit = 1.0
            }
            total += (parseRustF64(number) ?? 0.0) * unit
            number = ""
        case let c where c.isAsciiDigit || c == ".":
            number.unicodeScalars.append(c)
        default:
            number = ""
        }
    }
    // Round to milliseconds; a value the clock format cannot represent
    // exactly keeps its source text instead of silently degrading.
    let totalMsFloat = (total * 1000.0).rounded()
    if !(totalMsFloat >= 0.0 && totalMsFloat < 1e18) {
        return iso
    }
    let totalMs = UInt64(totalMsFloat)
    let sign = negative ? "-" : ""
    let hours = totalMs / 3_600_000
    let rest = totalMs % 3_600_000
    let minutes = rest / 60_000
    let ms = rest % 60_000
    // Rust formats the seconds as `{:02}` (or `{:06.3}` with milliseconds);
    // the integer arithmetic below reproduces those paddings exactly.
    if ms % 1000 != 0 {
        return "\(sign)\(hours):\(pad2(minutes)):\(pad2(ms / 1000)).\(pad3(ms % 1000))"
    }
    return "\(sign)\(hours):\(pad2(minutes)):\(pad2(ms / 1000))"
}

private func pad2(_ n: UInt64) -> String {
    n < 10 ? "0\(n)" : "\(n)"
}

private func pad3(_ n: UInt64) -> String {
    if n < 10 { return "00\(n)" }
    if n < 100 { return "0\(n)" }
    return "\(n)"
}

private func rowIsEmpty(_ row: XmlElement) -> Bool {
    row.childElements.allSatisfy { cell in
        if cell.named(Ns.table, "covered-table-cell") {
            return false  // structural: belongs to a span
        }
        if !cell.named(Ns.table, "table-cell") {
            return true
        }
        return cell.attr(Ns.table, "number-columns-spanned") == nil
            && cell.attr(Ns.table, "number-rows-spanned") == nil
            && cell.attr(Ns.office, "value-type") == nil
            && cell.children.isEmpty
    }
}

/// One sheet of a spreadsheet body.
func parseSpreadsheet(_ sheet: XmlElement, _ ctx: OdfCtx) throws -> [Block] {
    let tables = sheet.childElements.filter { $0.named(Ns.table, "table") }
    let multiSheet = tables.count > 1
    var blocks: [Block] = []
    for table in tables {
        let name = table.attr(Ns.table, "name") ?? ""
        let content = try parseTable(table, ctx)
        if content.isEmpty {
            continue
        }
        if multiSheet {
            blocks.append(.heading(2, [.plain(name)]))
        }
        blocks.append(contentsOf: content)
    }
    return blocks
}

extension UInt64 {
    /// Rust `u64::saturating_sub`.
    fileprivate func saturatingSubtracting(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }

    /// Rust `u64::saturating_mul`.
    fileprivate func saturatingMultiplying(_ other: UInt64) -> UInt64 {
        let (result, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? .max : result
    }
}
