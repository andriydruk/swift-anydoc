/// Filling a detected grid with text, ported from `assign_items_to_grid` in
/// pdf-inspector's `tables/detect_rects.rs`.
///
/// Both ruled strategies end up here: once the cell borders have given a set
/// of column and row *edges*, every text item has to be dropped into the cell
/// it falls in and each cell's items joined into one string.
///
/// The edges are boundaries, not centres — `n` edges bound `n - 1` cells —
/// which is what distinguishes this from the heuristic path's
/// `pdfFindColumnIndex`, where the columns are positions and an item goes to
/// the nearest.

/// How far outside its cell an item's centre may sit and still belong to it.
/// A glyph nudged over a border by rounding should not fall out of the table.
private let pdfGridAssignSlack: Float = 2.0

/// Assign items to grid cells and join each cell's text.
///
/// An item is placed by the centre of its horizontal extent but by its
/// *baseline* vertically — not its vertical centre — because a cell's row is
/// decided by where the text sits, and a tall glyph should not migrate upward.
///
/// Returns the cell text and the indices of the items consumed, so the caller
/// can mark them claimed.
func pdfAssignItemsToGrid(
    _ items: [PdfLayoutItem], columnEdges: [Float], rowEdges: [Float]
) -> (cells: [[String]], itemIndices: [Int]) {
    guard columnEdges.count >= 2, rowEdges.count >= 2 else { return ([], []) }
    let columnCount = columnEdges.count - 1
    let rowCount = rowEdges.count - 1

    var cellItems = Array(
        repeating: Array(repeating: [(index: Int, item: PdfLayoutItem)](), count: columnCount),
        count: rowCount)
    var indices: [Int] = []

    for (index, item) in items.enumerated() {
        let centreX = item.x + item.width / 2
        let baseline = item.y

        let column = (0..<columnCount).first {
            centreX >= columnEdges[$0] - pdfGridAssignSlack
                && centreX <= columnEdges[$0 + 1] + pdfGridAssignSlack
        }
        // Row edges run down the page, so the *next* edge is the lower bound.
        let row = (0..<rowCount).first {
            baseline >= rowEdges[$0 + 1] - pdfGridAssignSlack
                && baseline <= rowEdges[$0] + pdfGridAssignSlack
        }

        guard let column, let row else { continue }
        cellItems[row][column].append((index, item))
        indices.append(index)
    }

    let cells = cellItems.map { row in
        row.map { entries -> String in
            // Within a cell: down the page, then left to right — a wrapped
            // cell reads in its own order.
            let sorted = entries.sorted {
                $0.item.y != $1.item.y ? $0.item.y > $1.item.y : $0.item.x < $1.item.x
            }
            let joined = sorted.map { $0.item.text.rustTrim() }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return pdfRemoveInnerDelimiterSpaces(joined)
        }
    }
    return (cells, indices)
}

/// Close up a space that landed just inside a bracket.
///
/// Joining a cell's fragments with spaces puts one wherever the producer
/// happened to break the run, and a break beside a bracket reads as `( 12 )`.
/// Only the *inner* side is closed: `a (b)` keeps its space, `a ( b )` becomes
/// `a (b)`.
func pdfRemoveInnerDelimiterSpaces(_ text: String) -> String {
    let characters = Array(text)
    var result = ""
    result.reserveCapacity(characters.count)

    for (index, character) in characters.enumerated() {
        if character == " " {
            let afterOpen = result.hasSuffix("(") || result.hasSuffix("[") || result.hasSuffix("{")
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let beforeClose = next == ")" || next == "]" || next == "}"
            if afterOpen || beforeClose { continue }
        }
        result.append(character)
    }
    return result
}
