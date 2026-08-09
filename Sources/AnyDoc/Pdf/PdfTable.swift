/// The table model and its Markdown rendering, ported from pdf-inspector's
/// `tables/mod.rs` (the `Table` type) and `tables/format.rs`.
///
/// Rendering a grid of strings as a Markdown table is the easy half. The
/// other half is that the grid does not arrive clean: a cell whose text wraps
/// produces an extra row with the first column empty, a footnote sits in the
/// table's last row as though it were data, and a contents listing renders
/// terribly as a table at all. `pdfCleanTableCells` is most of this file, and
/// every one of its tests exists because some real document broke the
/// previous ones.

/// What a table is, which changes how it renders.
enum PdfTableKind {
    case data
    /// A contents listing, which renders as a flat text block rather than a
    /// table so page numbers stay beside their titles.
    case tableOfContents
}

/// A detected table.
///
/// `kind` is supplied rather than derived: the reference classifies it with
/// `is_table_of_contents`, three sub-classifiers living with the heuristic
/// detector, which this port has not reached. Both kinds render correctly
/// here — what is missing is deciding which one a grid *is*.
struct PdfTable {
    /// Column boundaries, as x positions.
    var columns: [Float] = []
    /// Row boundaries, as y positions, descending.
    var rows: [Float] = []
    /// Cell text, indexed row-major.
    var cells: [[String]] = []
    /// Indices of the text items that fell inside.
    var itemIndices: [Int] = []
    var kind: PdfTableKind = .data
}

/// Render a table as Markdown.
///
/// The data form is deliberately compact — no padding, minimal separators —
/// because the reference's primary consumer is a model rather than a reader.
func pdfTableToMarkdown(_ table: PdfTable) -> String {
    guard let firstRow = table.cells.first, !firstRow.isEmpty else { return "" }

    // A contents listing renders from the *raw* cells: the continuation
    // merging below collapses separate entries whose sub-entries leave the
    // first column empty.
    if case .tableOfContents = table.kind {
        return pdfFormatTocAsList(table.cells, footnotes: [])
    }

    let (cleaned, footnotes) = pdfCleanTableCells(table.cells)
    guard let header = cleaned.first else { return "" }
    let columnCount = header.count

    var output = ""
    for (index, row) in cleaned.enumerated() {
        output += "|"
        for cell in row { output += cell + "|" }
        output += "\n"
        if index == 0 {
            output += "|" + String(repeating: "---|", count: columnCount) + "\n"
        }
    }
    if !footnotes.isEmpty {
        output += "\n"
        for footnote in footnotes { output += footnote + "\n" }
    }
    return output
}

/// Render a contents listing as one line per row.
///
/// Non-empty cells join with spaces, and a trailing page number is separated
/// by a tab so it stays beside its title instead of being pulled into a
/// column of its own by a column-aware reader.
func pdfFormatTocAsList(_ cells: [[String]], footnotes: [String]) -> String {
    var output = ""
    for row in cells {
        let trimmed = row.map { $0.rustTrim() }
        guard let lastFilled = trimmed.lastIndex(where: { !$0.isEmpty }) else { continue }

        let lastCell = trimmed[lastFilled]
        let titleCells: ArraySlice<String>
        let trailing: String?
        if pdfIsPageNumberCell(lastCell), lastFilled > 0 {
            titleCells = trimmed[..<lastFilled]
            trailing = lastCell
        } else {
            titleCells = trimmed[...lastFilled]
            trailing = nil
        }

        // A dots-only cell is a leader, not part of the entry's name.
        let title = titleCells.filter { !$0.isEmpty && !pdfIsDotsOnly($0) }.joined(separator: " ")
        if title.isEmpty, trailing == nil { continue }

        output += title
        if let trailing {
            if !title.isEmpty { output += "\t" }
            output += trailing
        }
        output += "\n"
    }
    if !footnotes.isEmpty {
        output += "\n"
        for footnote in footnotes { output += footnote + "\n" }
    }
    return output
}

// MARK: - cell predicates

/// The value of a canonical lowercase roman numeral, if the token is one.
///
/// Canonical: the value has to round-trip, so `iiii` is rejected where `iv`
/// is accepted.
func pdfCanonicalRomanValue(_ token: String) -> UInt32? {
    let lower = token.rustTrim().asciiLowercased()
    guard !lower.isEmpty, lower.utf8.count <= 8,
        lower.unicodeScalars.allSatisfy({ "ivxlc".unicodeScalars.contains($0) })
    else { return nil }

    var total = 0
    var previous = 0
    for scalar in lower.unicodeScalars.reversed() {
        let value: Int
        switch scalar {
        case "i": value = 1
        case "v": value = 5
        case "x": value = 10
        case "l": value = 50
        case "c": value = 100
        default: return nil
        }
        if value < previous {
            total -= value
        } else {
            total += value
            previous = value
        }
    }
    guard total > 0, let value = UInt32(exactly: total) else { return nil }
    return pdfRomanLowercase(value) == lower ? value : nil
}

/// A value as a lowercase roman numeral, for the round-trip check.
private func pdfRomanLowercase(_ value: UInt32) -> String {
    let table: [(UInt32, String)] = [
        (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
        (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
    ]
    var remaining = value
    var result = ""
    for (amount, numeral) in table {
        while remaining >= amount {
            result += numeral
            remaining -= amount
        }
    }
    return result
}

/// Whether a cell looks like a page number: short digit tokens, canonical
/// roman numerals, or the dashed section-page forms technical manuals use
/// (`5-21`, `A-1`, `TC-2`).
func pdfIsPageNumberCell(_ cell: String) -> Bool {
    let tokens = cell.rustSplitWhitespace()
    guard !tokens.isEmpty else { return false }
    return tokens.allSatisfy { token in
        let text = String(token)
        // Byte length, as in the reference.
        if text.isEmpty || text.utf8.count > 8 { return false }
        if text.unicodeScalars.allSatisfy(pdfIsAsciiDigit) { return text.utf8.count <= 4 }
        if pdfCanonicalRomanValue(text) != nil { return true }
        return text.unicodeScalars.allSatisfy {
            pdfIsAsciiDigit($0) || pdfIsAsciiUppercase($0) || $0 == "-"
        } && text.unicodeScalars.contains(where: pdfIsAsciiDigit)
    }
}

private func pdfIsAsciiDigit(_ scalar: Unicode.Scalar) -> Bool { scalar >= "0" && scalar <= "9" }
private func pdfIsAsciiUppercase(_ scalar: Unicode.Scalar) -> Bool {
    scalar >= "A" && scalar <= "Z"
}

/// Whether the cell is nothing but leader dots.
func pdfIsDotsOnly(_ cell: String) -> Bool {
    let trimmed = cell.rustTrim()
    let dots = trimmed.unicodeScalars.count(where: { $0 == "." })
    return dots >= 3
        && trimmed.unicodeScalars.allSatisfy { $0 == "." || $0.properties.isWhitespace }
}

/// Whether the first alphanumeric character is uppercase.
private func pdfStartsWithUppercaseWord(_ cell: String) -> Bool {
    cell.unicodeScalars.first(where: { $0.properties.isAlphabetic || pdfIsAsciiDigit($0) })
        .map(\.properties.isUppercase) ?? false
}

private func pdfStartsWithUppercaseAlpha(_ cell: String) -> Bool {
    cell.unicodeScalars.first(where: \.properties.isAlphabetic).map(\.properties.isUppercase)
        ?? false
}

private func pdfStartsWithLowercaseAlpha(_ cell: String) -> Bool {
    cell.unicodeScalars.first(where: \.properties.isAlphabetic).map(\.properties.isLowercase)
        ?? false
}

/// Whether the cell opens with a short numbered label — `1.`, `12)`, `3-`.
private func pdfStartsWithNumberedLabel(_ cell: String) -> Bool {
    let trimmed = Array(cell.rustTrimStart().unicodeScalars)
    let digits = trimmed.prefix(while: pdfIsAsciiDigit).count
    guard digits > 0, digits <= 3, digits < trimmed.count else { return false }
    return ".)-:".unicodeScalars.contains(trimmed[digits])
}

/// Whether the cell opens with a dotted hierarchical label — `6.2`, `6.2.1`.
private func pdfStartsWithHierarchicalNumberedLabel(_ cell: String) -> Bool {
    let firstToken = cell.rustSplitWhitespace().first.map(String.init) ?? ""
    var token = Substring(firstToken)
    while let last = token.last, ".):-".contains(last) { token = token.dropLast() }
    let levels = token.split(separator: ".", omittingEmptySubsequences: false)
    guard (2...4).contains(levels.count) else { return false }
    return levels.allSatisfy {
        !$0.isEmpty && $0.utf8.count <= 3 && $0.unicodeScalars.allSatisfy(pdfIsAsciiDigit)
    }
}

/// How many whitespace-separated words contain a letter.
private func pdfAlphaWordCount(_ cell: String) -> Int {
    cell.rustSplitWhitespace().count { $0.unicodeScalars.contains(where: \.properties.isAlphabetic) }
}

/// Whether the cell reads as a short entry label rather than prose.
private func pdfLooksLikeCompactEntryLabel(_ cell: String) -> Bool {
    let trimmed = cell.rustTrim()
    guard trimmed.utf8.count >= 3, trimmed.utf8.count <= 80 else { return false }
    guard pdfStartsWithUppercaseAlpha(trimmed) || pdfStartsWithNumberedLabel(trimmed) else {
        return false
    }
    if let last = trimmed.last, ".,;:".contains(last) { return false }
    return (1...6).contains(pdfAlphaWordCount(trimmed))
}

/// Whether the cell reads as a bare section heading — letters only, title
/// case, a handful of words.
private func pdfLooksLikePlainSectionLabel(_ cell: String) -> Bool {
    let trimmed = cell.rustTrim()
    guard trimmed.utf8.count >= 4, trimmed.utf8.count <= 40 else { return false }
    if let last = trimmed.last, ".,;:".contains(last) { return false }
    if trimmed.unicodeScalars.contains(where: pdfIsAsciiDigit) { return false }
    // A short all-caps token is an abbreviation, not a section name.
    if trimmed.utf8.count <= 4, trimmed.unicodeScalars.allSatisfy({ !$0.properties.isLowercase }) {
        return false
    }
    return trimmed.unicodeScalars.allSatisfy {
        $0.properties.isAlphabetic || $0.properties.isWhitespace || $0 == "&" || $0 == "/"
            || $0 == "-"
    } && pdfStartsWithUppercaseAlpha(trimmed) && (1...4).contains(pdfAlphaWordCount(trimmed))
}

/// Whether the cell breaks off mid-phrase, which means the next row continues
/// it.
private func pdfEndsLikeIncompletePhrase(_ cell: String) -> Bool {
    let lower = cell.rustTrimEnd().asciiLowercased()
    return lower.hasSuffix(" and") || lower.hasSuffix(" or") || lower.hasSuffix(",")
        || lower.hasSuffix("-") || lower.hasSuffix("/")
}

/// Whether the cell opens a footnote row: `(1)`, `2)`, or `Note:`.
func pdfIsFootnoteRow(_ text: String) -> Bool {
    let trimmed = text.rustTrim()

    if trimmed.hasPrefix("("), trimmed.utf8.count >= 2 {
        let inside = trimmed.dropFirst()
        if let close = inside.firstIndex(of: ")") {
            let number = inside[..<close]
            if number.unicodeScalars.allSatisfy(pdfIsAsciiDigit) { return true }
        }
    }
    if trimmed.utf8.count >= 2, let paren = trimmed.firstIndex(of: ")") {
        let number = trimmed[..<paren]
        if !number.isEmpty, number.unicodeScalars.allSatisfy(pdfIsAsciiDigit) { return true }
    }
    let lower = trimmed.rustLowercased()
    return lower.hasPrefix("note:") || lower.hasPrefix("notes:")
}

// MARK: - cleanup

/// Merge continuation rows, pull footnotes out, and drop empty rows.
///
/// A cell whose text wraps produces a row with the first column empty and the
/// overflow beside it — but so does a data row with a spanned first column, a
/// short sub-header, and a hierarchical sub-entry, and none of those may be
/// merged away. The tests below are the reference's, each distinguishing one
/// of those cases from a genuine continuation.
func pdfCleanTableCells(_ cells: [[String]]) -> (rows: [[String]], footnotes: [String]) {
    var cleaned: [[String]] = []
    var footnotes: [String] = []

    for row in cells {
        if row.allSatisfy({ $0.rustTrim().isEmpty }) { continue }

        let firstCell = row.first.map { $0.rustTrim() } ?? ""
        if pdfIsFootnoteRow(firstCell) {
            footnotes.append(
                row.map { $0.rustTrim() }.filter { !$0.isEmpty }.joined(separator: " "))
            continue
        }

        let columnCount = row.count
        let filledCells = row.count(where: { !$0.rustTrim().isEmpty })
        let laterCells = row.dropFirst().map { $0.rustTrim() }.filter { !$0.isEmpty }

        // One short value beside an empty first column is a sub-header like
        // `JAN`, not overflow.
        let isShortSubheader = laterCells.count == 1 && laterCells[0].utf8.count <= 5
        // Several short numeric values are a data row with a spanned first
        // column; a continuation carries longer descriptive text.
        let averageLength =
            laterCells.isEmpty
            ? 0
            : Float(laterCells.map { $0.utf8.count }.reduce(0, +)) / Float(laterCells.count)
        let numericCells = laterCells.count(where: { cell in
            cell.unicodeScalars.allSatisfy {
                pdfIsAsciiDigit($0) || $0 == "." || $0 == "-" || $0 == "," || $0 == " "
            }
        })
        let looksLikeDataRow =
            laterCells.count >= 2 && averageLength <= 10 && numericCells > laterCells.count / 2

        let uppercaseLeading = laterCells.count(where: pdfStartsWithUppercaseWord)
        let firstFilledColumn = row.firstIndex(where: { !$0.rustTrim().isEmpty })
        let firstFilledCell = firstFilledColumn.map { row[$0].rustTrim() } ?? ""
        let titleLikeLaterCells =
            firstFilledColumn.map { index in
                row.dropFirst(index + 1).map { $0.rustTrim() }
                    .count(where: { !$0.isEmpty && pdfStartsWithUppercaseAlpha($0) })
            } ?? 0
        let previousFirstCell = cleaned.last?.first.map { $0.rustTrim() } ?? ""
        let previousFirstCellEmpty = cleaned.last?.first.map { $0.rustTrim().isEmpty } ?? false
        let headerFilled =
            cleaned.first.map { $0.count(where: { !$0.rustTrim().isEmpty }) } ?? columnCount

        let looksLikeSpanningFirstColumnRow =
            firstCell.isEmpty && row.count >= 4 && laterCells.count == row.count - 1
            && uppercaseLeading >= max(laterCells.count - 1, 0)

        // A hierarchical table blanks column 0 on its sub-rows and starts a
        // compact label in column 1. A wrapped continuation instead starts
        // mid-sentence, so those stay mergeable.
        let looksLikeHierarchicalSubrow =
            firstCell.isEmpty && firstFilledColumn == 1
            && pdfLooksLikeCompactEntryLabel(firstFilledCell)
            && ((row.count == 2 && pdfStartsWithHierarchicalNumberedLabel(firstFilledCell))
                || (row.count >= 3 && laterCells.count >= 2 && titleLikeLaterCells > 0)
                || (laterCells.count == 1 && row.count >= 3 && previousFirstCellEmpty
                    && pdfAlphaWordCount(firstFilledCell) >= 2))

        let looksLikeNewFirstColumnEntry =
            !firstCell.isEmpty
            && (pdfStartsWithNumberedLabel(firstCell) || pdfStartsWithUppercaseAlpha(firstCell))
            && filledCells >= 2 && laterCells.contains(where: pdfLooksLikeCompactEntryLabel)

        let looksLikeSectionLabelRow =
            !firstCell.isEmpty && filledCells == 1 && headerFilled >= 3
            && pdfLooksLikePlainSectionLabel(firstCell)

        let isClassicContinuation =
            firstCell.isEmpty && !laterCells.isEmpty && !isShortSubheader && !looksLikeDataRow
            && !looksLikeSpanningFirstColumnRow && !looksLikeHierarchicalSubrow
            && cleaned.count > 1

        // Overflow also shows up as a row with far fewer filled cells than
        // the header. Wide tables demand at most half, narrow ones merely
        // fewer, which keeps ordinary rows of a wide table intact.
        let previousFilled = cleaned.last.map { $0.count(where: { !$0.rustTrim().isEmpty }) } ?? 0
        let maximumFilledForMerge = headerFilled >= 5 ? headerFilled / 2 : max(headerFilled - 1, 0)
        let continuesWrappedLabel =
            !firstCell.isEmpty && pdfStartsWithLowercaseAlpha(firstCell)
            && pdfEndsLikeIncompletePhrase(previousFirstCell)
        let isWrappedContinuation =
            cleaned.count > 1 && filledCells <= maximumFilledForMerge
            && (previousFilled > filledCells
                || (continuesWrappedLabel && previousFilled >= filledCells))
            && !looksLikeDataRow && !looksLikeSpanningFirstColumnRow
            && !looksLikeHierarchicalSubrow && !looksLikeNewFirstColumnEntry
            && !looksLikeSectionLabelRow && !isShortSubheader

        if isClassicContinuation || isWrappedContinuation, !cleaned.isEmpty {
            let target = cleaned.count - 1
            for (column, cell) in row.enumerated() {
                let text = cell.rustTrim()
                guard !text.isEmpty, column < cleaned[target].count else { continue }
                if !cleaned[target][column].isEmpty { cleaned[target][column] += " " }
                cleaned[target][column] += text
            }
        } else {
            cleaned.append(row.map { $0.rustTrim() })
        }
    }
    return (cleaned, footnotes)
}
