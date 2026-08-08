/// Spreadsheets: every sheet becomes a table, in workbook order.
///
/// A workbook carries no headings, no styling worth keeping and no reading
/// order beyond the grid, so the mapping is deliberately flat: one table per
/// sheet, a level-2 heading naming each sheet when there is more than one,
/// and the shape of the data deciding which rows are headers.

func parseSheet(_ bytes: [UInt8]) throws -> Document {
    let workbook = try openWorkbook(bytes)
    let sheetNames = workbook.sheets
    let multiSheet = sheetNames.count > 1

    var doc = Document()
    var failed = 0
    for sheet in sheetNames {
        let cells: [SheetCell]
        do {
            cells = try workbook.cells(ofSheetAt: sheet.path)
        } catch let e as ConvertError where !e.isFatal {
            Log.warn("skipping unreadable sheet \(rustDebugString(sheet.name)): \(e.message)")
            failed += 1
            continue
        }
        // The used range is the bounding box of the cells that carry a value,
        // not whatever `<dimension>` claims.
        guard let bounds = usedRange(of: cells) else { continue }

        // Merged regions are advisory: a sheet without them still renders.
        var regions: [SheetRegion] = []
        do {
            regions = try workbook.mergedRegions(ofSheetAt: sheet.path)
        } catch let e as ConvertError where !e.isFatal {
            Log.warn(
                "skipping unreadable merged-region list for \(rustDebugString(sheet.name)): "
                    + e.message)
        }

        guard var table = try buildSheetTable(cells: cells, bounds: bounds, regions: regions) else {
            continue
        }
        // A spreadsheet marks no header row, so the shape of the data decides.
        table.headerRows = resolveHeaderRows(table, declared: 0)
        if multiSheet {
            doc.blocks.append(.heading(2, [.plain(sheet.name)]))
        }
        doc.blocks.append(.table(table))
    }
    if !sheetNames.isEmpty && failed == sheetNames.count {
        throw ConvertError.malformed("no sheet in the workbook could be read")
    }
    return doc
}

/// Open a workbook, choosing the reader by content the way the reference's
/// auto-detection does.
private func openWorkbook(_ bytes: [UInt8]) throws -> XlsxWorkbook {
    // The legacy binary workbook (.xls, and the .xlsb record stream) shares
    // the OLE compound container with .doc and .ppt and lands with them.
    if let ole = probeOle(bytes) {
        if case .encrypted = ole { throw ole }
        throw ConvertError.unsupported(
            "legacy binary workbooks are not implemented yet in swift-anydoc")
    }
    return try XlsxWorkbook(bytes: bytes)
}

private struct UsedRange {
    var startRow: UInt32
    var startCol: UInt32
    var height: Int
    var width: Int
}

/// The bounding box of the cells carrying a value, or `nil` when the sheet
/// has none.
private func usedRange(of cells: [SheetCell]) -> UsedRange? {
    guard var minRow = cells.first?.row, var minCol = cells.first?.col else { return nil }
    var maxRow = minRow
    var maxCol = minCol
    // Cells do not always arrive in (row, column) order.
    for cell in cells {
        minRow = min(minRow, cell.row)
        maxRow = max(maxRow, cell.row)
        minCol = min(minCol, cell.col)
        maxCol = max(maxCol, cell.col)
    }
    return UsedRange(
        startRow: minRow, startCol: minCol,
        height: Int(maxRow - minRow) + 1, width: Int(maxCol - minCol) + 1)
}

/// Lay the used range out as a table, applying merged regions as spans.
/// Returns `nil` when nothing survives (a sheet holding only blanks).
private func buildSheetTable(
    cells: [SheetCell], bounds: UsedRange, regions: [SheetRegion]
) throws -> Table? {
    // The used range is materialized position by position, so its area is
    // the work this sheet costs. The reference allocates it outright and dies
    // on a workbook whose two occupied cells sit in opposite corners; charge
    // it against the expansion budget instead.
    let area = UInt64(bounds.height) * UInt64(bounds.width)
    if area > Limits.maxExpansion {
        throw ConvertError.resourceLimit(
            limit: "max_expansion",
            detail: "sheet used range spans \(area) positions")
    }

    var values: [UInt64: SheetValue] = [:]
    values.reserveCapacity(cells.count)
    for cell in cells {
        let r = UInt64(cell.row - bounds.startRow)
        let c = UInt64(cell.col - bounds.startCol)
        values[r &* UInt64(bounds.width) &+ c] = cell.value
    }

    // A merged region's top-left cell becomes a spanning origin and the rest
    // of its positions are covered.
    var origins: [UInt64: (colSpan: UInt32, rowSpan: UInt32)] = [:]
    var covered: Set<UInt64> = []
    let endRow = UInt64(bounds.startRow) + UInt64(bounds.height)
    let endCol = UInt64(bounds.startCol) + UInt64(bounds.width)
    for region in regions {
        // Intersect with the used range first: a region wholly above or left
        // of it must not saturate onto the top-left cell, and positions
        // outside it are never materialized, so a crafted region list cannot
        // force insertions beyond the cells that actually exist.
        let row0 = UInt64(max(region.startRow, bounds.startRow))
        let col0 = UInt64(max(region.startCol, bounds.startCol))
        let rowEnd = min(UInt64(region.endRow) + 1, endRow)
        let colEnd = min(UInt64(region.endCol) + 1, endCol)
        if row0 >= rowEnd || col0 >= colEnd { continue }
        let r0 = row0 - UInt64(bounds.startRow)
        let c0 = col0 - UInt64(bounds.startCol)
        let r1 = rowEnd - UInt64(bounds.startRow)
        let c1 = colEnd - UInt64(bounds.startCol)
        // A region clipped down to a single cell spans nothing.
        if r1 - r0 == 1 && c1 - c0 == 1 { continue }
        origins[r0 &* UInt64(bounds.width) &+ c0] = (
            colSpan: UInt32(c1 - c0), rowSpan: UInt32(r1 - r0)
        )
        for r in r0..<r1 {
            for c in c0..<c1 where (r, c) != (r0, c0) {
                covered.insert(r &* UInt64(bounds.width) &+ c)
            }
        }
    }

    var builder = GridBuilder()
    for r in 0..<UInt64(bounds.height) {
        builder.nextRow()
        for c in 0..<UInt64(bounds.width) {
            let key = r &* UInt64(bounds.width) &+ c
            if covered.contains(key) {
                builder.covered()
                continue
            }
            let text = formatSheetValue(values[key] ?? .empty)
            let cell = text.isEmpty ? Cell() : Cell.fromInlines([.plain(text)])
            if let span = origins[key] {
                try builder.place(
                    Cell.spanning(cell.blocks, colSpan: span.colSpan, rowSpan: span.rowSpan))
            } else {
                try builder.place(cell)
            }
        }
    }
    let table = builder.finish(.data)
    return table.grid.isEmpty ? nil : table
}

/// A cell value as it renders in Markdown.
func formatSheetValue(_ value: SheetValue) -> String {
    switch value {
    case .empty:
        return ""
    // Untrimmed: leading and trailing whitespace in a cell is source content.
    case .string(let s):
        return cleanText(s)
    case .float(let f):
        return formatSheetFloat(f)
    case .bool(let b):
        return b ? "TRUE" : "FALSE"
    case .error(let name):
        return "#\(name)"
    case .dateTimeIso(let s):
        return s
    case .dateTime(let dt):
        if dt.isDuration {
            return formatDurationDays(dt.value)
        }
        // A serial below one whole day carries no date: it is a time of day.
        if abs(dt.value) < 1.0 {
            return formatTimeOfDay(dt.value)
        }
        guard let civil = excelSerialToCivil(dt) else {
            return formatSheetFloat(dt.value)
        }
        let text = formatCivilDateTime(
            year: civil.year, month: civil.month, day: civil.day,
            hour: civil.hour, minute: civil.minute, second: civil.second)
        // Midnight means the serial carried no time of day.
        return text.hasSuffix(" 00:00:00") ? String(text.dropLast(9)) : text
    }
}

/// Float formatting at the 15 significant decimal digits a spreadsheet stores
/// and displays. Shortest round-trip formatting past that surfaces the binary
/// representation (`3554.7000000000003`); 15 digits still keeps small values
/// like `0.0000004` exact.
func formatSheetFloat(_ value: Double) -> String {
    rustFormatF64(roundToSignificantDigits(value, 15))
}
