/// (X)HTML element tree -> model blocks. Used by the EPUB frontend.
///
/// Applies a deliberately small CSS subset - the semantic properties only:
/// `font-weight`, `font-style`, `text-decoration: line-through`, and
/// `display: none` - from inline `style` attributes and element/class rules.
/// Tables build the canonical grid (`rowspan`/`colspan`); ordered lists honor
/// `start`, `reversed`, `type`, and per-item `value`.

/// Frontend hooks: how hrefs, image sources, and anchor ids resolve in the
/// containing document (EPUB scopes them per chapter).
protocol HtmlCtx {
    func linkTarget(_ href: String) -> LinkTarget?
    /// A failed load degrades to `nil`; resource-limit errors propagate.
    func imageSource(_ src: String) throws -> ImageSource?
    func anchorId(_ raw: String) -> AnchorId
}

func htmlToBlocks(_ body: XmlElement, css: Stylesheet, ctx: any HtmlCtx) throws -> [Block] {
    var builder = HtmlBuilder(css: css, ctx: ctx, startBoundary: true)
    try builder.walkChildren(body, StyleDelta())
    return builder.finish()
}

// ---------------------------------------------------------------------------
// Minimal CSS

struct StyleProps {
    var delta = StyleDelta()
    /// `display` visibility as a tri-state: a higher-priority
    /// `display: block` (or any non-none value) can restore content a
    /// lower-priority `display: none` hid.
    var hidden: Bool? = nil

    func merge(_ over: StyleProps) -> StyleProps {
        StyleProps(delta: delta.merge(over.delta), hidden: over.hidden ?? hidden)
    }

    var isDefault: Bool {
        delta == StyleDelta() && hidden == nil
    }
}

/// Cascade priority tiers: rules < inline style < `!important` rules <
/// `!important` inline style, with selector specificity ordering within a
/// tier and source order breaking ties.
private let inlinePriority: UInt32 = 100_000
private let importantPriority: UInt32 = 1_000_000

private struct CssRule {
    var tag: String?
    var cls: String?
    /// Cascade priority: the tier base plus selector specificity within the
    /// supported subset (a class outweighs any number of tags: `.c` = 10,
    /// `t.c` = 11, `t` = 1). Source order breaks ties (rules are stored in
    /// document order).
    var priority: UInt32
    var props: StyleProps
}

struct Stylesheet {
    private var rules: [CssRule] = []

    init() {}

    /// Add rules from one stylesheet's text. Only simple `tag`, `.class`,
    /// and `tag.class` selectors participate; `!important` declarations
    /// enter the higher cascade tier.
    ///
    /// Parsed over Unicode scalars: Rust's `char`-based `split`/`contains`
    /// see every delimiter even when a combining mark follows it, where
    /// Swift's `Character` view would fuse the two.
    mutating func add(_ cssText: String) {
        let css = Array(stripCssComments(cssText).unicodeScalars)
        for chunk in splitScalar(css[...], "}") {
            guard let brace = chunk.firstIndex(of: "{") else {
                continue
            }
            let selectors = chunk[..<brace]
            let body = chunk[(brace + 1)...]
            let decls = parseDeclarations(body)
            if decls.normal.isDefault && decls.important.isDefault {
                continue
            }
            for selector in splitScalar(selectors, ",") {
                let s = rustTrimScalars(selector)
                if s.isEmpty || s.contains(" ") || s.contains(":") || s.contains("[") {
                    continue  // combinators/pseudo/attribute selectors: out of subset
                }
                let tag: String?
                let cls: String?
                if let dot = s.firstIndex(of: ".") {
                    let t = s[..<dot]
                    tag = t.isEmpty ? nil : asciiLowercase(scalarString(t))
                    cls = scalarString(s[(dot + 1)...])
                } else {
                    tag = asciiLowercase(scalarString(s))
                    cls = nil
                }
                let specificity: UInt32 = (cls != nil ? 10 : 0) + (tag != nil ? 1 : 0)
                for (props, base) in [(decls.normal, 0 as UInt32), (decls.important, importantPriority)]
                where !props.isDefault {
                    rules.append(
                        CssRule(tag: tag, cls: cls, priority: base + specificity, props: props))
                }
            }
        }
    }

    /// Matching rules for one element as (priority, props) pairs.
    fileprivate func matchingRules(tag: String, classes: [String]) -> [(UInt32, StyleProps)] {
        rules
            .filter { rule in
                (rule.tag == nil || rule.tag == tag)
                    && (rule.cls == nil || classes.contains(rule.cls ?? ""))
            }
            .map { ($0.priority, $0.props) }
    }
}

private func stripCssComments(_ css: String) -> String {
    let bytes = Array(css.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var rest = 0
    while let start = findAsciiPair(bytes, from: rest, UInt8(ascii: "/"), UInt8(ascii: "*")) {
        out.append(contentsOf: bytes[rest..<start])
        // The `*/` search starts at the `/*` itself, so `/*/` closes at its
        // own overlapping star (Rust `rest[start..].find("*/")`).
        guard let end = findAsciiPair(bytes, from: start, UInt8(ascii: "*"), UInt8(ascii: "/"))
        else {
            return String(decoding: out, as: UTF8.self)
        }
        rest = end + 2
    }
    out.append(contentsOf: bytes[rest...])
    return String(decoding: out, as: UTF8.self)
}

private func findAsciiPair(_ bytes: [UInt8], from: Int, _ a: UInt8, _ b: UInt8) -> Int? {
    var i = max(from, 0)
    while i + 1 < bytes.count {
        if bytes[i] == a, bytes[i + 1] == b {
            return i
        }
        i += 1
    }
    return nil
}

/// A declaration block's properties, split by cascade tier.
private struct DeclProps {
    var normal = StyleProps()
    var important = StyleProps()
}

/// The semantic subset of a declaration block.
private func parseDeclarations(_ body: ArraySlice<Unicode.Scalar>) -> DeclProps {
    var out = DeclProps()
    for decl in splitScalar(body, ";") {
        guard let colon = decl.firstIndex(of: ":") else {
            continue
        }
        let name = asciiLowercase(scalarString(rustTrimScalars(decl[..<colon])))
        var valueScalars = ArraySlice(
            Array(asciiLowercase(scalarString(rustTrimScalars(decl[(colon + 1)...]))).unicodeScalars))
        // `!important` moves the declaration into the higher cascade tier.
        var important = false
        if let pos = valueScalars.firstIndex(of: "!") {
            if scalarString(rustTrimScalars(valueScalars[(pos + 1)...])) == "important" {
                important = true
            }
            valueScalars = rustTrimEndScalars(valueScalars[..<pos])
        }
        let value = scalarString(valueScalars)
        var props = important ? out.important : out.normal
        switch name {
        case "font-weight":
            props.delta.bold =
                value == "bold"
                || value == "bolder"
                || (parseRustU32(value).map { $0 >= 600 } ?? false)
        case "font-style":
            props.delta.italic = (value == "italic" || value == "oblique")
        case "text-decoration", "text-decoration-line":
            if containsScalarRun(valueScalars, "line-through") {
                props.delta.strike = true
            } else if value == "none" {
                props.delta.strike = false
            }
        case "display":
            props.hidden = (value == "none")
        default:
            break
        }
        if important { out.important = props } else { out.normal = props }
    }
    return out
}

/// Rust `str::split` on one delimiter scalar: empty pieces included.
private func splitScalar(
    _ scalars: ArraySlice<Unicode.Scalar>, _ separator: Unicode.Scalar
) -> [ArraySlice<Unicode.Scalar>] {
    var out: [ArraySlice<Unicode.Scalar>] = []
    var start = scalars.startIndex
    for i in scalars.indices where scalars[i] == separator {
        out.append(scalars[start..<i])
        start = i + 1
    }
    out.append(scalars[start...])
    return out
}

/// Rust `str::trim` over a scalar slice.
private func rustTrimScalars(_ scalars: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
    rustTrimEndScalars(scalars.drop(while: \.isRustWhitespace))
}

/// Rust `str::trim_end` over a scalar slice.
private func rustTrimEndScalars(
    _ scalars: ArraySlice<Unicode.Scalar>
) -> ArraySlice<Unicode.Scalar> {
    var view = scalars
    while let last = view.last, last.isRustWhitespace {
        view = view.dropLast()
    }
    return view
}

/// Rust `str::contains(&str)`: a plain scalar-run substring search.
private func containsScalarRun(
    _ haystack: ArraySlice<Unicode.Scalar>, _ needle: String
) -> Bool {
    let pattern = Array(needle.unicodeScalars)
    if pattern.isEmpty {
        return true
    }
    guard haystack.count >= pattern.count else {
        return false
    }
    for start in haystack.startIndex...(haystack.endIndex - pattern.count) {
        var matched = true
        for (offset, p) in pattern.enumerated() where haystack[start + offset] != p {
            matched = false
            break
        }
        if matched {
            return true
        }
    }
    return false
}

private func scalarString(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
}

// ---------------------------------------------------------------------------
// Walking

private struct HtmlBuilder {
    var blocks: [Block] = []
    var inlines: [Inline] = []
    let css: Stylesheet
    let ctx: any HtmlCtx
    /// Whether text appended while `inlines` is empty sits at a whitespace
    /// boundary (block start: leading whitespace collapses away; inline
    /// sub-builders inherit the surrounding run's state instead).
    var startBoundary: Bool

    mutating func flushParagraph() {
        if !inlines.isEmpty {
            let content = inlines
            inlines = []
            if keepsParagraph(content) {
                blocks.append(.paragraph(content))
            }
        }
        startBoundary = true
    }

    mutating func finish() -> [Block] {
        flushParagraph()
        return blocks
    }

    /// Sub-walk in a fresh block context (list items, quotes, cells).
    mutating func subBlocks(_ elem: XmlElement, _ delta: StyleDelta) throws -> [Block] {
        try subBlocksAt(elem, delta, true)
    }

    /// Sub-walk starting at the given whitespace-boundary state (`false`
    /// when the sub-content continues an inline run, so its leading space
    /// stays significant relative to the surrounding text).
    mutating func subBlocksAt(
        _ elem: XmlElement, _ delta: StyleDelta, _ startBoundary: Bool
    ) throws -> [Block] {
        var b = HtmlBuilder(css: css, ctx: ctx, startBoundary: startBoundary)
        try b.walkChildren(elem, delta)
        return b.finish()
    }

    /// Element-level props: matching stylesheet rules and the inline `style`
    /// attribute merged in one cascade order — normal rules, inline style,
    /// `!important` rules, `!important` inline style.
    func elementProps(_ elem: XmlElement) -> StyleProps {
        let classes: [String] =
            elem.attrAny("class").map(splitRustWhitespace) ?? []
        var entries = css.matchingRules(tag: elem.local, classes: classes)
        if let style = elem.attrAny("style") {
            let decls = parseDeclarations(ArraySlice(Array(style.unicodeScalars)))
            entries.append((inlinePriority, decls.normal))
            entries.append((importantPriority + inlinePriority, decls.important))
        }
        // Stable order: priority, with source order breaking ties.
        let sorted = entries.enumerated()
            .sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
        var props = StyleProps()
        for entry in sorted {
            props = props.merge(entry.element.1)
        }
        return props
    }

    mutating func pushAnchor(_ elem: XmlElement) {
        if let id = elem.attrAny("id"), !id.isEmpty {
            inlines.append(.anchor(ctx.anchorId(id)))
        }
        if elem.local == "a", let name = elem.attrAny("name"), !name.isEmpty {
            inlines.append(.anchor(ctx.anchorId(name)))
        }
    }

    mutating func walkChildren(_ elem: XmlElement, _ delta: StyleDelta) throws {
        for node in elem.children {
            switch node {
            case .text(let t): pushText(t, delta)
            case .elem(let e): try walkElem(e, delta)
            }
        }
    }

    mutating func pushText(_ text: String, _ delta: StyleDelta) {
        let collapsed = collapseWhitespace(cleanText(text))
        if collapsed.isEmpty {
            return
        }
        // Collapse across node boundaries: leading whitespace vanishes at a
        // block start and after already-emitted whitespace, no matter how
        // the source split its text nodes and inline elements.
        let text: String
        if atSpaceBoundary(inlines, startBoundary) {
            // Rust `trim_start_matches(' ')`: leading space *scalars* only —
            // a space fused into a combining cluster must still strip.
            var scalars = ArraySlice(Array(collapsed.unicodeScalars))
            while scalars.first == " " {
                scalars = scalars.dropFirst()
            }
            text = scalarString(scalars)
        } else {
            text = collapsed
        }
        if text.isEmpty {
            return
        }
        inlines.append(.text(text, style: delta.resolve()))
    }

    mutating func walkElem(_ elem: XmlElement, _ delta: StyleDelta) throws {
        let props = elementProps(elem)
        if props.hidden == true {
            return
        }
        // Cascade order: inherited delta, then the tag's presentational
        // default (`<b>`, `<i>`, …), then CSS — so `font-weight: normal`
        // can undo a `<b>`.
        let delta = mergeInlineTag(elem, delta).merge(props.delta)
        switch elem.local {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            flushParagraph()
            let level = Int(parseRustU32(elem.local.dropFirst()) ?? 1)
            var content = try inlineChildren(elem, delta)
            // The heading element's own styling is how it looks, not
            // markup applied to the words; a `<b>` inside it still is.
            rebaseEmphasis(&content, base: delta.resolve())
            let anchor = elem.attrAny("id").map { ctx.anchorId($0) }
            if !inlinesAreEmpty(content) {
                blocks.append(.heading(level: level, anchor: anchor, content: content))
            } else {
                // An empty heading still carries link targets: its own
                // id and any anchors inside.
                var kept: [Inline] = []
                if let anchor {
                    kept.append(.anchor(anchor))
                }
                kept.append(contentsOf: content.filter { inline in
                    if case .anchor = inline { return true }
                    return false
                })
                if !kept.isEmpty {
                    blocks.append(.paragraph(kept))
                }
            }
        case "p":
            flushParagraph()
            pushAnchor(elem)
            var content = inlines
            inlines = []
            content.append(contentsOf: try inlineChildren(elem, delta))
            if keepsParagraph(content) {
                blocks.append(.paragraph(content))
            }
        case "ul", "ol":
            flushParagraph()
            let lists = try parseList(elem, delta)
            blocks.append(contentsOf: lists)
        case "table":
            flushParagraph()
            if let caption = elem.childElements.first(where: { $0.local == "caption" }) {
                let content = try inlineChildren(caption, delta)
                if keepsParagraph(content) {
                    blocks.append(.paragraph(content))
                }
            }
            if let t = try parseTable(elem, delta) {
                blocks.append(t)
            }
        case "blockquote":
            flushParagraph()
            let inner = try subBlocks(elem, delta)
            if !inner.isEmpty {
                blocks.append(.blockQuote(inner))
            }
        case "pre":
            flushParagraph()
            let text = elem.text()
            if !text.isBlank {
                blocks.append(.codeBlock(lang: nil, text: text))
            }
        case "hr":
            flushParagraph()
            blocks.append(.rule)
        case let name where isContainerTag(name):
            pushAnchor(elem)
            if hasBlockChildren(elem) {
                flushParagraph()
                try walkChildren(elem, delta)
                flushParagraph()
            } else {
                try walkChildren(elem, delta)
            }
        case "script", "style", "head", "template", "noscript":
            break
        default:
            try walkInline(elem, delta)
        }
    }

    mutating func walkInline(_ elem: XmlElement, _ delta: StyleDelta) throws {
        pushAnchor(elem)
        switch elem.local {
        case "br":
            inlines.append(.lineBreak)
        case "img", "image":
            let alt = cleanText(elem.attrAny("alt") ?? "")
            let src = elem.attrAny("src") ?? elem.attrAny("href") ?? ""
            let source = try ctx.imageSource(src)
            if source != nil || !alt.isBlank {
                inlines.append(.image(alt: alt, source: source ?? .unavailable))
            }
        case "a":
            let target = elem.attrAny("href").flatMap { ctx.linkTarget($0) }
            let content = try inlineChildrenAt(
                elem, delta, atSpaceBoundary(inlines, startBoundary))
            // An empty label still keeps a resolved target: the renderer
            // shows the URL as the link text.
            if let target {
                inlines.append(.link(content: content, target: target))
            } else {
                inlines.append(contentsOf: content)
            }
        default:
            try walkChildren(elem, delta)
        }
    }

    mutating func inlineChildren(_ elem: XmlElement, _ delta: StyleDelta) throws -> [Inline] {
        try inlineChildrenAt(elem, delta, true)
    }

    /// Inline children starting at the given whitespace-boundary state.
    mutating func inlineChildrenAt(
        _ elem: XmlElement, _ delta: StyleDelta, _ startBoundary: Bool
    ) throws -> [Inline] {
        let blocks = try subBlocksAt(elem, delta, startBoundary)
        if blocks.count == 1, case .paragraph(let inlines) = blocks[0] {
            return inlines
        }
        var out: [Inline] = []
        for (i, block) in blocks.enumerated() {
            if i > 0 {
                out.append(.lineBreak)
            }
            switch block {
            case .paragraph(let inlines):
                out.append(contentsOf: inlines)
            case .heading(_, _, let content):
                out.append(contentsOf: content)
            default:
                out.append(.plain(collapseWhitespace(blockText(block))))
            }
        }
        return out
    }

    /// Ordered/unordered list with `start`, `reversed`, `type`, and per-item
    /// `value`. Non-contiguous numbering splits into consecutive list blocks
    /// so the rendered numbers match the source.
    mutating func parseList(_ elem: XmlElement, _ delta: StyleDelta) throws -> [Block] {
        let ordered = elem.local == "ol"
        let items = elem.childElements.filter { $0.local == "li" }
        if items.isEmpty {
            return []
        }
        if !ordered {
            var listItems: [ListItem] = []
            listItems.reserveCapacity(items.count)
            for li in items {
                listItems.append(ListItem(blocks: try subBlocks(li, delta)))
            }
            return [.list(List(marker: .bullet, start: 1, items: listItems))]
        }
        let marker: MarkerKind
        switch elem.attrAny("type") {
        case "a": marker = .lowerAlpha
        case "A": marker = .upperAlpha
        case "i": marker = .lowerRoman
        case "I": marker = .upperRoman
        default: marker = .decimal
        }
        let reversed = elem.attrAny("reversed") != nil
        let start: Int64 =
            elem.attrAny("start").flatMap(parseRustI64)
            ?? (reversed ? Int64(items.count) : 1)
        var numbers: [Int64] = []
        numbers.reserveCapacity(items.count)
        var next = start
        for li in items {
            if let v = li.attrAny("value").flatMap(parseRustI64) {
                next = v
            }
            numbers.append(next)
            // Source-controlled values sit anywhere in the i64 range; the
            // step must not overflow.
            if reversed {
                next = next == .min ? .min : next - 1
            } else {
                next = next == .max ? .max : next + 1
            }
        }
        // Zero/negative numbers are valid ordered-list values but cannot be
        // a `start` for the renderer's start+index numbering; such lists
        // carry every number as an explicit literal marker instead.
        if numbers.contains(where: { $0 < 1 }) {
            var listItems: [ListItem] = []
            listItems.reserveCapacity(items.count)
            for (li, n) in zip(items, numbers) {
                listItems.append(
                    ListItem(blocks: try subBlocks(li, delta), markerLabel: "\(n)."))
            }
            return [.list(List(marker: marker, start: 1, items: listItems))]
        }
        var out: [Block] = []
        var current: List? = nil
        var lastNumber: Int64 = 0
        for (li, number) in zip(items, numbers) {
            let item = ListItem(blocks: try subBlocks(li, delta))
            let contiguous = current != nil && lastNumber != .max && lastNumber + 1 == number
            if !contiguous {
                if let list = current {
                    out.append(.list(list))
                    current = nil
                }
                // number >= 1 was proven above, so the u64 cast is exact.
                current = List(marker: marker, start: UInt64(bitPattern: number), items: [])
            }
            current?.items.append(item)
            lastNumber = number
        }
        if let list = current {
            out.append(.list(list))
        }
        return out
    }

    mutating func parseTable(_ elem: XmlElement, _ delta: StyleDelta) throws -> Block? {
        // (row, is thead row, row-group index): each thead/tbody/tfoot is
        // one row group; consecutive direct `tr` children form an implicit
        // one. `rowspan="0"` spans to the end of its group.
        var rowElems: [(tr: XmlElement, inHead: Bool, group: Int)] = []
        var group = 0
        var inImplicitGroup = false
        for child in elem.childElements {
            switch child.local {
            case "thead", "tbody", "tfoot":
                if inImplicitGroup {
                    inImplicitGroup = false
                    group += 1
                }
                let inHead = child.local == "thead"
                for tr in child.childElements where tr.local == "tr" {
                    rowElems.append((tr, inHead, group))
                }
                group += 1
            case "tr":
                inImplicitGroup = true
                rowElems.append((child, false, group))
            default:
                break
            }
        }
        if rowElems.isEmpty {
            return nil
        }
        // Last row index of each group, for rowspan=0 expansion.
        var groupEnd: [Int: Int] = [:]
        for (i, row) in rowElems.enumerated() {
            groupEnd[row.group] = i
        }
        var builder = GridBuilder()
        var headerRows = 0
        for (i, row) in rowElems.enumerated() {
            builder.nextRow()
            var allTh = true
            var anyCell = false
            for cell in row.tr.childElements {
                guard cell.local == "td" || cell.local == "th" else {
                    continue
                }
                anyCell = true
                if cell.local != "th" {
                    allTh = false
                }
                // HTML clamps colspan to 1000 and rowspan to 65534.
                let colSpan = min(max(cell.attrAny("colspan").flatMap(parseRustU32) ?? 1, 1), 1000)
                let rowSpan: UInt32
                switch cell.attrAny("rowspan").flatMap(parseRustU32) {
                case .some(0):
                    // rowspan=0: span all remaining rows of the row group.
                    let end = max(groupEnd[row.group] ?? i, i)
                    rowSpan = UInt32(clamping: end - i + 1)
                case .some(let n):
                    rowSpan = min(max(n, 1), 65534)
                case .none:
                    rowSpan = 1
                }
                let cellBlocks = try subBlocks(cell, delta)
                try builder.place(Cell.spanning(cellBlocks, colSpan: colSpan, rowSpan: rowSpan))
            }
            if i == headerRows && (row.inHead || (allTh && anyCell)) {
                headerRows += 1
            }
        }
        var table = builder.finish(.data)
        if table.grid.isEmpty {
            return nil
        }
        table.headerRows = resolveHeaderRows(table, declared: headerRows)
        return .table(table)
    }
}

/// Content worth keeping: visible text, or an anchor node some link may
/// target (the renderer drops unreferenced anchors itself).
private func keepsParagraph(_ inlines: [Inline]) -> Bool {
    if !inlinesAreEmpty(inlines) {
        return true
    }
    return inlines.contains { inline in
        if case .anchor = inline { return true }
        return false
    }
}

/// Whether text appended after `inlines` sits at a whitespace boundary
/// (its leading spaces collapse away): at a block start, after emitted
/// whitespace or a line break, looking through zero-width anchors.
private func atSpaceBoundary(_ inlines: [Inline], _ start: Bool) -> Bool {
    for inline in inlines.reversed() {
        switch inline {
        case .anchor:
            continue
        case .text(let text, _):
            if text.isEmpty {
                continue
            }
            return text.unicodeScalars.last?.isRustWhitespace ?? false
        case .lineBreak:
            return true
        case .link(let content, _):
            if inlinesAreEmpty(content) {
                continue
            }
            return atSpaceBoundary(content, false)
        case .image, .noteRef:
            return false
        }
    }
    return start
}

private func mergeInlineTag(_ elem: XmlElement, _ delta: StyleDelta) -> StyleDelta {
    var delta = delta
    switch elem.local {
    case "b", "strong": delta.bold = true
    case "i", "em", "cite", "dfn", "var": delta.italic = true
    case "s", "del", "strike": delta.strike = true
    case "code", "kbd", "samp", "tt": delta.code = true
    default: break
    }
    return delta
}

private func blockText(_ block: Block) -> String {
    switch block {
    case .paragraph(let inlines):
        return inlinesToPlainText(inlines)
    case .heading(_, _, let content):
        return inlinesToPlainText(content)
    case .list(let list):
        return list.items
            .flatMap { item in item.blocks.map(blockText) }
            .joined(separator: " ")
    case .blockQuote(let blocks):
        return blocks.map(blockText).joined(separator: " ")
    case .codeBlock(_, let text):
        return text
    case .table(let table):
        return table.grid
            .flatMap { row in
                row.compactMap { slot -> String? in
                    switch slot {
                    case .origin(let cell):
                        return cell.blocks.map(blockText).joined(separator: " ")
                    case .covered:
                        return nil
                    }
                }
            }
            .joined(separator: " ")
    case .rule:
        return ""
    }
}

/// Elements that only group other content, walked through transparently.
private func isContainerTag(_ name: String) -> Bool {
    switch name {
    case "div", "section", "article", "aside", "main", "nav", "header", "footer",
        "figure", "figcaption", "center", "details", "summary", "li", "dl", "dt",
        "dd", "body":
        return true
    default:
        return false
    }
}

private func isBlockTag(_ name: String) -> Bool {
    if isContainerTag(name) {
        return true
    }
    switch name {
    case "p", "ul", "ol", "table", "blockquote", "pre", "hr", "h1", "h2", "h3",
        "h4", "h5", "h6":
        return true
    default:
        return false
    }
}

private func hasBlockChildren(_ elem: XmlElement) -> Bool {
    elem.childElements.contains { isBlockTag($0.local) }
}

// ---------------------------------------------------------------------------
// Rust-parity scalar helpers

/// Rust `str::split_whitespace`: split on Unicode whitespace, no empties.
private func splitRustWhitespace(_ s: String) -> [String] {
    s.unicodeScalars
        .split(whereSeparator: \.isRustWhitespace)
        .map { String(String.UnicodeScalarView($0)) }
}

/// Rust `str::to_ascii_lowercase`: ASCII letters only, all else verbatim.
private func asciiLowercase(_ s: some StringProtocol) -> String {
    var out = String.UnicodeScalarView()
    for c in s.unicodeScalars {
        if c >= "A", c <= "Z", let lower = Unicode.Scalar(c.value + 0x20) {
            out.append(lower)
        } else {
            out.append(c)
        }
    }
    return String(out)
}

/// Rust `u32::from_str`: optional leading `+`, one or more ASCII digits,
/// overflow fails.
func parseRustU32(_ text: some StringProtocol) -> UInt32? {
    var scalars = ArraySlice(Array(text.unicodeScalars))
    if scalars.first == "+" {
        scalars = scalars.dropFirst()
    }
    guard !scalars.isEmpty else { return nil }
    var value: UInt32 = 0
    for c in scalars {
        guard c.isAsciiDigit else { return nil }
        let (shifted, mulOverflow) = value.multipliedReportingOverflow(by: 10)
        guard !mulOverflow else { return nil }
        let (added, addOverflow) = shifted.addingReportingOverflow(UInt32(c.value - 0x30))
        guard !addOverflow else { return nil }
        value = added
    }
    return value
}

/// Rust `i64::from_str`: optional sign, one or more ASCII digits, overflow
/// fails (`i64::MIN` parses via negative accumulation).
func parseRustI64(_ text: some StringProtocol) -> Int64? {
    var scalars = ArraySlice(Array(text.unicodeScalars))
    var negative = false
    if scalars.first == "+" {
        scalars = scalars.dropFirst()
    } else if scalars.first == "-" {
        negative = true
        scalars = scalars.dropFirst()
    }
    guard !scalars.isEmpty else { return nil }
    var value: Int64 = 0
    for c in scalars {
        guard c.isAsciiDigit else { return nil }
        let digit = Int64(c.value - 0x30)
        let (shifted, mulOverflow) = value.multipliedReportingOverflow(by: 10)
        guard !mulOverflow else { return nil }
        let (stepped, stepOverflow) =
            negative
            ? shifted.subtractingReportingOverflow(digit)
            : shifted.addingReportingOverflow(digit)
        guard !stepOverflow else { return nil }
        value = stepped
    }
    return value
}
