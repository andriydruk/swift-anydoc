/// Layout reconstruction: positioned runs back into lines of text.
///
/// A PDF says where each glyph goes, not what a line or a word is. Recovering
/// them is heuristic, and the heuristics ported here are the core of
/// pdf-inspector's: group runs whose baselines agree, order each line left to
/// right, and decide from the horizontal gap whether two runs are one word or
/// two.
///
/// Multi-column detection, newspaper layout and XY-cut splitting live in
/// `PdfDetectColumns.swift` and the files it draws on (waves 61–65). This
/// file still groups a single column's runs into lines; wiring the column
/// regions into that grouping is the remaining step.

/// A run of text after layout, with the geometry the joiner needs.
struct PdfLayoutItem {
    var text: String
    var x: Float
    var y: Float
    var width: Float
    var fontSize: Float
    var fontName: String
    /// Resolved from the font's name and descriptor when the item is built;
    /// see `PdfFontStyle.swift`. Held per item rather than looked up per
    /// font at write time, because underline is not a font property at all
    /// and the writer has to weigh all three together.
    var isBold = false
    var isItalic = false
    /// Set by geometric detection, not by anything the font declares: a PDF
    /// draws an underline as a separate path. See `PdfUnderline.swift`.
    var isUnderline = false
    /// Detected the same way, and — as in the reference — never rendered.
    var isStrikeout = false
    /// An image placeholder rather than text. Column detection excludes
    /// these, since an image's left edge would otherwise count toward the
    /// projection profile. Nothing sets this yet — image placeholders are
    /// not extracted — so it stands in for the reference's `ItemType::Image`
    /// until they are.
    var isImage = false
    /// The marked-content id this item was drawn under, which is what links
    /// it to a node of the structure tree.
    ///
    /// Nothing sets this yet: the extractor's `BDC`/`EMC` tracking is not
    /// ported, so it is always `nil` and the struct-tree table detector finds
    /// no items on a real document. The detector itself is complete and
    /// probed; this is the one piece it waits on.
    var mcid: Int?
}

/// Runs that share a baseline, ordered left to right.
struct PdfTextLine {
    var items: [PdfLayoutItem]
    /// The line's baseline.
    var y: Float

    /// The leftmost edge of the line.
    var minX: Float { items.map(\.x).min() ?? 0 }
    /// The largest font on the line, which is what heading detection reads.
    var maxFontSize: Float { items.map(\.fontSize).max() ?? 0 }
}

/// Baselines within this many points are the same line. Runs on one line can
/// differ slightly through sub/superscript rise and rounding.
private let baselineTolerance: Float = 3.0

/// Group runs into lines and order them for reading.
///
/// Runs are sorted by descending y (PDF's origin is bottom-left, so that is
/// top to bottom) and then by x. Sorting rather than trusting content order
/// is what handles a writer that jumps backwards to place a glyph from
/// another font — which real documents do.
/// Text runs as layout items, before any grouping.
func pdfLayoutItems(_ runs: [PdfTextRun]) -> [PdfLayoutItem] {
    runs.map {
        PdfLayoutItem(
            text: $0.text, x: $0.x, y: $0.y, width: $0.width, fontSize: $0.fontSize,
            fontName: $0.fontName, mcid: $0.mcid)
    }
}

func pdfGroupIntoLines(_ runs: [PdfTextRun]) -> [PdfTextLine] {
    pdfGroupIntoLines(pdfLayoutItems(runs))
}

func pdfGroupIntoLines(_ items: [PdfLayoutItem]) -> [PdfTextLine] {
    guard !items.isEmpty else { return [] }

    // Sort top to bottom, then left to right. `sorted` is stable, so runs
    // that agree on both keys keep content order.
    let sorted = items.enumerated().sorted { lhs, rhs in
        if lhs.element.y != rhs.element.y { return lhs.element.y > rhs.element.y }
        if lhs.element.x != rhs.element.x { return lhs.element.x < rhs.element.x }
        return lhs.offset < rhs.offset
    }.map(\.element)

    var lines: [PdfTextLine] = []
    for item in sorted {
        // Only the line in progress can absorb the run: the sort means any
        // earlier line is already above this one.
        if var last = lines.last, abs(last.y - item.y) < baselineTolerance {
            last.items.append(item)
            lines[lines.count - 1] = last
            continue
        }
        lines.append(PdfTextLine(items: [item], y: item.y))
    }
    // Within a line the sort already ordered by x.
    return lines
}

/// The text of a line, inserting a space wherever two runs are separate
/// words.
func pdfLineText(_ line: PdfTextLine) -> String {
    var result = ""
    var previous: PdfLayoutItem?
    for item in line.items {
        let trimmed = item.text.trimmingCharactersInPdfWhitespace()
        if trimmed.isEmpty {
            // An all-space run still marks a word boundary.
            if !result.isEmpty, !result.hasSuffix(" "), !item.text.isEmpty {
                result += " "
            }
            continue
        }
        if let previous, !result.isEmpty {
            if pdfNeedsSpace(previous, item, result) { result += " " }
        }
        result += trimmed
        previous = item
    }
    return result
}

/// Whether a space belongs between two runs.
func pdfNeedsSpace(_ previous: PdfLayoutItem, _ current: PdfLayoutItem, _ soFar: String) -> Bool {
    // Text already ending in a space needs no second one.
    if soFar.hasSuffix(" ") { return false }
    // An explicit space on either run *is* the word boundary. The runs are
    // trimmed before joining, so this has to put the space back rather than
    // conclude one is already there — otherwise a boundary the writer stated
    // outright is the one case that gets dropped.
    if previous.text.hasSuffix(" ") || current.text.hasPrefix(" ") { return true }

    let previousLast = previous.text.trimmingCharactersInPdfWhitespace().unicodeScalars.last
    let currentFirst = current.text.trimmingCharactersInPdfWhitespace().unicodeScalars.first

    // A hyphen binds the words it joins.
    if soFar.hasSuffix("-") { return false }
    if let currentFirst, currentFirst == "-" { return false }

    // Punctuation that follows its word without a space.
    if let currentFirst {
        switch currentFirst {
        case ".", ",", ";", "!", "?", ")", "]", "}", "'":
            return false
        default:
            break
        }
    }
    // A colon before a value takes a space, the label:value shape.
    if let previousLast, previousLast == ":", let currentFirst,
        currentFirst.properties.isAlphabetic || currentFirst.isAsciiDigit
    {
        return true
    }

    // A sub- or superscript sits at a different size and baseline and is not
    // a separate word.
    if previous.fontSize > 0, current.fontSize > 0 {
        let ratio = current.fontSize / previous.fontSize
        let inverse = previous.fontSize / current.fontSize
        let verticalOffset = abs(current.y - previous.y)
        if verticalOffset > 1.0, ratio < 0.85 || inverse < 0.85 { return false }
    }

    // Without a measured width there is no gap to reason about, so fall back
    // to joining — the reference does the same.
    guard previous.width > 0 else { return false }
    let gap =
        previous.x <= current.x
        ? current.x - (previous.x + previous.width)
        : previous.x - (current.x + current.width)
    let fontSize = previous.fontSize > 0 ? previous.fontSize : current.fontSize
    guard fontSize > 0 else { return false }

    // A column-scale gap, or a large overlap, is never a word join.
    if gap > fontSize * 3.0 || gap < -fontSize { return true }

    // Digits and their separators that sit close together are one number.
    if let previousLast, let currentFirst {
        let previousNumeric =
            previousLast.isAsciiDigit || previousLast == "," || previousLast == "."
        let currentNumeric =
            currentFirst.isAsciiDigit || currentFirst == "%" || currentFirst == "."
        if previousNumeric && currentNumeric {
            return !(gap > -fontSize && gap < fontSize * 0.3)
        }
        if previousLast == "+" || previousLast == "-", currentFirst.isAsciiDigit {
            return !(gap > -fontSize && gap < fontSize * 0.3)
        }
    }

    let previousChars = previous.text.trimmingCharactersInPdfWhitespace().unicodeScalars.count
    let currentChars = current.text.trimmingCharactersInPdfWhitespace().unicodeScalars.count
    // A single-character fragment beside a longer one is usually a split
    // word ("b" + "illion"), so it joins across a wider gap.
    if (previousChars == 1) != (currentChars == 1) {
        return !(gap < fontSize * 0.20)
    }
    // Per-glyph positioning: intra-word gaps are near zero, word boundaries
    // around 0.15 em. Digits get a looser bound, since spaces inside numbers
    // are rare.
    if previousChars == 1, currentChars == 1 {
        if let previousLast, let currentFirst {
            let previousNumeric =
                previousLast.isAsciiDigit || ",.%+-".unicodeScalars.contains(previousLast)
            let currentNumeric =
                currentFirst.isAsciiDigit || ",.%".unicodeScalars.contains(currentFirst)
            if previousNumeric && currentNumeric { return !(gap < fontSize * 0.25) }
        }
        return !(gap < fontSize * 0.10)
    }
    return !(gap < fontSize * 0.10)
}

extension String {
    /// Trim the whitespace PDF text carries, which is ASCII plus the
    /// no-break space producers emit for justified text.
    fileprivate func trimmingCharactersInPdfWhitespace() -> String {
        var view = Substring(self)
        while let first = view.unicodeScalars.first, first.properties.isWhitespace {
            view = view.dropFirst()
        }
        while let last = view.unicodeScalars.last, last.properties.isWhitespace {
            view = view.dropLast()
        }
        return String(view)
    }
}
