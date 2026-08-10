/// Building a single-column table from a vertical stack of boxes, ported from
/// `detect_stacked_box_table` in pdf-inspector's `tables/detect_rects.rs`.
///
/// Some documents present a list as a run of framed rows — each item in its
/// own box, stacked down the page. There are no columns at all, so none of
/// the grid strategies apply, but the boxes are real structure worth keeping.
///
/// The catch is that a stack of boxes is also what page decor looks like:
/// callout panels, sidebar frames, striped backgrounds behind ordinary prose.
/// So of the code here, roughly a fifth finds the stack and the rest argues
/// about whether it is a table — five separate ways of recognising prose
/// wearing a table's geometry.

/// A candidate row box: wide enough to hold a row, tall enough for one line
/// of text but not a whole panel.
private func pdfIsStackedBoxCandidate(_ rect: (x: Float, y: Float, width: Float, height: Float))
    -> Bool
{
    rect.width >= 100 && rect.height >= 8 && rect.height <= 80
}

/// The function words whose presence marks a cell as prose rather than a
/// label. The list is the reference's.
private let pdfProseWords: Set<String> = [
    "a", "an", "the", "of", "to", "is", "was", "are", "were", "be", "been", "in", "on", "at",
    "with", "for", "by", "as", "and", "or", "but", "this", "that", "these", "those", "from",
    "into", "has", "have", "had", "not", "it", "its", "their", "such", "shall", "which",
]

/// Whether a cell opens with a list marker — `1)`, `(ii)`, `a.`
func pdfHasListMarker(_ text: String) -> Bool {
    var trimmed = Substring(text.rustTrimStart())
    if trimmed.hasPrefix("(") { trimmed = trimmed.dropFirst() }
    let characters = Array(trimmed)
    let markerLength = characters.prefix { $0.isLetter || $0.isNumber }.count
    guard (1...3).contains(markerLength), markerLength < characters.count else { return false }
    let next = characters[markerLength]
    return next == ")" || next == "."
}

/// Build a single-column table from stacked boxes, or reject the cluster.
func pdfDetectStackedBoxTable(
    items: [PdfLayoutItem],
    groupRects: [(x: Float, y: Float, width: Float, height: Float)]
) -> PdfTable? {
    let candidates = groupRects.filter(pdfIsStackedBoxCandidate)

    // The row boxes are the largest family that agree on x and size;
    // backgrounds and decoration have their own geometry and stay out.
    var boxes: [(x: Float, y: Float, width: Float, height: Float)] = []
    for anchor in candidates {
        let family = candidates.filter {
            abs($0.x - anchor.x) <= 12 && abs($0.width - anchor.width) <= anchor.width * 0.15
                && abs($0.height - anchor.height) <= anchor.height * 0.3
        }
        if family.count > boxes.count { boxes = family }
    }
    guard boxes.count >= 3 else { return nil }

    // A box with something beside it at the same height is one column of a
    // wider structure — that belongs to the grid strategies, not here, where
    // it would collapse to a single column.
    let flanked = boxes.count(where: { box in
        let rectSibling = groupRects.contains { other in
            let overlap = min(box.y + box.height, other.y + other.height) - max(box.y, other.y)
            return other.height >= 8 && overlap > box.height * 0.5
                && (other.x + other.width <= box.x + 2 || other.x >= box.x + box.width - 2)
                && other.width >= 30
        }
        let textSibling = items.contains { item in
            let centreX = item.x + item.width / 2
            return item.y >= box.y - 2 && item.y <= box.y + box.height + 2
                && (centreX < box.x - 5 || centreX > box.x + box.width + 5) && item.width >= 10
        }
        return rectSibling || textSibling
    })
    guard flanked * 3 < boxes.count else { return nil }

    boxes.sort { $0.y > $1.y }
    // A border and a fill draw the same box twice.
    var deduped: [(x: Float, y: Float, width: Float, height: Float)] = []
    for box in boxes {
        if let last = deduped.last, abs(last.y - box.y) <= 3, abs(last.height - box.height) <= 6 {
            continue
        }
        deduped.append(box)
    }
    boxes = deduped
    guard boxes.count >= 3 else { return nil }

    // A genuine stack: boxes neither overlap nor leave a gap wider than a row.
    for (upper, lower) in zip(boxes, boxes.dropFirst()) {
        let upperBottom = upper.y
        let lowerTop = lower.y + lower.height
        if lowerTop > upperBottom + 4 { return nil }
        if upperBottom - lowerTop > max(upper.height, lower.height) { return nil }
    }

    var cells: [[String]] = []
    var itemIndices: [Int] = []
    var multiRunBoxes = 0
    for box in boxes {
        let inBox = items.enumerated().filter { _, item in
            let centreX = item.x + item.width / 2
            return item.y >= box.y - 2 && item.y <= box.y + box.height + 2 && centreX >= box.x
                && centreX <= box.x + box.width
        }.sorted {
            $0.element.y != $1.element.y
                ? $0.element.y > $1.element.y : $0.element.x < $1.element.x
        }
        guard !inBox.isEmpty else { return nil }

        // Horizontally separated runs on the *same baseline* mean
        // multi-column content that must not collapse into one column. Mixed
        // baselines are allowed: a boxed diagram row legitimately scatters
        // segments and still belongs to one row.
        var runs = 1
        for (previous, current) in zip(inBox, inBox.dropFirst()) {
            let a = previous.element
            let b = current.element
            if abs(a.y - b.y) <= 2, b.x - (a.x + a.width) > 15 { runs += 1 }
        }
        if runs >= 2 { multiRunBoxes += 1 }

        let text = inBox.map { $0.element.text.rustTrim() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty, text.count <= 120 else { return nil }
        itemIndices += inBox.map(\.offset)
        cells.append([text])
    }
    guard multiRunBoxes * 2 < boxes.count else { return nil }

    // Prose behind per-line stripes: sentence fragments read as long cells
    // dense in function words, where real list rows are short labels.
    let totalCharacters = cells.map { $0[0].count }.reduce(0, +)
    let meanCharacters = totalCharacters / max(cells.count, 1)
    let proseCells = cells.count(where: { row in
        row[0].asciiLowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .contains { pdfProseWords.contains(String($0)) }
    })
    if meanCharacters > 60, proseCells * 5 >= cells.count * 2 { return nil }

    // A sentence wrapping across boxes: a row ending in a comma, or a row
    // with no terminal punctuation followed by one starting lowercase. Real
    // label rows produce none of these, so even a couple is disqualifying.
    let continuations = zip(cells, cells.dropFirst()).count { previous, next in
        let a = previous[0].rustTrimEnd()
        let b = next[0].rustTrimStart()
        let stillOpen = !(a.last.map { ".:;!?)\"%".contains($0) } ?? false)
        let nextLower = b.first?.isLowercase ?? false
        return a.hasSuffix(",") || (stillOpen && nextLower)
    }
    if cells.count >= 2, continuations >= 2 || continuations * 4 >= cells.count - 1 { return nil }

    // Numbered items behind decorative stripes stay a list.
    let listRows = cells.count(where: { pdfHasListMarker($0[0]) })
    guard listRows * 2 < cells.count else { return nil }

    let columns = [boxes[0].x + boxes[0].width / 2]
    let rows = boxes.map { $0.y + $0.height / 2 }
    return PdfTable(columns: columns, rows: rows, cells: cells, itemIndices: itemIndices)
}
