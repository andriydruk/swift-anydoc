/// Block and inline walking for WordprocessingML parts.

/// Namespaces whose markup this frontend understands; `mc:Choice` branches
/// requiring anything else fall back to `mc:Fallback`.
private let supportedNs: [String] = [
    Ns.w,
    Ns.a,
    Ns.pic,
    Ns.wp,
    Ns.mc,
    Ns.chart,
    Ns.dgm,
    Ns.vml,
    Ns.oVml,
    Ns.wps,
    Ns.wpg,
]

final class DocxCtx {
    let pkg: Package
    let rels: Relationships
    let basePart: String
    let styles: DocxStyles
    let numbering: DocxNumbering
    let counters: MutBox<DocxCounters>
    let assets: MutBox<AssetSink>

    init(
        pkg: Package,
        rels: Relationships,
        basePart: String,
        styles: DocxStyles,
        numbering: DocxNumbering,
        counters: MutBox<DocxCounters>,
        assets: MutBox<AssetSink>
    ) {
        self.pkg = pkg
        self.rels = rels
        self.basePart = basePart
        self.styles = styles
        self.numbering = numbering
        self.counters = counters
        self.assets = assets
    }

    /// The same document-wide dependencies scoped to another package part
    /// (notes parts): only the relationships and base path change.
    func forPart(_ rels: Relationships, _ basePart: String) -> DocxCtx {
        DocxCtx(
            pkg: pkg,
            rels: rels,
            basePart: basePart,
            styles: styles,
            numbering: numbering,
            counters: counters,
            assets: assets)
    }

    /// Load an internal relationship target's bytes, resolved against this
    /// part. Failures degrade (log + `nil`) per the unified policy;
    /// resource-limit errors always propagate.
    func relPart(_ relId: String) throws -> RelTarget? {
        try relTargetBytes(pkg, rels, basePart: basePart, relId: relId)
    }

    func addAsset(_ mediaType: String, _ part: String, _ bytes: [UInt8]) throws -> AssetId {
        try assets.value.add(mediaType: mediaType, originPart: part, bytes: bytes)
    }

    /// Pick the branch of an `mc:AlternateContent` to process.
    func alternateBranch(_ alt: XmlElement) -> XmlElement? {
        Mc.alternateBranch(alt, supported: supportedNs)
    }
}

enum ParaKind {
    /// A heading: `label` is the visible number of a numbered heading (with
    /// its trailing separator), prepended to the content — headings have no
    /// native numbering in the output. `base` is the heading style's own
    /// emphasis, subtracted from its runs.
    case heading(level: UInt8, label: String?, base: Style)
    case listItem(ilvl: Int, key: ListKey, number: UInt64, label: String?)
    /// A paragraph whose style names a block container.
    case styled(BlockStyle)
    case plain
}

/// Block runs a following paragraph may extend: a list being built, and a
/// styled container. Only one is ever open, so starting either closes the
/// other.
struct Runs {
    var list: [ListEntry] = []
    var styled = StyledRun()

    init() {}

    mutating func flush(_ blocks: inout [Block]) {
        styled.flush(&blocks)
        flushList(&blocks, &list)
    }
}

/// A paragraph's content in source order: inline runs interleaved with
/// block attachments (text boxes, charts) at their anchor positions.
enum Piece {
    case inlines([Inline])
    case blocks([Block])
}

func parseBlocks(_ parent: XmlElement, _ ctx: DocxCtx) throws -> [Block] {
    var blocks: [Block] = []
    var runs = Runs()
    try collectBlocks(parent, ctx, &blocks, &runs)
    runs.flush(&blocks)
    return blocks
}

private func collectBlocks(
    _ parent: XmlElement,
    _ ctx: DocxCtx,
    _ blocks: inout [Block],
    _ runs: inout Runs
) throws {
    for child in parent.childElements {
        if child.named(Ns.mc, "AlternateContent") {
            if let branch = ctx.alternateBranch(child) {
                try collectBlocks(branch, ctx, &blocks, &runs)
            }
            continue
        }
        if child.ns != Ns.w {
            continue
        }
        switch child.local {
        case "p":
            let (kind, pieces) = try parseParagraph(child, ctx)
            emitParagraph(kind, pieces, &blocks, &runs)
        case "tbl":
            runs.flush(&blocks)
            blocks.append(contentsOf: try parseTable(child, ctx))
        case "sdt":
            if let content = child.find(Ns.w, "sdtContent") {
                try collectBlocks(content, ctx, &blocks, &runs)
            }
        case "customXml":
            try collectBlocks(child, ctx, &blocks, &runs)
        default:
            break
        }
    }
}

func emitParagraph(_ kind: ParaKind, _ pieces: [Piece], _ blocks: inout [Block], _ runs: inout Runs) {
    switch kind {
    case .listItem(let ilvl, let key, let number, let label):
        runs.styled.flush(&blocks)
        let item = piecesIntoBlocks(pieces)
        runs.list.append(ListEntry(level: ilvl, key: key, number: number, label: label, blocks: item))
    case .styled(let style):
        flushList(&blocks, &runs.list)
        for piece in pieces {
            switch piece {
            case .inlines(let inlines):
                runs.styled.push(style, inlines, &blocks)
            case .blocks(let attachments):
                runs.styled.flush(&blocks)
                blocks.append(contentsOf: attachments)
            }
        }
    case .heading(let level, let label, let base):
        runs.flush(&blocks)
        var label = label
        var emittedHeading = false
        for piece in pieces {
            switch piece {
            case .inlines(var content) where !inlinesAreEmpty(content):
                rebaseEmphasis(&content, base: base)
                if !emittedHeading {
                    if let taken = label {
                        label = nil
                        content.insert(.text(taken, style: .plain), at: 0)
                    }
                    blocks.append(.heading(level: Int(level), anchor: nil, content: content))
                    emittedHeading = true
                } else {
                    // Attachments cannot be nested in a heading, so
                    // subsequent text becomes a paragraph.
                    blocks.append(.paragraph(content))
                }
            case .inlines:
                break
            case .blocks(let attachments):
                blocks.append(contentsOf: attachments)
            }
        }
    case .plain:
        runs.flush(&blocks)
        blocks.append(contentsOf: piecesIntoBlocks(pieces))
    }
}

func parseParagraph(_ p: XmlElement, _ ctx: DocxCtx) throws -> (ParaKind, [Piece]) {
    let ppr = p.find(Ns.w, "pPr")
    let pstyleId = ppr?.find(Ns.w, "pStyle")?.attr(Ns.w, "val")

    // Direct paragraph properties overlay the style chain: an explicit
    // outlineLvl of 9 ("no outline level") turns a style heading off.
    let outlineVal: String? = ppr?.find(Ns.w, "outlineLvl")?.attr(Ns.w, "val")
    let directOutline: UInt8?? = outlineVal
        .flatMap { UInt8($0) }
        .map { l -> UInt8? in l < 9 ? .some(l + 1) : .none }
    let styleHeading: UInt8??
    if let id = pstyleId {
        styleHeading = try ctx.styles.headingLevel(id)
    } else {
        styleHeading = .none
    }
    let merged: UInt8?? = directOutline != nil ? directOutline : styleHeading
    let heading: UInt8? = merged ?? nil
    let styleBlock: BlockStyle?
    if let id = pstyleId {
        styleBlock = try ctx.styles.blockStyle(id)
    } else {
        styleBlock = nil
    }

    // Numbering resolves independently of heading semantics: a numbered
    // heading advances its sequence and keeps its number visible.
    let numbering = try resolveNumbering(ppr, pstyleId, ctx)

    // Toggle properties: the paragraph style chain's true-parity flips the
    // docDefaults base. Headings use the same resolution as body text.
    let parity: Toggles
    if let id = pstyleId {
        parity = try ctx.styles.runToggles(id)
    } else {
        parity = Toggles()
    }
    let paragraphLevel = parity.applyOver(ctx.styles.docDefaults)

    let kind: ParaKind
    if let level = heading {
        var label: String? = nil
        if let (_, key, number, numLabel) = numbering, key.marker.ordered {
            label = "\(numLabel ?? key.marker.label(number)) "
        }
        kind = .heading(level: level, label: label, base: paragraphLevel)
    } else if let (ilvl, key, number, label) = numbering {
        kind = .listItem(ilvl: ilvl, key: key, number: number, label: label)
    } else if let style = styleBlock {
        kind = .styled(style)
    } else {
        kind = .plain
    }

    var walker = InlineWalker(ctx, paragraphLevel)
    try walker.walk(p)
    return (kind, walker.finish())
}

/// Resolve a paragraph's effective numbering per ECMA-376: the direct
/// `numPr` children are tri-state and merge property-by-property with the
/// style-inherited `numPr` (a missing `numId`/`ilvl` inherits; an explicit
/// `numId` of 0 suppresses). Returns the level, list identity, effective
/// number, and composite label, advancing the instance counters.
private func resolveNumbering(
    _ ppr: XmlElement?,
    _ pstyleId: String?,
    _ ctx: DocxCtx
) throws -> (ilvl: Int, key: ListKey, number: UInt64, label: String?)? {
    let direct = ppr?.find(Ns.w, "numPr")
    let directNumId: UInt64? = direct?.find(Ns.w, "numId")?
        .attr(Ns.w, "val")
        .flatMap { UInt64($0) }
    // PARITY: Rust parses ilvl as usize (full u64 range); values above
    // Int.max clamp here. Indistinguishable in behavior — every use is
    // min-clamped to the 9-level range or compared as a list depth.
    let directIlvl: Int? = direct?.find(Ns.w, "ilvl")?
        .attr(Ns.w, "val")
        .flatMap { UInt64($0) }
        .map { Int(clamping: $0) }

    let numId: UInt64?
    if let id = directNumId {
        numId = id
    } else if let id = pstyleId {
        numId = try ctx.styles.styleNumPr(id)
    } else {
        numId = nil
    }
    guard let numId else {
        return nil
    }
    if numId == 0 {
        // numId 0 is explicitly suppressed numbering.
        return nil
    }
    guard let instance = ctx.numbering.instance(numId) else {
        Log.debug("paragraph references undefined numbering instance \(numId)")
        return nil
    }
    let ilvl: Int
    if let l = directIlvl {
        ilvl = l
    } else if let id = pstyleId {
        // Style-referenced numbering carries no usable ilvl (§17.3.1.19);
        // the level comes from the abstract levels' pStyle bindings.
        ilvl = try ctx.styles.styleNumberingLevel(id, instance) ?? 0
    } else {
        ilvl = 0
    }
    let def = instance.levels[min(ilvl, docxNumberingLevels - 1)]
    // A numFmt of "none" is explicitly suppressed numbering.
    guard let marker = def.marker else {
        return nil
    }
    let number: UInt64
    let label: String?
    if marker.ordered {
        (number, label) = ctx.counters.value.next(numId: numId, ilvl: ilvl, instance: instance)
    } else {
        (number, label) = (0, nil)
    }
    return (ilvl: ilvl, key: ListKey(instance: numId, marker: marker), number: number, label: label)
}

struct InlineWalker {
    let ctx: DocxCtx
    let base: Style
    var pieces: [Piece] = []
    var current: [Inline] = []
    var fields: [FieldFrame] = []

    init(_ ctx: DocxCtx, _ base: Style) {
        self.ctx = ctx
        self.base = base
    }

    mutating func push(_ inline: Inline) {
        if fields.isEmpty {
            current.append(inline)
        } else if fields[fields.count - 1].inResult {
            fields[fields.count - 1].inlines.append(inline)
        }
    }

    /// Attach block content at the current position in run order.
    mutating func pushBlocks(_ blocks: [Block]) {
        if blocks.isEmpty {
            return
        }
        if !current.isEmpty {
            pieces.append(.inlines(current))
            current = []
        }
        pieces.append(.blocks(blocks))
    }

    mutating func walk(_ elem: XmlElement) throws {
        for child in elem.childElements {
            if child.named(Ns.mc, "AlternateContent") {
                if let branch = ctx.alternateBranch(child) {
                    try walk(branch)
                }
                continue
            }
            if child.ns != Ns.w {
                continue
            }
            switch child.local {
            case "pPr":
                break
            case "r":
                try walkRun(child)
            case "hyperlink":
                let target = hyperlinkLinkTarget(child)
                var inner = InlineWalker(ctx, base)
                try inner.walk(child)
                let (content, attachments) = splitPieces(inner.finish())
                if let target {
                    // An empty label still keeps a resolved target: the
                    // renderer shows the URL as the link text.
                    push(.link(content: content, target: target))
                } else {
                    for inline in content {
                        push(inline)
                    }
                }
                pushBlocks(attachments)
            case "fldSimple":
                let instr = child.attr(Ns.w, "instr") ?? ""
                var inner = InlineWalker(ctx, base)
                try inner.walk(child)
                let (content, attachments) = splitPieces(inner.finish())
                pushFieldResult(instr, content)
                pushBlocks(attachments)
            case "bookmarkStart":
                if let name = child.attr(Ns.w, "name"), name != "_GoBack" {
                    push(.anchor(name))
                }
            case "sdt":
                if let content = child.find(Ns.w, "sdtContent") {
                    try walk(content)
                }
            // `moveTo` is moved-in text — part of the final document;
            // `customXml` wraps ordinary run content.
            case "smartTag", "ins", "bdo", "dir", "moveTo", "customXml":
                try walk(child)
            default:
                break
            }
        }
    }

    func hyperlinkLinkTarget(_ link: XmlElement) -> LinkTarget? {
        if let id = link.attrQualified(Ns.r, "id"), let rel = ctx.rels.get(id) {
            return classifyRelTarget(external: rel.mode == .external, target: rel.target)
        }
        return link.attr(Ns.w, "anchor").map { LinkTarget.anchor($0) }
    }

    mutating func walkRun(_ run: XmlElement) throws {
        let style: Style
        if let rpr = run.find(Ns.w, "rPr") {
            // Character-style chain: another toggle layer over the
            // paragraph-level value. Direct formatting is absolute.
            let charParity: Toggles
            if let id = rpr.find(Ns.w, "rStyle")?.attr(Ns.w, "val") {
                charParity = try ctx.styles.runToggles(id)
            } else {
                charParity = Toggles()
            }
            let withChar = charParity.applyOver(base)
            style = rprDelta(rpr).apply(withChar)
        } else {
            style = base
        }
        try walkRunContent(run, style)
    }

    mutating func walkRunContent(_ run: XmlElement, _ style: Style) throws {
        for child in run.childElements {
            if child.named(Ns.mc, "AlternateContent") {
                if let branch = ctx.alternateBranch(child) {
                    try walkRunContent(branch, style)
                }
                continue
            }
            if child.ns != Ns.w {
                continue
            }
            switch child.local {
            case "t":
                // Open XML text-space contract: edge whitespace in w:t
                // is significant only under xml:space="preserve";
                // unmarked edges are discarded (Word never renders them).
                // Only XML whitespace counts: a no-break space is
                // character data, not whitespace the contract may drop.
                let preserved = child.attrQualified(Ns.xml, "space") == "preserve"
                let raw = child.text()
                // The contract applies to the XML text, before
                // normalization turns a no-break space into a space.
                let text = cleanText(preserved ? raw[...] : trimXmlSpace(raw))
                if !text.isEmpty {
                    push(.text(text, style: style))
                }
            case "tab", "ptab":
                push(.text(" ", style: .plain))
            // Markdown has no pages or columns, but every w:br still
            // separates the runs around it: dropping a page break
            // outright would join the words on either side. One left at
            // the end of a paragraph is trimmed when the block renders.
            case "br":
                push(.lineBreak)
            case "cr":
                push(.lineBreak)
            case "footnoteReference":
                if let id = child.attr(Ns.w, "id") {
                    push(.noteRef("fn\(id)"))
                }
            case "endnoteReference":
                if let id = child.attr(Ns.w, "id") {
                    push(.noteRef("en\(id)"))
                }
            case "drawing", "pict", "object":
                try walkDrawing(child)
            case "fldChar":
                switch child.attr(Ns.w, "fldCharType") {
                case "begin":
                    fields.append(FieldFrame())
                case "separate":
                    if !fields.isEmpty {
                        fields[fields.count - 1].inResult = true
                    }
                case "end":
                    if let frame = fields.popLast() {
                        pushFieldResult(frame.instr, frame.inlines)
                    }
                default:
                    break
                }
            case "instrText":
                if !fields.isEmpty {
                    fields[fields.count - 1].instr += child.text()
                }
            default:
                break
            }
        }
    }

    /// Drawings, VML picts, and embedded objects: text boxes become block
    /// attachments at this position; images/charts/diagrams/objects resolve
    /// through relationships.
    mutating func walkDrawing(_ elem: XmlElement) throws {
        // Text boxes first: their content is the drawing's content.
        var boxes: [XmlElement] = []
        collectTextBoxes(elem, &boxes)
        if !boxes.isEmpty {
            var blocks: [Block] = []
            for tb in boxes {
                blocks.append(contentsOf: try parseBlocks(tb, ctx))
            }
            pushBlocks(blocks)
            return
        }

        let descr = elem.firstDescendant(Ns.wp, "docPr")?
            .attr(Ns.wp, "descr")
            .map { cleanText($0) } ?? ""

        // Charts and SmartArt render their textual content.
        if let chartRef = elem.firstDescendant(Ns.chart, "chart"),
            let relId = chartRef.attrQualified(Ns.r, "id")
        {
            pushBlocks(try chartBlocks(relId))
            return
        }
        if let relIds = elem.firstDescendant(Ns.dgm, "relIds"),
            let relId = relIds.attrQualified(Ns.r, "dm")
        {
            pushBlocks(try diagramBlocks(relId))
            return
        }

        // Embedded OLE objects come before images: standard Word OLE markup
        // carries a VML preview image next to the o:OLEObject, and the
        // object's identity and payload must win over its preview.
        if let ole = elem.firstDescendant(Ns.oVml, "OLEObject") {
            let progId = ole.attr(Ns.oVml, "ProgID") ?? "object"
            let alt = descr.isBlank ? "Embedded object: \(progId)" : descr
            var source: ImageSource? = nil
            if let relId = ole.attrQualified(Ns.r, "id"),
                let (part, bytes) = try ctx.relPart(relId)
            {
                source = .asset(try ctx.addAsset("application/vnd.ms-ole-object", part, bytes))
            }
            push(.image(alt: alt, source: source ?? .unavailable))
            return
        }

        // Bitmap images: DrawingML blip or VML imagedata.
        var imageRel: String? = nil
        if let blip = elem.firstDescendant(Ns.a, "blip") {
            imageRel = blip.attrQualified(Ns.r, "embed") ?? blip.attrQualified(Ns.r, "link")
        }
        if imageRel == nil, let imagedata = elem.firstDescendant(Ns.vml, "imagedata") {
            imageRel = imagedata.attrQualified(Ns.r, "id")
        }
        if let relId = imageRel {
            // External-mode targets (`r:link`) become external image
            // sources; embedded targets are retained as assets.
            let source = try relImageSource(
                ctx.pkg, ctx.rels, basePart: ctx.basePart, assets: ctx.assets, relId: relId)
            if let source {
                push(.image(alt: descr, source: source))
            } else if !descr.isBlank {
                push(.image(alt: descr, source: .unavailable))
            }
            return
        }

        if !descr.isBlank {
            push(.image(alt: descr, source: .unavailable))
        }
    }

    /// Textual extraction of a chart part via `DrawingMl`.
    func chartBlocks(_ relId: String) throws -> [Block] {
        guard let (part, bytes) = try ctx.relPart(relId) else {
            return []
        }
        do {
            return DrawingMl.chartBlocks(try parseXml(bytes))
        } catch let e as ConvertError {
            if e.isFatal { throw e }
            Log.warn("skipping corrupt chart part \(part): \(e.message)")
            return []
        }
    }

    /// Textual extraction of a SmartArt data part via `DrawingMl`.
    func diagramBlocks(_ relId: String) throws -> [Block] {
        guard let (part, bytes) = try ctx.relPart(relId) else {
            return []
        }
        do {
            return DrawingMl.diagramBlocks(try parseXml(bytes))
        } catch let e as ConvertError {
            if e.isFatal { throw e }
            Log.warn("skipping corrupt diagram part \(part): \(e.message)")
            return []
        }
    }

    mutating func pushFieldResult(_ instr: String, _ content: [Inline]) {
        for inline in fieldResult(instr, content) {
            push(inline)
        }
    }

    mutating func finish() -> [Piece] {
        while let frame = fields.popLast() {
            for inline in frame.inlines {
                push(inline)
            }
        }
        if !current.isEmpty {
            pieces.append(.inlines(current))
            current = []
        }
        return pieces
    }
}

func splitPieces(_ pieces: [Piece]) -> ([Inline], [Block]) {
    var inlines: [Inline] = []
    var blocks: [Block] = []
    for piece in pieces {
        switch piece {
        case .inlines(let i): inlines.append(contentsOf: i)
        case .blocks(let b): blocks.append(contentsOf: b)
        }
    }
    return (inlines, blocks)
}

func piecesIntoBlocks(_ pieces: [Piece]) -> [Block] {
    var blocks: [Block] = []
    for piece in pieces {
        switch piece {
        // Visually empty inlines still become a paragraph: a
        // bookmark-only one carries the anchor link resolution binds to.
        case .inlines(let inlines): blocks.append(.paragraph(inlines))
        case .blocks(let attachments): blocks.append(contentsOf: attachments)
        }
    }
    return blocks
}

/// Find text-box content (`w:txbxContent`) in a drawing or VML pict, skipping
/// `mc:Fallback` so AlternateContent shapes aren't collected twice.
private func collectTextBoxes(_ elem: XmlElement, _ out: inout [XmlElement]) {
    for child in elem.childElements {
        if child.named(Ns.mc, "Fallback") {
            continue
        }
        if child.named(Ns.w, "txbxContent") {
            out.append(child)
        } else {
            collectTextBoxes(child, &out)
        }
    }
}

/// Rust `str::trim_matches(is_xml_space)`: strip XML whitespace from both
/// ends only.
// ---------------------------------------------------------------------------
// Tables

private struct TcInfo {
    var elem: XmlElement?
    /// Legacy `hMerge` continuation cells folded into this origin.
    var merged: [XmlElement]
    var colSpan: Int
    var rowSpan: Int
    /// vMerge continuation: this position belongs to the origin above.
    var covered: Bool

    /// Empty single-column filler for `gridBefore`/`gridAfter` positions.
    static func filler() -> TcInfo {
        TcInfo(elem: nil, merged: [], colSpan: 1, rowSpan: 1, covered: false)
    }
}

/// A `w:trPr` grid filler count (`gridBefore`/`gridAfter`).
private func gridFiller(_ trpr: XmlElement?, _ name: String) -> Int {
    let count = trpr?.find(Ns.w, name)?
        .attr(Ns.w, "val")
        .flatMap { UInt64($0) } ?? 0
    return Int(min(count, 1000))
}

func parseTable(_ tbl: XmlElement, _ ctx: DocxCtx) throws -> [Block] {
    // Collect the raw cell matrix first so vertical merges can be resolved
    // into row spans before the grid is built. gridBefore/gridAfter filler
    // materializes as empty cells so every cell keeps its grid column.
    var matrix: [[TcInfo]] = []
    for tr in tbl.findAll(Ns.w, "tr") {
        let trpr = tr.find(Ns.w, "trPr")
        var row: [TcInfo] = []
        row.append(contentsOf: (0..<gridFiller(trpr, "gridBefore")).map { _ in TcInfo.filler() })
        collectRowCells(tr, &row)
        row.append(contentsOf: (0..<gridFiller(trpr, "gridAfter")).map { _ in TcInfo.filler() })
        matrix.append(row)
    }
    // Active vertical-merge chains by grid column.
    var active: [Int: (row: Int, idx: Int)] = [:]
    for r in 0..<matrix.count {
        var col = 0
        var nextActive: [(Int, (row: Int, idx: Int))] = []
        for i in 0..<matrix[r].count {
            let covered = matrix[r][i].covered
            let span = matrix[r][i].colSpan
            if covered {
                if let origin = active[col] {
                    matrix[origin.row][origin.idx].rowSpan += 1
                    for c in col..<(col + span) {
                        nextActive.append((c, origin))
                    }
                } else {
                    matrix[r][i].covered = false  // stray continuation
                }
            } else {
                for c in col..<(col + span) {
                    nextActive.append((c, (row: r, idx: i)))
                }
            }
            col += span
        }
        active = Dictionary(nextActive, uniquingKeysWith: { _, new in new })
    }

    // tblHeader is ST_OnOff: an explicit false value is not a header row.
    var headerRows = 0
    for tr in tbl.findAll(Ns.w, "tr") {
        guard let trpr = tr.find(Ns.w, "trPr"), onOff(trpr, "tblHeader") == true else {
            break
        }
        headerRows += 1
    }

    var builder = GridBuilder()
    for row in matrix {
        builder.nextRow()
        for tc in row {
            if tc.covered {
                for _ in 0..<tc.colSpan {
                    builder.covered()
                }
            } else {
                var blocks: [Block]
                if let elem = tc.elem {
                    blocks = try parseBlocks(elem, ctx)
                } else {
                    blocks = []
                }
                for merged in tc.merged {
                    blocks.append(contentsOf: try parseBlocks(merged, ctx))
                }
                try builder.place(
                    Cell.spanning(
                        blocks,
                        colSpan: UInt32(truncatingIfNeeded: tc.colSpan),
                        rowSpan: UInt32(truncatingIfNeeded: tc.rowSpan)))
            }
        }
    }
    var table = builder.finish(.data)
    if table.grid.isEmpty {
        return []
    }
    table.headerRows = resolveHeaderRows(table, declared: headerRows)
    return [.table(table)]
}

private func collectRowCells(_ parent: XmlElement, _ cells: inout [TcInfo]) {
    for child in parent.childElements {
        if child.ns != Ns.w {
            continue
        }
        switch child.local {
        case "tc":
            let tcpr = child.find(Ns.w, "tcPr")
            let covered: Bool
            if let vmerge = tcpr?.find(Ns.w, "vMerge") {
                covered = vmerge.attr(Ns.w, "val") != "restart"
            } else {
                covered = false
            }
            let colSpan = tcpr?.find(Ns.w, "gridSpan")?
                .attr(Ns.w, "val")
                .flatMap { UInt64($0) }
                .map { Int(min(max($0, 1), 1000)) } ?? 1
            // Legacy hMerge: a non-restart hMerge cell folds into the
            // preceding origin, widening its span.
            let hmergeCont: Bool
            if let hmerge = tcpr?.find(Ns.w, "hMerge") {
                hmergeCont = hmerge.attr(Ns.w, "val") != "restart"
            } else {
                hmergeCont = false
            }
            if hmergeCont, !cells.isEmpty, !cells[cells.count - 1].covered {
                cells[cells.count - 1].colSpan += colSpan
                cells[cells.count - 1].merged.append(child)
                continue
            }
            cells.append(
                TcInfo(elem: child, merged: [], colSpan: colSpan, rowSpan: 1, covered: covered))
        case "sdt":
            if let content = child.find(Ns.w, "sdtContent") {
                collectRowCells(content, &cells)
            }
        case "customXml":
            collectRowCells(child, &cells)
        default:
            break
        }
    }
}
