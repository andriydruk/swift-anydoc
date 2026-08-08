/// Block and inline walking for ODF text content.

struct OdfCounterKey: Hashable {
    var style: String
    var depth: Int
}

final class OdfCtx {
    let styles: OdfStyles
    let pkg: Package
    let assets: MutBox<AssetSink>
    var notes: [Note] = []
    /// Continuation counters per (list style, depth): the next number a
    /// `text:continue-numbering` list resumes at.
    var listCounters: [OdfCounterKey: UInt64] = [:]
    /// Next number per list `xml:id`, resolved by `text:continue-list`.
    var listIds: [String: UInt64] = [:]
    /// Heading numbering state for `text:outline-style` (values, started).
    var headingValues = [UInt64](repeating: 0, count: odfListLevels)
    var headingStarted = [Bool](repeating: false, count: odfListLevels)

    init(styles: OdfStyles, pkg: Package, assets: MutBox<AssetSink>) {
        self.styles = styles
        self.pkg = pkg
        self.assets = assets
    }
}

func parseContainer(_ parent: XmlElement, _ ctx: OdfCtx) throws -> [Block] {
    var blocks: [Block] = []
    var run = StyledRun()
    for child in parent.childElements {
        try parseBlockElem(child, ctx, &blocks, &run)
    }
    run.flush(&blocks)
    return blocks
}

private func parseBlockElem(
    _ elem: XmlElement,
    _ ctx: OdfCtx,
    _ blocks: inout [Block],
    _ run: inout StyledRun
) throws {
    let inText = elem.ns == Ns.text
    if inText {
        // Only a run of same-styled paragraphs continues a container.
        if !elem.named(Ns.text, "p") {
            run.flush(&blocks)
        }
        switch elem.local {
        case "h":
            let level = elem.attr(Ns.text, "outline-level").flatMap { UInt8($0) } ?? 1
            let (inlines, boxes) = try parseInlineContent(elem, ctx)
            if !inlinesAreEmpty(inlines) {
                var content = inlines
                rebaseEmphasis(&content, base: try paragraphBase(elem, ctx).resolve())
                // ODF outline links target headings by their text; carry
                // it as the heading's anchor id (without the number).
                let anchor = inlinesToPlainText(content)
                if let label = headingLabel(elem, level, ctx) {
                    content.insert(.text(label, style: .plain), at: 0)
                }
                blocks.append(.heading(level: Int(level), anchor: anchor, content: content))
            }
            blocks.append(contentsOf: boxes)
            return
        case "p":
            let (inlines, boxes) = try parseInlineContent(elem, ctx)
            let style = elem.attr(Ns.text, "style-name").flatMap { ctx.styles.blockStyle($0) }
            switch style {
            case .some(let style):
                run.push(style, inlines, &blocks)
            case nil:
                run.flush(&blocks)
                blocks.append(.paragraph(inlines))
            }
            if !boxes.isEmpty {
                // A frame is not part of the container's text.
                run.flush(&blocks)
                blocks.append(contentsOf: boxes)
            }
            return
        case "list":
            blocks.append(contentsOf: try parseList(elem, ctx, 0, nil, []))
            return
        case "section", "index-body", "index-title":
            blocks.append(contentsOf: try parseContainer(elem, ctx))
            return
        case "table-of-content", "alphabetical-index", "bibliography", "illustration-index":
            // The stored index body is real document text (the generated
            // entries are written into `text:index-body`).
            blocks.append(contentsOf: try parseContainer(elem, ctx))
            return
        default:
            return
        }
    }
    if elem.named(Ns.table, "table") {
        run.flush(&blocks)
        blocks.append(contentsOf: try parseTable(elem, ctx))
    }
}

/// One `text:list` -> blocks: list headers render without markers (as
/// plain blocks alongside the list), and every `text:start-value` restart
/// after the first item splits the run into a new list with that start.
/// `ancestors` carries the enclosing levels' current numbers so composite
/// labels (`text:display-levels` > 1) render the full chain.
private func parseList(
    _ elem: XmlElement,
    _ ctx: OdfCtx,
    _ depth: Int,
    _ inheritedStyle: String?,
    _ ancestors: [UInt64]
) throws -> [Block] {
    let styleName = elem.attr(Ns.text, "style-name") ?? inheritedStyle
    let level = ctx.styles.listLevel(styleName ?? "", depth)
    let ordered = level.marker.ordered

    let counterKey = OdfCounterKey(style: styleName ?? "", depth: depth)
    var start = level.start
    if ordered {
        // Continuation identity: an explicit target list (`continue-list`
        // by xml:id) wins over the style-scoped `continue-numbering`.
        if let target = elem.attr(Ns.text, "continue-list") {
            if let resume = ctx.listIds[target] {
                start = resume
            }
        } else if elem.attr(Ns.text, "continue-numbering") == "true",
            let resume = ctx.listCounters[counterKey]
        {
            start = resume
        }
    }

    var out: [Block] = []
    var current = List(marker: level.marker, start: start, items: [])
    var next = start
    var firstItem = true
    func flush(_ start: UInt64) {
        let done = current
        current = List(marker: done.marker, start: start, items: [])
        if !done.items.isEmpty {
            out.append(.list(done))
        }
    }
    for item in elem.childElements {
        let header = item.named(Ns.text, "list-header")
        if !(header || item.named(Ns.text, "list-item")) {
            continue
        }
        // Establish this item's number before walking children: nested
        // lists render composite labels against the ancestor chain.
        if !header, ordered,
            let sv = item.attr(Ns.text, "start-value").flatMap(odfParseStart)
        {
            if firstItem {
                current.start = sv
            } else {
                flush(sv)
            }
        }
        let number = current.start.saturatingAdding(UInt64(current.items.count))
        var chain = ancestors
        chain.append(number)
        var itemBlocks: [Block] = []
        var itemRun = StyledRun()
        for child in item.childElements {
            if child.named(Ns.text, "list") {
                itemRun.flush(&itemBlocks)
                itemBlocks.append(
                    contentsOf: try parseList(child, ctx, depth + 1, styleName, chain))
            } else {
                try parseBlockElem(child, ctx, &itemBlocks, &itemRun)
            }
        }
        itemRun.flush(&itemBlocks)
        if header {
            // A list header has no marker: its blocks sit next to the list
            // and do not consume a number.
            flush(next)
            out.append(contentsOf: itemBlocks)
            continue
        }
        firstItem = false
        let label = itemLabel(ctx, styleName, depth, chain)
        current.items.append(ListItem(blocks: itemBlocks, checked: nil, markerLabel: label))
        next = current.start.saturatingAdding(UInt64(current.items.count))
    }
    flush(next)
    if ordered, !out.isEmpty {
        ctx.listCounters[counterKey] = next
        if let id = elem.attrQualified(Ns.xml, "id") {
            ctx.listIds[id] = next
        }
    }
    return out
}

/// A list item's composite marker label (`num-prefix`/`num-suffix`/
/// `display-levels`); `nil` when the default `n.` label is faithful.
private func itemLabel(
    _ ctx: OdfCtx, _ styleName: String?, _ depth: Int, _ chain: [UInt64]
) -> String? {
    guard let styleName, let levels = ctx.styles.listLevels(styleName) else {
        return nil
    }
    let depth = min(depth, odfListLevels - 1)
    let lvl = levels[depth]
    if !lvl.marker.ordered {
        return nil
    }
    return compositeLabel(
        lvl.pattern(depth),
        ownMarker: lvl.marker,
        ownValue: chain.last ?? 1,
        levelMarker: { l in levels[min(l, odfListLevels - 1)].marker },
        levelValue: { l in
            l >= 0 && l < chain.count ? chain[l] : levels[min(l, odfListLevels - 1)].start
        })
}

/// ODF heading numbering: the `text:outline-style` level formats with the
/// heading's `restart-numbering`/`start-value`/`is-list-header` controls.
/// Advances the outline sequence; `nil` for unnumbered headings.
private func headingLabel(_ elem: XmlElement, _ level: UInt8, _ ctx: OdfCtx) -> String? {
    guard let levels = ctx.styles.outlineLevels() else {
        return nil
    }
    let idx = min(Int(max(level, 1)) - 1, odfListLevels - 1)
    let lvl = levels[idx]
    if !lvl.marker.ordered {
        return nil
    }
    // An unnumbered heading displays no number and consumes none.
    if elem.attr(Ns.text, "is-list-header") == "true" {
        return nil
    }
    let restart = elem.attr(Ns.text, "restart-numbering") == "true"
    let explicit = elem.attr(Ns.text, "start-value").flatMap(odfParseStart)
    let value: UInt64
    if let explicit {
        value = explicit
    } else if ctx.headingStarted[idx], !restart {
        value = ctx.headingValues[idx].saturatingAdding(1)
    } else {
        value = lvl.start
    }
    ctx.headingValues[idx] = value
    ctx.headingStarted[idx] = true
    for deeper in (idx + 1)..<odfListLevels {
        ctx.headingStarted[deeper] = false
    }
    let values = ctx.headingValues
    let started = ctx.headingStarted
    let label = compositeLabel(
        lvl.pattern(idx),
        ownMarker: lvl.marker,
        ownValue: value,
        levelMarker: { l in levels[min(l, odfListLevels - 1)].marker },
        levelValue: { l in
            let l = min(l, odfListLevels - 1)
            return started[l] ? values[l] : levels[l].start
        })
    // Headings have no native numbering in the output, so the default label
    // is rendered too.
    return "\(label ?? lvl.marker.label(value)) "
}

/// Inline content of a paragraph plus block attachments (text boxes) that
/// were anchored in it.
private func parseInlineContent(
    _ elem: XmlElement,
    _ ctx: OdfCtx
) throws -> ([Inline], [Block]) {
    let base = try paragraphBase(elem, ctx)
    var out: [Inline] = []
    var boxes: [Block] = []
    try walkInlines(elem, ctx, base, &out, &boxes)
    return (out, boxes)
}

/// The style a paragraph's runs cascade from. An unstyled paragraph still
/// sits on the family's default style.
private func paragraphBase(_ elem: XmlElement, _ ctx: OdfCtx) throws -> StyleDelta {
    try ctx.styles.delta("paragraph", elem.attr(Ns.text, "style-name") ?? "")
}

private func walkInlines(
    _ elem: XmlElement,
    _ ctx: OdfCtx,
    _ delta: StyleDelta,
    _ out: inout [Inline],
    _ boxes: inout [Block]
) throws {
    let style = delta.resolve()
    loop: for node in elem.children {
        switch node {
        case .text(let t):
            let text = collapseWhitespace(cleanText(t))
            if !text.isEmpty {
                out.append(.text(text, style: style))
            }
        case .elem(let child):
            let inText = child.ns == Ns.text
            if inText {
                switch child.local {
                case "span":
                    let merged: StyleDelta
                    switch child.attr(Ns.text, "style-name") {
                    case .some(let name): merged = delta.merge(try ctx.styles.delta("text", name))
                    case nil: merged = delta
                    }
                    try walkInlines(child, ctx, merged, &out, &boxes)
                    continue loop
                case "a":
                    let href = child.attr(Ns.xlink, "href") ?? ""
                    var content: [Inline] = []
                    try walkInlines(child, ctx, delta, &content, &boxes)
                    switch odfClassifyHref(href) {
                    case .some(let target) where !inlinesAreEmpty(content):
                        out.append(.link(content: content, target: target))
                    default:
                        out.append(contentsOf: content)
                    }
                    continue loop
                case "s":
                    let n = child.attr(Ns.text, "c").flatMap { UInt($0) } ?? 1
                    out.append(
                        .text(String(repeating: " ", count: Int(min(n, 20))), style: .plain))
                    continue loop
                case "tab":
                    out.append(.text(" ", style: .plain))
                    continue loop
                case "line-break":
                    out.append(.lineBreak)
                    continue loop
                case "bookmark", "bookmark-start":
                    if let name = child.attr(Ns.text, "name") {
                        out.append(.anchor(name))
                    }
                    continue loop
                case "note":
                    let idx = ctx.notes.count
                    let id = child.attr(Ns.text, "id") ?? "odt\(idx)"
                    let kind: NoteKind
                    switch child.attr(Ns.text, "note-class") {
                    case "endnote": kind = .endnote
                    default: kind = .footnote
                    }
                    let noteBlocks: [Block]
                    switch child.find(Ns.text, "note-body") {
                    case .some(let b): noteBlocks = try parseContainer(b, ctx)
                    case nil: noteBlocks = []
                    }
                    ctx.notes.append(Note(id: id, kind: kind, blocks: noteBlocks))
                    out.append(.noteRef(id))
                    continue loop
                case "annotation", "tracked-changes", "soft-page-break":
                    continue loop
                default:
                    break
                }
            }
            if child.named(Ns.draw, "frame") {
                try walkFrame(child, ctx, &out, &boxes)
                continue loop
            }
            try walkInlines(child, ctx, delta, &out, &boxes)
        }
    }
}

/// A draw:frame inline in text: an image (resolved into the asset store) or
/// a text box (attached as blocks after the paragraph).
func walkFrame(
    _ frame: XmlElement,
    _ ctx: OdfCtx,
    _ out: inout [Inline],
    _ boxes: inout [Block]
) throws {
    if let textBox = frame.find(Ns.draw, "text-box") {
        boxes.append(contentsOf: try parseContainer(textBox, ctx))
        return
    }
    let rawAlt = frame.firstDescendant(Ns.svgCompat, "title").map { $0.text() }
        ?? frame.firstDescendant(Ns.svgCompat, "desc").map { $0.text() }
        ?? ""
    let alt = cleanText(rawAlt.rustTrim())
    if let image = frame.firstDescendant(Ns.draw, "image") {
        let href = image.attr(Ns.xlink, "href") ?? ""
        let source = try loadImage(ctx, href)
        if source != nil || !alt.isEmpty {
            out.append(.image(alt: alt, source: source ?? .unavailable))
        }
        return
    }
    if !alt.isEmpty {
        out.append(.image(alt: alt, source: .unavailable))
    }
}

/// Failures degrade (log + `nil`) per the unified policy; resource-limit
/// errors always propagate.
private func loadImage(_ ctx: OdfCtx, _ href: String) throws -> ImageSource? {
    if href.isEmpty {
        return nil
    }
    if isAbsoluteUri(href) {
        return .external(href)
    }
    let target: PackageTarget
    do {
        target = try resolvePackageReference(basePart: "content.xml", reference: href)
    } catch let e as ConvertError {
        Log.warn("skipping unresolvable image reference \(rustDebugString(href)): \(e.message)")
        return nil
    }
    switch try ctx.pkg.optionalPart(target.path) {
    case .some(let bytes):
        let media = mediaTypeFor(target.path)
        let id = try ctx.assets.value.add(
            mediaType: media, originPart: target.path, bytes: bytes)
        return .asset(id)
    case nil:
        Log.warn("image part \(target.path) is missing")
        return nil
    }
}

/// ODF hrefs: external URLs, package-relative paths, or `#target` internal
/// references (with `|outline`-style suffixes on generated links).
func odfClassifyHref(_ href: String) -> LinkTarget? {
    if href.isEmpty {
        return nil
    }
    if href.hasPrefix("#") {
        let fragment = href.dropFirst()
        let target = fragment.split(separator: "|", omittingEmptySubsequences: false)
            .first ?? fragment
        if target.isEmpty {
            return nil
        }
        return .anchor(decodeFragment(String(target)))
    }
    if isAbsoluteUri(href) {
        return .external(href)
    } else {
        return .relative(href)
    }
}
