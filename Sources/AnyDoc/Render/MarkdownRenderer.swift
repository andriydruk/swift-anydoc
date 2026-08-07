/// GitHub-Flavored Markdown serializer for the document model.

/// Immutable render context threaded through every render function:
/// footnote id -> rendered number, and the anchor map.
struct RenderContext {
    var nums: [String: Int]
    var anchors: AnchorMap
}

/// Escape a source-derived composite marker label for literal use: control
/// characters collapse to spaces and Markdown syntax is neutralized so a
/// crafted label cannot alter document structure.
func escapeMarkerLabel(_ label: String, _ ctx: InlineContext) -> String {
    let cleaned = String(String.UnicodeScalarView(label.unicodeScalars.map { c in
        c.isRustControl ? " " : c
    }))
    // List-item content re-opens block syntax after the `- ` marker.
    let opts = EscapeOpts(atLineStart: ctx == .block, trailingActive: true)
    return escapeText(cleaned, ctx, opts)
}

public func documentToMarkdown(_ doc: Document) -> String {
    let rc = RenderContext(nums: numberNotes(doc), anchors: AnchorMap.resolve(doc))
    var parts: [String] = doc.blocks.compactMap { renderBlock($0, rc) }
    var renderedDefs: Set<Int> = []
    var ordered: [(Note, Int)] = doc.notes.compactMap { note in
        rc.nums[note.id].map { (note, $0) }
    }
    ordered.sort { $0.1 < $1.1 }
    for (note, num) in ordered {
        let body = renderBlocks(note.blocks, rc)
        if body.isEmpty {
            continue
        }
        // The first non-empty definition for a duplicate id wins.
        if !renderedDefs.insert(num).inserted {
            Log.debug("duplicate note id \(note.id) dropped from output")
            continue
        }
        var lines = body.rustLines()[...]
        let first = lines.popFirst() ?? ""
        var s = "[^\(num)]: \(first)"
        for line in lines {
            s += "\n"
            if !line.isEmpty {
                s += "    "
                s += line
            }
        }
        parts.append(s)
    }
    var out = parts.joined(separator: "\n\n")
    if !out.isEmpty {
        out += "\n"
    }
    return out
}

/// Number notes in first-reference order; unreferenced notes follow at the
/// end. The first note wins a duplicated id.
private func numberNotes(_ doc: Document) -> [String: Int] {
    var valid: [String: Note] = [:]
    for note in doc.notes {
        if !note.blocks.allSatisfy(blockIsBlank) {
            if valid[note.id] == nil { valid[note.id] = note }
        }
    }
    var order: [String] = []
    var seen: Set<String> = []
    collectNoteRefs(doc.blocks, valid, &order, &seen)
    for note in doc.notes {
        if valid[note.id] != nil, seen.insert(note.id).inserted {
            order.append(note.id)
        }
    }
    var nums: [String: Int] = [:]
    for (i, id) in order.enumerated() {
        nums[id] = i + 1
    }
    return nums
}

private func blockIsBlank(_ block: Block) -> Bool {
    if case .paragraph(let inlines) = block {
        return inlinesAreEmpty(inlines)
    }
    return false
}

private func collectNoteRefs(
    _ blocks: [Block], _ valid: [String: Note], _ order: inout [String], _ seen: inout Set<String>
) {
    func walkInlines(_ inlines: [Inline]) {
        for inline in inlines {
            switch inline {
            case .noteRef(let id):
                if let note = valid[id], seen.insert(id).inserted {
                    order.append(id)
                    collectNoteRefs(note.blocks, valid, &order, &seen)
                }
            case .link(let content, _):
                walkInlines(content)
            default:
                break
            }
        }
    }
    for block in blocks {
        switch block {
        case .paragraph(let inlines), .heading(_, _, let inlines):
            walkInlines(inlines)
        case .list(let list):
            for item in list.items {
                collectNoteRefs(item.blocks, valid, &order, &seen)
            }
        case .table(let table):
            for row in table.grid {
                for slot in row {
                    if case .origin(let cell) = slot {
                        collectNoteRefs(cell.blocks, valid, &order, &seen)
                    }
                }
            }
        case .blockQuote(let blocks):
            collectNoteRefs(blocks, valid, &order, &seen)
        case .codeBlock, .rule:
            break
        }
    }
}

func renderBlocks(_ blocks: [Block], _ rc: RenderContext) -> String {
    blocks.compactMap { renderBlock($0, rc) }.joined(separator: "\n\n")
}

func renderBlock(_ block: Block, _ rc: RenderContext) -> String? {
    switch block {
    case .heading(let level, _, let content):
        let text = renderInlines(content, .heading, rc).rustTrim()
        if text.isEmpty {
            return nil
        }
        let clamped = min(max(level, 1), 6)
        return "\(String(repeating: "#", count: clamped)) \(text)"
    case .paragraph(let inlines):
        let text = renderInlines(inlines, .block, rc)
        let trimmed = trimParagraph(text)
        return trimmed.isEmpty ? nil : trimmed
    case .list(let list):
        return renderList(list, rc)
    // Trivial layout tables are scaffolding; render their content directly.
    case .table(let t) where t.kind == .layout && t.isSingleCell:
        guard case .origin(let cell) = t.grid[0][0] else { return nil }
        let inner = renderBlocks(cell.blocks, rc)
        return inner.isEmpty ? nil : inner
    case .table(let t):
        return renderTable(t, rc)
    case .blockQuote(let blocks):
        let inner = renderBlocks(blocks, rc)
        if inner.isEmpty {
            return nil
        }
        return inner.rustLines()
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    case .codeBlock(let lang, let text):
        let fence = backtickFence(text, min: 3)
        var body = Substring(text)
        while body.hasSuffix("\n") { body = body.dropLast() }
        return "\(fence)\(lang ?? "")\n\(body)\n\(fence)"
    case .rule:
        return "---"
    }
}

private func renderList(_ list: List, _ rc: RenderContext) -> String? {
    if list.items.isEmpty {
        return nil
    }
    var renderedItems: [String] = []
    var loose = false
    for (i, item) in list.items.enumerated() {
        // GFM has decimal ordered lists only, so Roman/alphabetic levels
        // render as bullets carrying the source marker as literal text
        // (`- iv. ...`) — the source marker semantics stay visible. Items
        // with an explicit label (composite number text) render it the same
        // way.
        let marker: String
        switch (item.markerLabel, list.marker) {
        case (.some(let label), _):
            marker = "- \(escapeMarkerLabel(label, .block)) "
        case (nil, .bullet):
            marker = "- "
        case (nil, .decimal):
            marker = "\(list.start.saturatingAdding(UInt64(i))). "
        case (nil, let kind):
            marker = "- \(kind.label(list.start.saturatingAdding(UInt64(i)))) "
        }
        let checkbox: String
        switch item.checked {
        case .some(true): checkbox = "[x] "
        case .some(false): checkbox = "[ ] "
        case nil: checkbox = ""
        }
        let body = renderBlocks(item.blocks, rc)
        if item.blocks.count > 1 {
            loose = true
        }
        let indent = String(repeating: " ", count: marker.unicodeScalars.count)
        var lines = body.rustLines()[...]
        let first = lines.popFirst() ?? ""
        var s = "\(marker)\(checkbox)\(first)"
        for line in lines {
            s += "\n"
            if line.isEmpty {
                loose = true
            } else {
                s += indent
                s += line
            }
        }
        renderedItems.append(s)
    }
    let sep = loose ? "\n\n" : "\n"
    return renderedItems.joined(separator: sep)
}

/// Trim paragraph lines, keeping hard-break backslashes intact.
func trimParagraph(_ text: String) -> String {
    let lines: [String] = text.rustLines().map { l in
        let started = l.rustTrimStart()
        let t = endsWithHardBreak(started) ? started : started.rustTrimEnd()
        var noBreaks = Substring(t)
        while noBreaks.hasSuffix("\\") { noBreaks = noBreaks.dropLast() }
        return noBreaks.isBlank ? "" : t
    }
    guard let start = lines.firstIndex(where: { !$0.isEmpty }),
        let end = lines.lastIndex(where: { !$0.isEmpty })
    else {
        return ""
    }
    var out = lines[start...end].joined(separator: "\n")
    if endsWithHardBreak(out) {
        out.removeLast()
        out = out.rustTrimEnd()
    }
    return out
}

private func endsWithHardBreak(_ line: some StringProtocol) -> Bool {
    var count = 0
    for c in line.unicodeScalars.reversed() {
        if c == "\\" { count += 1 } else { break }
    }
    return count % 2 == 1
}
