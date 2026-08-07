/// Textual extraction of DrawingML rich objects shared by DOCX and PPTX:
/// charts (title, axis titles, cached series data) and SmartArt diagram
/// data (text points).

enum DrawingMl {
    /// A chart part as blocks: bold title paragraph plus a categories x series
    /// table built from the cached display strings.
    static func chartBlocks(_ root: XmlElement) -> [Block] {
        var blocks: [Block] = []
        var title = root.firstDescendant(Ns.chart, "title").map { cleanText(drawingText($0)) }
        if let t = title, t.isBlank {
            title = nil
        }
        if let title {
            blocks.append(.paragraph([.text(title, style: Style(bold: true))]))
        }
        struct Series {
            var name: String
            var values: [String]
        }
        var categories: [String] = []
        var series: [Series] = []
        for ser in root.descendants(Ns.chart, "ser") {
            // Cached display strings only; `c:f` formula references are not text.
            let name = ser.find(Ns.chart, "tx")
                .flatMap { $0.firstDescendant(Ns.chart, "v") }
                .map { cleanText($0.text()) } ?? ""
            let cats: [String] = ser.find(Ns.chart, "cat")
                .map { $0.descendants(Ns.chart, "v").map { cleanText($0.text()) } } ?? []
            if categories.isEmpty {
                categories = cats
            }
            let values: [String] = ser.find(Ns.chart, "val")
                .map { $0.descendants(Ns.chart, "v").map { cleanText($0.text()) } } ?? []
            series.append(Series(name: name, values: values))
        }
        if !series.isEmpty && !categories.isEmpty {
            let catTitle = root.firstDescendant(Ns.chart, "catAx")
                .flatMap { $0.find(Ns.chart, "title") }
                .map { cleanText(drawingText($0)) } ?? ""
            var header: [Cell] = [.fromInlines([.plain(catTitle)])]
            header.append(contentsOf: series.map { .fromInlines([.plain($0.name)]) })
            var rows = [header]
            for (i, cat) in categories.enumerated() {
                var row: [Cell] = [.fromInlines([.plain(cat)])]
                for s in series {
                    let v = i < s.values.count ? s.values[i] : ""
                    row.append(.fromInlines([.plain(v)]))
                }
                rows.append(row)
            }
            blocks.append(.table(Table.fromRows(rows, headerRows: 1, kind: .data)))
        }
        return blocks
    }

    /// A SmartArt data part as a bullet list of its text points in order.
    static func diagramBlocks(_ root: XmlElement) -> [Block] {
        var items: [ListItem] = []
        for pt in root.descendants(Ns.dgm, "pt") {
            guard let t = pt.find(Ns.dgm, "t") else { continue }
            let text = cleanText(t.text())
            if text.isBlank {
                continue
            }
            items.append(
                ListItem(
                    blocks: [.paragraph([.plain(text)])],
                    checked: nil,
                    markerLabel: nil))
        }
        if items.isEmpty {
            return []
        }
        return [.list(List(marker: .bullet, start: 1, items: items))]
    }

    /// Text runs inside DrawingML rich text (`a:p`/`a:r`/`a:t`), joined.
    static func drawingText(_ elem: XmlElement) -> String {
        var parts: [String] = []
        for p in elem.descendants(Ns.a, "p") {
            let text = p.text()
            if !text.isBlank {
                parts.append(text)
            }
        }
        return parts.isEmpty ? elem.text() : parts.joined(separator: " ")
    }
}
