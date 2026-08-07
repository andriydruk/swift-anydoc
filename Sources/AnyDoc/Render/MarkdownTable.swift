/// Table rendering over the canonical grid. Covered positions render as
/// blank cells (GFM has no span syntax); the grid invariant means the
/// renderer never synthesizes or duplicates columns.

private struct RenderedCell {
    var text: String
    var coveredSpan: Bool
}

func renderTable(_ table: Table, _ rc: RenderContext) -> String? {
    // Interior empty rows render as blank rows — they carry the source's
    // row coordinates; trailing blank rows are popped below.
    if table.grid.isEmpty {
        return nil
    }
    let fullWidth = table.grid.map(\.count).max() ?? 0
    var rendered: [[RenderedCell]] = table.grid.map { row in
        var cells: [RenderedCell] = row.map { slot in
            switch slot {
            case .origin(let cell):
                RenderedCell(text: renderCell(cell, rc), coveredSpan: false)
            case .covered:
                RenderedCell(text: "", coveredSpan: true)
            }
        }
        while cells.count < fullWidth {
            cells.append(RenderedCell(text: "", coveredSpan: false))
        }
        return cells
    }
    while rendered.count > 1,
        let last = rendered.last, last.allSatisfy({ $0.text.isEmpty && !$0.coveredSpan })
    {
        rendered.removeLast()
    }
    let width = rendered.map { row in
        row.lastIndex(where: { !$0.text.isEmpty || $0.coveredSpan }).map { $0 + 1 } ?? 0
    }.max() ?? 0
    if width == 0 {
        return nil
    }
    for i in rendered.indices {
        rendered[i].removeLast(rendered[i].count - min(rendered[i].count, width))
    }

    var out = ""
    // GFM tables always carry a delimiter row, so a table with no header row
    // of its own renders an empty one above the data.
    let header: [String]
    if table.headerRows >= 1, !rendered.isEmpty {
        header = rendered.removeFirst().map(\.text)
    } else {
        header = Array(repeating: "", count: width)
    }
    out += formatRow(header)
    out += "\n"
    out += formatRow(Array(repeating: "---", count: width))
    for row in rendered {
        out += "\n"
        out += formatRow(row.map(\.text))
    }
    return out
}

private func formatRow(_ cells: [String]) -> String {
    var s = "|"
    for cell in cells {
        s += " "
        s += cell
        s += " |"
    }
    return s
}

/// Flatten arbitrary block content into a single table-cell line.
func renderCell(_ cell: Cell, _ rc: RenderContext) -> String {
    var parts: [String] = []
    for block in cell.blocks {
        cellBlockText(block, rc, into: &parts)
    }
    // A cell's edge whitespace is padding the table's own padding would
    // swallow anyway, and spreadsheets carry it by the thousand.
    return parts
        .joined(separator: "<br>")
        .rustLines()
        .filter { !$0.isBlank }
        .map { $0.rustTrim() }
        .joined(separator: "<br>")
}

private func cellBlockText(_ block: Block, _ rc: RenderContext, into parts: inout [String]) {
    switch block {
    case .heading(_, _, let content):
        let t = renderInlines(content, .tableCell, rc)
        if !t.isBlank {
            parts.append("**\(t.rustTrim())**")
        }
    case .paragraph(let inlines):
        // Edge whitespace is preserved here and protected in `renderCell`;
        // sources that retain cell padding (spreadsheets, CSV) keep it in the
        // final output.
        let t = renderInlines(inlines, .tableCell, rc)
        if !t.isBlank {
            parts.append(t)
        }
    case .list(let list):
        for (i, item) in list.items.enumerated() {
            var inner: [String] = []
            for b in item.blocks {
                cellBlockText(b, rc, into: &inner)
            }
            let marker: String
            switch (item.markerLabel, list.marker) {
            case (.some(let label), _):
                marker = "\(escapeMarkerLabel(label, .tableCell)) "
            case (nil, .bullet):
                marker = "\u{2022} "
            case (nil, let kind):
                marker = "\(kind.label(list.start.saturatingAdding(UInt64(i)))) "
            }
            if !inner.isEmpty {
                parts.append("\(marker)\(inner.joined(separator: " "))")
            }
        }
    case .table(let table):
        // Keep empty cells in the join so values stay in their source
        // column positions.
        for row in table.grid {
            let cells: [String] = row.map { slot in
                switch slot {
                case .origin(let cell): renderCell(cell, rc)
                case .covered: ""
                }
            }
            if cells.contains(where: { !$0.isEmpty }) {
                parts.append(cells.joined(separator: " / "))
            }
        }
    case .blockQuote(let blocks):
        for b in blocks {
            cellBlockText(b, rc, into: &parts)
        }
    case .codeBlock(_, let text):
        let t = text.rustTrim()
        if !t.isEmpty {
            var s = ""
            pushCodeSpan(t, into: &s)
            parts.append(s)
        }
    case .rule:
        break
    }
}
