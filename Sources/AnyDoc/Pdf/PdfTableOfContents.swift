/// Telling a contents listing from a data table, ported from the classifier
/// cluster in pdf-inspector's `tables/detect_heuristic.rs`.
///
/// This closes the gap wave 14 left open: `PdfTable.kind` can now be derived
/// rather than supplied. It matters because the two render completely
/// differently — a contents listing becomes flat lines with the page number
/// on a tab, and rendering one as a Markdown table drifts the page numbers
/// into a column of their own.
///
/// Three independent signals, any of which is enough: an explicit dot leader,
/// a dotted section number with page numbers in the last column, or — with no
/// leader at all — a title column beside a column of ascending page numbers.
/// The last is the delicate one, because a two-column numeric data table
/// looks exactly like it until you check that the numbers *span* the
/// document.

/// Whether a grid of cells is a contents listing.
func pdfIsTableOfContents(_ cells: [[String]]) -> Bool {
    pdfIsDotLeaderToc(cells) || pdfIsTabularToc(cells) || pdfIsPageNumberToc(cells)
}

/// A page number's value: a short arabic integer or a canonical roman
/// numeral, the latter shared with the formatter so the two agree.
private func pdfPageNumberValue(_ token: String) -> UInt32? {
    let trimmed = token.rustTrim()
    guard !trimmed.isEmpty else { return nil }
    if trimmed.unicodeScalars.allSatisfy(pdfIsDigit), trimmed.utf8.count <= 4 {
        return UInt32(trimmed)
    }
    return pdfCanonicalRomanValue(trimmed)
}

private func pdfIsDigit(_ scalar: Unicode.Scalar) -> Bool { scalar >= "0" && scalar <= "9" }
private func pdfIsUppercaseAscii(_ scalar: Unicode.Scalar) -> Bool {
    scalar >= "A" && scalar <= "Z"
}
private func pdfHasLetter<S: StringProtocol>(_ text: S) -> Bool {
    text.unicodeScalars.contains(where: \.properties.isAlphabetic)
}

// MARK: - the page-number listing

/// A title column beside a column of ascending page numbers, with no leader
/// dots and no section numbers.
///
/// The hard case is telling this from a two-column numeric data table. The
/// tells, in order: contents have no header row, so the *first* row's last
/// cell is already a page number; the first column is mostly prose; the page
/// numbers mostly ascend; and — the strongest — real page numbers **span**
/// the document, because entries skip. A perfectly dense consecutive run is a
/// rank or ID column, and is only accepted when the titles read like
/// headings rather than short labels.
func pdfIsPageNumberToc(_ cells: [[String]]) -> Bool {
    let columnCount = cells.first?.count ?? 0
    // Contents are narrow: title, page, optionally a leader column.
    guard (2...3).contains(columnCount), cells.count >= 5 else { return false }
    let last = columnCount - 1

    // The actual first row, not the first non-empty one, so a blank header
    // cell still rejects.
    let firstLast = cells[0].count > last ? cells[0][last].rustTrim() : ""
    guard pdfPageNumberValue(firstLast) != nil else { return false }

    var filled: Int = 0
    var pageValues: [UInt32] = []
    for row in cells {
        let cell = row.count > last ? row[last].rustTrim() : ""
        if cell.isEmpty { continue }
        filled += 1
        if let value = pdfPageNumberValue(cell) { pageValues.append(value) }
    }
    guard filled >= 4, Float(pageValues.count) >= 0.7 * Float(filled) else { return false }

    // A prose first column, which rejects numeric-versus-numeric grids.
    let textFirst = cells.count(where: { $0.first.map(pdfHasLetter) ?? false })
    guard Float(textFirst) >= 0.6 * Float(cells.count) else { return false }

    guard pageValues.count >= 2 else { return false }
    let nonDecreasing = zip(pageValues, pageValues.dropFirst()).count { $1 >= $0 }
    guard Float(nonDecreasing) >= 0.7 * Float(pageValues.count - 1) else { return false }

    guard let minimum = pageValues.min(), let maximum = pageValues.max() else { return false }
    let span = maximum >= minimum ? maximum - minimum : 0
    // Entries skip pages, so the range exceeds the entry count.
    if span > UInt32(pageValues.count) { return true }

    let denseConsecutive =
        Int(span) + 1 == pageValues.count && Set(pageValues).count == pageValues.count
    // A narrow range with a gap or a repeat is still contents-like.
    if !denseConsecutive { return true }

    // A dense counter is contents only when the titles read like headings
    // rather than the short single-word labels a leaderboard uses.
    var totalWords = 0
    var titledRows = 0
    for cell in cells.compactMap(\.first) where pdfHasLetter(cell) {
        totalWords += cell.rustSplitWhitespace().count(where: pdfHasLetter)
        titledRows += 1
    }
    return titledRows > 0 && Float(totalWords) / Float(titledRows) >= 1.8
}

// MARK: - dot leaders

/// Any `Chapter 1 ........ 42` layout, in either of the two shapes a column
/// detector produces.
func pdfIsDotLeaderToc(_ cells: [[String]]) -> Bool {
    pdfHasStructuralDotLeader(cells) || pdfIsInlineLeaderIndex(cells)
}

/// Rows carrying a dedicated dots-only cell between a label and a page
/// number, which is the narrow two-or-three-column contents layout.
private func pdfHasStructuralDotLeader(_ cells: [[String]]) -> Bool {
    guard !cells.isEmpty else { return false }
    let structural = cells.count(where: pdfRowHasDotLeader)
    return Float(structural) / Float(cells.count) >= 0.3
}

/// A wide index where each cell holds a whole `label ... page` fragment,
/// because the column detector kept a multi-column index as single cells.
///
/// These render badly *both* ways — the column boundaries are arbitrary, and
/// each row holds several separate entries — so the reference flags them so
/// they fall back to the page's ordinary text flow.
func pdfIsInlineLeaderIndex(_ cells: [[String]]) -> Bool {
    var inline = 0
    var nonEmpty = 0
    for row in cells {
        for cell in row {
            let trimmed = cell.rustTrim()
            if trimmed.isEmpty { continue }
            nonEmpty += 1
            if pdfCellIsInlineLeader(trimmed) { inline += 1 }
        }
    }
    return nonEmpty >= 4 && Float(inline) / Float(nonEmpty) >= 0.25
}

/// Whether a row carries a dot leader, in either layout: a dedicated
/// dots-only cell with a label to its left and a page number to its right,
/// or a `Title ... ` cell whose leader is glued to the name.
private func pdfRowHasDotLeader(_ row: [String]) -> Bool {
    let hasPageNumber = row.contains(where: pdfRowCellIsPageNumber)

    for (index, cell) in row.enumerated() {
        let trimmed = cell.rustTrim()

        let dots = trimmed.unicodeScalars.count(where: { $0 == "." })
        // Byte length, as the reference measures it.
        let mostlyDots =
            dots >= 3 && dots > trimmed.utf8.count / 2
            && trimmed.unicodeScalars.allSatisfy { $0 == "." || $0.properties.isWhitespace }
        if mostlyDots {
            let hasLabelLeft = row[..<index].contains { cell in
                let text = cell.rustTrim()
                return !text.isEmpty && pdfHasLetter(text)
            }
            if hasLabelLeft, hasPageNumber { return true }
            continue
        }

        if hasPageNumber, pdfCellHasTrailingLeader(trimmed) { return true }
    }
    return false
}

/// Whether a cell ends in a leader run glued to a title.
///
/// A space before the dots rules out `etc...`, and requiring a letter rules
/// out a data row labelled `1973 ... `.
func pdfCellHasTrailingLeader(_ cell: String) -> Bool {
    let trimmed = cell.rustTrimEnd()
    guard trimmed.hasSuffix(".") else { return false }
    var withoutDots = Substring(trimmed)
    while withoutDots.hasSuffix(".") { withoutDots = withoutDots.dropLast() }
    let dotRun = trimmed.utf8.count - withoutDots.utf8.count
    guard dotRun >= 3 else { return false }
    return withoutDots.hasSuffix(" ") && pdfHasLetter(withoutDots.rustTrim())
}

/// Whether a cell is a page number *for leader purposes*: a short integer, a
/// `, `-separated list of them, or a dashed section-page id.
///
/// The separator has to be comma-*space*, which is what distinguishes a page
/// list like `18, 36, 107` from a thousands-separated `189,164`.
func pdfRowCellIsPageNumber(_ cell: String) -> Bool {
    let trimmed = cell.rustTrim()
    guard !trimmed.isEmpty else { return false }
    if pdfLooksLikeSectionPageId(trimmed) { return true }
    let parts = trimmed.components(separatedByString: ", ")
    return parts.allSatisfy {
        !$0.isEmpty && $0.utf8.count <= 4 && $0.unicodeScalars.allSatisfy(pdfIsDigit)
    }
}

/// Whether a cell is an index fragment — `text ... number`, or a bare
/// `... number` where the label landed in another column.
func pdfCellIsInlineLeader(_ cell: String) -> Bool {
    let trimmed = cell.rustTrim()
    let scalars = Array(trimmed.unicodeScalars)
    // The first run of three dots.
    var start: Int?
    if scalars.count >= 3 {
        for index in 0...(scalars.count - 3)
        where scalars[index] == "." && scalars[index + 1] == "." && scalars[index + 2] == "." {
            start = index
            break
        }
    }
    guard let start else { return false }

    let before = scalars[..<start]
    var afterIndex = start + 3
    // Any further dots belong to the leader.
    while afterIndex < scalars.count, scalars[afterIndex] == "." { afterIndex += 1 }
    let after = scalars[afterIndex...]

    // A space (or the cell's start) before the dots and a space or nothing
    // after, which blocks an intra-word ellipsis.
    let beforeOk = before.isEmpty || before.last == " "
    let afterOk = after.first == " " || after.isEmpty
    guard beforeOk, afterOk else { return false }

    let tail = String(String.UnicodeScalarView(after)).rustTrim()
    guard !tail.isEmpty else { return false }
    let tailNumeric =
        tail.unicodeScalars.allSatisfy {
            pdfIsDigit($0) || $0 == "," || $0 == " " || $0 == "." || $0 == "-" || $0 == "$"
        } && tail.unicodeScalars.contains(where: pdfIsDigit)
    guard tailNumeric else { return false }

    // Either a label precedes the leader, or the leader opens the cell —
    // both are legitimate index fragments.
    let beforeText = String(String.UnicodeScalarView(before))
    return pdfHasLetter(beforeText) || beforeText.rustTrim().isEmpty
}

// MARK: - the dot-less tabular listing

/// A tagged PDF's contents: a first column opening with a dotted section
/// number, and a last column of page numbers, with no leader dots at all.
func pdfIsTabularToc(_ cells: [[String]]) -> Bool {
    guard let firstRow = cells.first else { return false }
    let columnCount = firstRow.count
    guard columnCount >= 2, cells.count >= 4 else { return false }

    let sectionRows = cells.count(where: { row in
        row.first(where: { !$0.rustTrim().isEmpty })
            .map { pdfStartsWithSectionNumber($0.rustTrim()) } ?? false
    })

    let last = columnCount - 1
    var lastFilled = 0
    var lastPageNumbers = 0
    for row in cells {
        let cell = row.count > last ? row[last].rustTrim() : ""
        if cell.isEmpty { continue }
        lastFilled += 1
        let isPageNumbers = cell.rustSplitWhitespace().allSatisfy {
            !$0.isEmpty && $0.unicodeScalars.allSatisfy(pdfIsDigit)
        }
        if isPageNumbers { lastPageNumbers += 1 }
    }

    let sectionRatio = Float(sectionRows) / Float(cells.count)
    let pageRatio = lastFilled > 0 ? Float(lastPageNumbers) / Float(lastFilled) : 0
    return sectionRatio >= 0.6 && lastFilled >= 3 && pageRatio >= 0.7
}

/// A dashed section-page identifier: `5-21`, `A-1`, `B--3`, `TC-2`.
func pdfLooksLikeSectionPageId(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy { pdfIsDigit($0) || pdfIsUppercaseAscii($0) || $0 == "-" }
        && text.unicodeScalars.contains(where: pdfIsDigit)
}

/// Whether the leading token is a dotted section number — `1.2`, `4.3.1.2`.
/// A bare number is too ambiguous, so at least one dot is required.
func pdfStartsWithSectionNumber(_ text: String) -> Bool {
    guard let firstToken = text.rustSplitWhitespace().first else { return false }
    var token = firstToken
    while token.hasSuffix(".") { token = token.dropLast() }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard (2...6).contains(parts.count) else { return false }
    return parts.allSatisfy {
        !$0.isEmpty && $0.utf8.count <= 3 && $0.unicodeScalars.allSatisfy(pdfIsDigit)
    }
}

extension StringProtocol {
    /// Rust's `str::split` on a multi-character separator, which Foundation
    /// would otherwise be needed for.
    fileprivate func components(separatedByString separator: String) -> [String] {
        let haystack = Array(unicodeScalars)
        let needle = Array(separator.unicodeScalars)
        guard !needle.isEmpty, haystack.count >= needle.count else { return [String(self)] }
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        var index = 0
        while index < haystack.count {
            if index + needle.count <= haystack.count,
                Array(haystack[index..<(index + needle.count)]) == needle
            {
                parts.append(String(current))
                current = String.UnicodeScalarView()
                index += needle.count
            } else {
                current.append(haystack[index])
                index += 1
            }
        }
        parts.append(String(current))
        return parts
    }
}
