/// Header-row detection for grids whose format designates no header row. CSV
/// and spreadsheets have no notion of one; Word, RTF, and DrawingML carry only
/// pagination and table-style flags, none of which means "this row labels the
/// columns". The first row is a header when the columns below it are
/// consistently typed and the row itself is not: a label sits above a column
/// of numbers, dates or booleans without being one of them.

/// Body rows the column types are read from. A header shows in the first
/// screenful of data, so a full pass over a million-row export buys nothing.
private let sampleRows = 50

/// Share of a column's non-empty body cells that must agree on one type
/// before the column votes, as a numerator over `dominanceDen`. Stray `N/A`
/// and footnote markers are common enough that exact agreement would silence
/// otherwise obvious columns.
private let dominanceNum = 9
private let dominanceDen = 10

/// Longest a label can be when nothing else distinguishes the first row.
/// Beyond this the text reads as prose, which is data.
private let maxLabel = 64

/// What a cell value looks like, at the granularity the vote needs.
private enum Kind: Equatable {
    case number
    case bool
    case date
    case text
}

/// A grid's `Table.headerRows`: what the format `declared`, or — when it
/// declared none — 1 if the first row labels the columns and 0 otherwise.
/// Only the first row is ever considered, since that is where labels go.
func resolveHeaderRows(_ table: Table, declared: Int) -> Int {
    if declared > 0 {
        return min(declared, table.grid.count)
    }
    let grid = table.grid
    if grid.count < 2 {
        return 0
    }
    // A span in the first row means grouped columns or a merged title, not
    // one label per column.
    let firstRowPlain = grid[0].allSatisfy { slot in
        if case .origin(let c) = slot { return c.colSpan == 1 && c.rowSpan == 1 }
        return false
    }
    if !firstRowPlain {
        return 0
    }
    let sample = Array(grid[1..<min(grid.count, sampleRows + 1)])
    // A first row that does not have the body's field count is a title line
    // or a stray fragment, not a header.
    if grid[0].count != modalWidth(sample) {
        return 0
    }

    let head: [String] = grid[0].map(slotText)
    let body: [[String]] = sample.map { row in row.map(slotText) }
    // Columns past the last one holding content never render, so they take no
    // part in the checks below.
    func contentWidth(_ row: [String]) -> Int {
        row.lastIndex(where: { !$0.isBlank }).map { $0 + 1 } ?? 0
    }
    let width = ([head] + body).map(contentWidth).max() ?? 0
    // Content past the last label is an unlabelled column, same as a blank
    // label between two filled ones.
    if width == 0 || width > head.count {
        return 0
    }

    var seen: Set<String> = []
    for (c, value) in head.prefix(width).enumerated() {
        // Every column carries a label, with one exception: the unnamed index
        // column that pandas and R write as a leading empty field.
        if value.isBlank {
            if c == 0 { continue }
            return 0
        }
        // A label is one line; a cell holding several is data.
        if value.contains("\n") {
            return 0
        }
        // Repeated values are what a data row looks like, not a header.
        if !seen.insert(fold(value)).inserted {
            return 0
        }
    }

    var headerVotes = 0
    var dataVotes = 0
    for (c, label) in head.prefix(width).enumerated() {
        let values: [String] = body.compactMap { row in
            guard c < row.count else { return nil }
            let v = row[c].rustTrim()
            return v.isEmpty ? nil : v
        }
        if values.isEmpty { continue }
        let label = label.rustTrim()
        switch dominantKind(values) {
        // A column of numbers, dates or booleans under a label that is none
        // of those: the label does not belong to its own column.
        case .some(let kind) where kind != .text:
            if classify(label) == .text {
                headerVotes += 1
            } else {
                dataVotes += 1
            }
        // Text columns carry no type signal, but a first-row value that
        // recurs below is plainly a value of the column, not its label.
        default:
            if values.contains(where: { fold($0) == fold(label) }) {
                dataVotes += 1
            }
        }
    }

    if headerVotes == 0 && dataVotes == 0 {
        // Text above text, with no value repeated: only the shape of the row
        // is left to go on. Short single-line entries read as labels, and the
        // alternative is the empty header row every such table renders today.
        let labelled = head.prefix(width).allSatisfy { $0.unicodeScalars.count <= maxLabel }
        return labelled ? 1 : 0
    }
    return headerVotes > dataVotes ? 1 : 0
}

/// The field count most sampled body rows agree on. Frequency ties break
/// toward the wider shape so the result never depends on map iteration order.
private func modalWidth(_ rows: [[CellSlot]]) -> Int {
    var tally: [Int: Int] = [:]
    for row in rows {
        tally[row.count, default: 0] += 1
    }
    return tally.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key ?? 0
}

/// A slot's text. Covered positions and cells holding anything but paragraphs
/// yield nothing: neither is a plain value, and both then read as empty.
private func slotText(_ slot: CellSlot) -> String {
    guard case .origin(let cell) = slot else { return "" }
    var out = ""
    for block in cell.blocks {
        guard case .paragraph(let inlines) = block else { return "" }
        if !out.isEmpty { out += "\n" }
        out += inlinesToPlainText(inlines)
    }
    return out
}

/// Case- and padding-insensitive form used to compare a label against the
/// values below it.
private func fold(_ value: String) -> String {
    value.rustTrim().rustLowercased()
}

/// The kind at least `dominanceNum`/`dominanceDen` of the values share, if
/// any. Values are non-empty, so they all classify.
private func dominantKind(_ values: [String]) -> Kind? {
    [Kind.number, .bool, .date, .text].first { kind in
        let n = values.count(where: { classify($0) == kind })
        return n * dominanceDen >= values.count * dominanceNum
    }
}

/// Classify one value; `nil` when it is blank and carries no type at all.
private func classify(_ value: String) -> Kind? {
    let value = value.rustTrim()
    if value.isEmpty { return nil }
    if isNumber(value) { return .number }
    if ["true", "false", "yes", "no"].contains(fold(value)) { return .bool }
    if isTemporal(value) { return .date }
    return .text
}

/// A numeric literal as data files write them: sign, digit grouping, either
/// decimal convention, exponent, and a percent suffix. Which convention a
/// value uses does not matter here, only that it is a number.
private func isNumber(_ value: String) -> Bool {
    var value = Substring(value)
    if value.hasSuffix("%") { value = value.dropLast() }
    let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.filter { c in
        !(c == "," || c == " " || c == "_" || c == "\u{a0}")
    }))
    // A number here has digits in it (`inf`/`NaN` don't count).
    return cleaned.unicodeScalars.contains(where: \.isAsciiDigit) && parsesAsRustF64(cleaned)
}

/// A numeric date triple in any field order, optionally followed by a time,
/// or a bare clock time. Month names stay text: a column of them is a column
/// of labels, and it would cast the same vote either way.
private func isTemporal(_ value: String) -> Bool {
    let (date, time) = splitOnce(value, separators: ["T", " "]) ?? (value, "")
    // Fractional seconds and a trailing zone marker are not part of the shape.
    var timeTrimmed = Substring(time)
    while timeTrimmed.hasSuffix("Z") { timeTrimmed = timeTrimmed.dropLast() }
    let timeShape = timeTrimmed.split(separator: ".", omittingEmptySubsequences: false)
        .first.map(String.init) ?? ""
    func isClock(_ t: String) -> Bool {
        let groups = digitGroups(t, separators: [":"])
        return groups == 2 || groups == 3
    }
    if digitGroups(date, separators: ["-", "/", "."]) == 3 {
        return timeShape.isEmpty || isClock(timeShape)
    }
    return timeShape.isEmpty && isClock(date)
}

/// Rust `str::split_once` over the first occurrence of any listed separator.
private func splitOnce(_ value: String, separators: [Unicode.Scalar]) -> (String, String)? {
    let scalars = Array(value.unicodeScalars)
    guard let i = scalars.firstIndex(where: { separators.contains($0) }) else { return nil }
    return (
        String(String.UnicodeScalarView(scalars[..<i])),
        String(String.UnicodeScalarView(scalars[(i + 1)...]))
    )
}

/// How many components `value` has when split on the first of `seps` it
/// contains, or 0 unless every component is a short digit run.
private func digitGroups(_ value: String, separators: [Character]) -> Int {
    guard let sep = separators.first(where: { value.contains($0) }) else { return 0 }
    let parts = value.split(separator: sep, omittingEmptySubsequences: false)
    let shortDigits = { (p: Substring) in
        (1...4).contains(p.unicodeScalars.count) && p.unicodeScalars.allSatisfy(\.isAsciiDigit)
    }
    return parts.allSatisfy(shortDigits) ? parts.count : 0
}
