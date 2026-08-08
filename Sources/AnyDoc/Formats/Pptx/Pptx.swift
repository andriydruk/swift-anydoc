/// OOXML PresentationML (.pptx / .pptm / .ppsx): slides in `sldIdLst` order,
/// with the full text cascade - slide -> layout -> master placeholder /
/// `txStyles` -> presentation defaults. Speaker notes are included (fixed
/// policy), rendered as a quote after each slide's content.

private let layoutRel =
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout"
private let masterRel =
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster"
private let notesRel =
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide"
private let slideRel =
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"

/// Namespaces whose markup this frontend understands; `mc:Choice` branches
/// requiring anything else fall back to `mc:Fallback`.
private let supportedNs: [String] = [Ns.p, Ns.a, Ns.r, Ns.mc]

private struct LayoutInfo {
    var placeholders: [PptxCascade.Placeholder]
    var masterPath: String?
}

private struct MasterInfo {
    var title = PptxCascade.LevelStyle()
    var body = PptxCascade.LevelStyle()
    var other = PptxCascade.LevelStyle()
    var placeholders: [PptxCascade.Placeholder] = []
}

func parsePptx(_ bytes: [UInt8]) throws -> Document {
    let pkg: Package
    do {
        pkg = try Package.open(bytes)
    } catch let e as ConvertError {
        throw probeOle(bytes) ?? e
    }

    // OPC part discovery: the presentation part comes from the package-level
    // officeDocument relationship, with the conventional path as fallback.
    let rootRels = try readRels(pkg, "_rels/.rels")
    let presPart = rootRels.firstOfType(RelType.officeDocument)
        .flatMap { try? resolvePackageReference(basePart: "", reference: $0.target) }
        .map(\.path) ?? "ppt/presentation.xml"
    let pres = try pkg.requiredXmlPart(presPart)
    let presRels = try readRels(pkg, relsPartFor(presPart))

    let defaultText = PptxCascade.parseLevelStyles(pres.firstDescendant(Ns.p, "defaultTextStyle"))

    let slidePaths: [String] = pres.firstDescendant(Ns.p, "sldIdLst").map { list in
        list.findAll(Ns.p, "sldId")
            .compactMap { $0.attrQualified(Ns.r, "id") }
            .compactMap { presRels.internalTarget($0) }
            .compactMap { try? resolvePackageReference(basePart: presPart, reference: $0).path }
    } ?? []
    if slidePaths.isEmpty {
        throw ConvertError.malformedPart(presPart, "presentation has no slide list")
    }

    let assets = MutBox(AssetSink())
    var layouts: [String: LayoutInfo] = [:]
    var masters: [String: MasterInfo] = [:]
    var blocks: [Block] = []
    var failed = 0
    let instanceCounter = MutBox(UInt64(0))
    // Every slide has a start anchor id so internal slide-to-slide links
    // resolve after concatenation; the anchor node is emitted only on
    // slides some link actually targets.
    var slideAnchors: [String: String] = [:]
    for (i, p) in slidePaths.enumerated() {
        // Last insert wins for a repeated slide path, as in the Rust collect.
        slideAnchors[p] = "slide-\(i + 1)"
    }
    var allRels: [Relationships] = []
    allRels.reserveCapacity(slidePaths.count)
    for p in slidePaths {
        allRels.append(try readRels(pkg, relsPartFor(p)))
    }
    var targeted: Set<String> = []
    for (p, rels) in zip(slidePaths, allRels) {
        for (_, rel) in rels.all
        where rel.relType == slideRel && rel.mode == .internalMode {
            if let t = try? resolvePackageReference(basePart: p, reference: rel.target),
                slideAnchors[t.path] != nil
            {
                targeted.insert(t.path)
            }
        }
    }

    for (slideIndex, slidePath) in slidePaths.enumerated() {
        guard let tree = try pkg.optionalXmlPart(slidePath) else {
            Log.warn("skipping unusable slide \(slidePath)")
            failed += 1
            continue
        }
        guard
            let spTree = tree.find(Ns.p, "sld")?.find(Ns.p, "cSld")?.find(Ns.p, "spTree")
        else {
            Log.warn("skipping slide \(slidePath): no shape tree")
            failed += 1
            continue
        }
        let slideRels = allRels[slideIndex]

        let layoutPath = relTargetOfType(slideRels, slidePath, layoutRel)
        if let lp = layoutPath, layouts[lp] == nil {
            let info = try loadLayout(pkg, lp)
            if let mp = info.masterPath, masters[mp] == nil {
                masters[mp] = try loadMaster(pkg, mp)
            }
            layouts[lp] = info
        }
        let layout = layoutPath.flatMap { layouts[$0] }
        let master = layout.flatMap(\.masterPath).flatMap { masters[$0] }

        let ctx = SlideCtx(
            pkg: pkg,
            rels: slideRels,
            basePart: slidePath,
            assets: assets,
            defaultText: defaultText,
            layout: layout,
            master: master,
            instanceCounter: instanceCounter,
            slideAnchors: slideAnchors)
        if targeted.contains(slidePath), let anchor = slideAnchors[slidePath] {
            blocks.append(.paragraph([.anchor(anchor)]))
        }
        try parseShapes(spTree, ctx, &blocks)

        // Speaker notes, set off as a quote (fixed policy: included).
        if let notesPath = relTargetOfType(slideRels, slidePath, notesRel),
            let notesTree = try pkg.optionalXmlPart(notesPath)
        {
            let notesRels = try readRels(pkg, relsPartFor(notesPath))
            let notesCtx = ctx.forNotes(notesRels, notesPath)
            var notesBlocks: [Block] = []
            for sp in notesTree.descendants(Ns.p, "sp") {
                // Keep note text bodies (real producers use a body
                // placeholder; LibreOffice writes plain text boxes) but skip
                // the slide-image and chrome placeholders.
                if let t = placeholderType(sp),
                    t == "sldImg" || t == "sldNum" || t == "hdr" || t == "ftr" || t == "dt"
                {
                    continue
                }
                if let tx = sp.find(Ns.p, "txBody") {
                    try parseTextBody(tx, notesCtx, nil, &notesBlocks)
                }
            }
            if !notesBlocks.isEmpty {
                blocks.append(.blockQuote(notesBlocks))
            }
        }
    }
    if failed == slidePaths.count {
        throw ConvertError.malformed("no slide in the presentation could be read")
    }

    return Document(blocks: blocks, notes: [], assets: assets.value.assets)
}

private func relTargetOfType(
    _ rels: Relationships, _ base: String, _ relType: String
) -> String? {
    // firstOfType picks the lowest id, so duplicate relationships resolve
    // deterministically.
    rels.firstOfType(relType)
        .flatMap { try? resolvePackageReference(basePart: base, reference: $0.target) }
        .map(\.path)
}

private func loadLayout(_ pkg: Package, _ layoutPath: String) throws -> LayoutInfo {
    let placeholders: [PptxCascade.Placeholder]
    if let tree = try pkg.optionalXmlPart(layoutPath) {
        placeholders =
            tree.firstDescendant(Ns.p, "spTree").map(PptxCascade.collectPlaceholders) ?? []
    } else {
        placeholders = []
    }
    let rels = try readRels(pkg, relsPartFor(layoutPath))
    let masterPath = relTargetOfType(rels, layoutPath, masterRel)
    return LayoutInfo(placeholders: placeholders, masterPath: masterPath)
}

private func loadMaster(_ pkg: Package, _ masterPath: String) throws -> MasterInfo {
    var info = MasterInfo()
    if let tree = try pkg.optionalXmlPart(masterPath) {
        if let txStyles = tree.firstDescendant(Ns.p, "txStyles") {
            info.title = PptxCascade.parseLevelStyles(txStyles.find(Ns.p, "titleStyle"))
            info.body = PptxCascade.parseLevelStyles(txStyles.find(Ns.p, "bodyStyle"))
            info.other = PptxCascade.parseLevelStyles(txStyles.find(Ns.p, "otherStyle"))
        }
        if let spTree = tree.firstDescendant(Ns.p, "spTree") {
            info.placeholders = PptxCascade.collectPlaceholders(spTree)
        }
    }
    return info
}

private struct SlideCtx {
    let pkg: Package
    let rels: Relationships
    let basePart: String
    let assets: MutBox<AssetSink>
    let defaultText: PptxCascade.LevelStyle
    let layout: LayoutInfo?
    let master: MasterInfo?
    /// Per-text-body list instance ids, unique document-wide.
    let instanceCounter: MutBox<UInt64>
    /// Slide part path -> the slide's start anchor id, for internal
    /// slide-to-slide links.
    let slideAnchors: [String: String]

    /// Slide-to-slide relationships become anchor links to the target
    /// slide's start anchor; everything else classifies as usual.
    func linkTarget(_ rel: Relationship) -> LinkTarget {
        if rel.mode == .internalMode,
            let t = try? resolvePackageReference(basePart: basePart, reference: rel.target),
            let anchor = slideAnchors[t.path]
        {
            return .anchor(anchor)
        }
        return classifyRelTarget(external: rel.mode == .external, target: rel.target)
    }

    /// Fold the cascade for a paragraph, outermost first.
    func baseProps(
        _ ph: PhInfo?, _ shapeStyles: PptxCascade.LevelStyle, _ lvl: Int
    ) -> PptxCascade.TextProps {
        var props = defaultText.level(lvl)
        if let master {
            let classStyle: PptxCascade.LevelStyle
            switch ph.map({ PptxCascade.titleClass($0.phType) }) {
            case .some(.title): classStyle = master.title
            case .some(.body): classStyle = master.body
            case .none: classStyle = master.other
            }
            props = props.merge(classStyle.level(lvl))
            if let ph,
                let hit = PptxCascade.matchPlaceholder(master.placeholders, ph.phType, ph.idx)
            {
                props = props.merge(hit.styles.level(lvl))
            }
        }
        if let layout, let ph,
            let hit = PptxCascade.matchPlaceholder(layout.placeholders, ph.phType, ph.idx)
        {
            props = props.merge(hit.styles.level(lvl))
        }
        return props.merge(shapeStyles.level(lvl))
    }

    /// Load an internal relationship target's bytes, resolved against this
    /// part. Failures degrade (log + `nil`) per the unified policy;
    /// resource-limit errors always propagate.
    func relPart(_ relId: String) throws -> RelTarget? {
        try relTargetBytes(pkg, rels, basePart: basePart, relId: relId)
    }

    /// The same document-wide dependencies scoped to a notes part: only the
    /// relationships and base path change, and the cascade loses its
    /// layout/master layers.
    func forNotes(_ rels: Relationships, _ basePart: String) -> SlideCtx {
        SlideCtx(
            pkg: pkg,
            rels: rels,
            basePart: basePart,
            assets: assets,
            defaultText: defaultText,
            layout: nil,
            master: nil,
            instanceCounter: instanceCounter,
            slideAnchors: slideAnchors)
    }
}

private struct PhInfo {
    var phType: String
    var idx: String?
}

private func placeholderType(_ sp: XmlElement) -> String? {
    sp.firstDescendant(Ns.p, "ph").map { $0.attr(Ns.p, "type") ?? "body" }
}

/// Rust `str::parse::<usize>()` for level indices.
// PARITY: values above Int.max clamp here where Rust holds the full u64
// range. Indistinguishable in behavior — every use is min-clamped to the
// 9-level range or compared as a list depth.
private func parseUsize(_ s: String) -> Int? {
    UInt64(s).map { Int(clamping: $0) }
}

private func parseShapes(
    _ parent: XmlElement, _ ctx: SlideCtx, _ blocks: inout [Block]
) throws {
    for child in parent.childElements {
        if child.named(Ns.mc, "AlternateContent") {
            if let branch = Mc.alternateBranch(child, supported: supportedNs) {
                try parseShapes(branch, ctx, &blocks)
            }
            continue
        }
        guard child.ns == Ns.p else {
            continue
        }
        switch child.local {
        // Connector shapes carry the same `p:txBody` as plain shapes.
        case "sp", "cxnSp":
            try parseShape(child, ctx, &blocks)
        case "grpSp":
            try parseShapes(child, ctx, &blocks)
        case "graphicFrame":
            try parseGraphicFrame(child, ctx, &blocks)
        case "pic":
            let descr = child.firstDescendant(Ns.p, "cNvPr")
                .flatMap { $0.attr(Ns.p, "descr") }
                .map(cleanText) ?? ""
            let rid = child.firstDescendant(Ns.a, "blip").flatMap { b in
                b.attrQualified(Ns.r, "embed") ?? b.attrQualified(Ns.r, "link")
            }
            // External-mode targets (`r:link`) become external image
            // sources; embedded targets are retained as assets.
            let source: ImageSource?
            if let rid {
                source = try relImageSource(
                    ctx.pkg, ctx.rels, basePart: ctx.basePart, assets: ctx.assets, relId: rid)
            } else {
                source = nil
            }
            if source != nil || !descr.isBlank {
                blocks.append(.paragraph([.image(alt: descr, source: source ?? .unavailable)]))
            }
        default:
            break
        }
    }
}

private func parseShape(
    _ sp: XmlElement, _ ctx: SlideCtx, _ blocks: inout [Block]
) throws {
    let ph = sp.firstDescendant(Ns.p, "ph").map {
        PhInfo(phType: $0.attr(Ns.p, "type") ?? "body", idx: $0.attr(Ns.p, "idx"))
    }
    if let ph, ph.phType == "sldNum" || ph.phType == "dt" || ph.phType == "ftr" {
        return
    }
    guard let tx = sp.find(Ns.p, "txBody") else {
        return
    }
    // Titles get heading semantics but keep their shape-order position.
    if let ph, PptxCascade.titleClass(ph.phType) == .title {
        try pushTitleHeading(tx, ctx, ph, &blocks)
    } else {
        try parseTextBody(tx, ctx, ph, &blocks)
    }
}

/// Collapse a title placeholder's paragraphs into one slide heading. Runs
/// resolve through the full cascade like body text.
private func pushTitleHeading(
    _ tx: XmlElement, _ ctx: SlideCtx, _ ph: PhInfo?, _ blocks: inout [Block]
) throws {
    let shapeStyles = PptxCascade.parseLevelStyles(tx.find(Ns.a, "lstStyle"))
    var inlines: [Inline] = []
    for p in tx.findAll(Ns.a, "p") {
        let ppr = p.find(Ns.a, "pPr")
        let lvl = ppr.flatMap { $0.attr(Ns.a, "lvl") }.flatMap(parseUsize) ?? 0
        var props = ctx.baseProps(ph, shapeStyles, lvl)
        if let ppr {
            props = props.merge(PptxCascade.paragraphProps(ppr))
        }
        let base = props.delta.resolve()
        var para = parseParaInlines(p, ctx, base)
        if inlinesAreEmpty(para) {
            continue
        }
        rebaseEmphasis(&para, base: base)
        if !inlines.isEmpty {
            inlines.append(.lineBreak)
        }
        inlines.append(contentsOf: para)
    }
    if !inlinesAreEmpty(inlines) {
        let anchor = inlinesToPlainText(inlines)
        blocks.append(.heading(level: 2, anchor: anchor, content: inlines))
    }
}

private func parseTextBody(
    _ tx: XmlElement, _ ctx: SlideCtx, _ ph: PhInfo?, _ blocks: inout [Block]
) throws {
    let shapeStyles = PptxCascade.parseLevelStyles(tx.find(Ns.a, "lstStyle"))
    // Text-body count is bounded by the XML node cap, far below u64 range.
    ctx.instanceCounter.value += 1
    let instance = ctx.instanceCounter.value
    var counters = [UInt64](repeating: 0, count: PptxCascade.levels)
    var started = [Bool](repeating: false, count: PptxCascade.levels)
    var listRun: [ListEntry] = []

    for p in tx.findAll(Ns.a, "p") {
        let ppr = p.find(Ns.a, "pPr")
        let lvl = ppr.flatMap { $0.attr(Ns.a, "lvl") }.flatMap(parseUsize) ?? 0
        var props = ctx.baseProps(ph, shapeStyles, lvl)
        if let ppr {
            props = props.merge(PptxCascade.paragraphProps(ppr))
        }
        let base = props.delta.resolve()
        let inlines = parseParaInlines(p, ctx, base)
        if inlinesAreEmpty(inlines) {
            flushList(&blocks, &listRun)
            continue
        }
        switch props.bullet {
        case .autoNum(let marker, let start, let wrap):
            let lvlIdx = min(lvl, PptxCascade.levels - 1)
            let number: UInt64
            if started[lvlIdx] {
                number = counters[lvlIdx].saturatingAdding(1)
            } else {
                started[lvlIdx] = true
                number = start
            }
            counters[lvlIdx] = number
            for deeper in (lvlIdx + 1)..<PptxCascade.levels {
                started[deeper] = false
            }
            listRun.append(
                ListEntry(
                    level: lvl,
                    key: ListKey(instance: instance, marker: marker),
                    number: number,
                    label: wrap.label(marker, number),
                    blocks: [.paragraph(inlines)]))
        case .char:
            listRun.append(
                ListEntry(
                    level: lvl,
                    key: ListKey(instance: instance, marker: .bullet),
                    number: 0,
                    label: nil,
                    blocks: [.paragraph(inlines)]))
        case .none, .inherit:
            flushList(&blocks, &listRun)
            blocks.append(.paragraph(inlines))
        }
    }
    flushList(&blocks, &listRun)
}

private func parseParaInlines(_ p: XmlElement, _ ctx: SlideCtx, _ base: Style) -> [Inline] {
    var out: [Inline] = []
    for child in p.childElements {
        guard child.ns == Ns.a else {
            continue
        }
        switch child.local {
        case "r", "fld":
            let rpr = child.find(Ns.a, "rPr")
            let text = cleanText(child.find(Ns.a, "t")?.text() ?? "")
            if text.isEmpty {
                continue
            }
            let style = rpr.map { PptxCascade.rprDelta($0).apply(base) } ?? base
            let inline = Inline.text(text, style: style)
            let target = rpr
                .flatMap { $0.find(Ns.a, "hlinkClick") }
                .flatMap { $0.attrQualified(Ns.r, "id") }
                .flatMap { ctx.rels.get($0) }
                .map { ctx.linkTarget($0) }
            if let target {
                out.append(.link(content: [inline], target: target))
            } else {
                out.append(inline)
            }
        case "br":
            out.append(.lineBreak)
        default:
            break
        }
    }
    return out
}

private func parseGraphicFrame(
    _ frame: XmlElement, _ ctx: SlideCtx, _ blocks: inout [Block]
) throws {
    if let tbl = frame.firstDescendant(Ns.a, "tbl") {
        try parseTable(tbl, ctx, &blocks)
        return
    }
    // Embedded OLE objects: retain identity, media type, and payload.
    if let ole = frame.firstDescendant(Ns.p, "oleObj") {
        let progId = ole.attr(Ns.p, "progId") ?? "object"
        let name = (ole.attr(Ns.p, "name") ?? "").rustTrim()
        let alt = name.isEmpty ? "Embedded object: \(progId)" : name
        var source: ImageSource? = nil
        if let rid = ole.attrQualified(Ns.r, "id"),
            let (part, bytes) = try ctx.relPart(rid)
        {
            source = .asset(
                try ctx.assets.value.add(
                    mediaType: "application/vnd.ms-ole-object", originPart: part, bytes: bytes))
        }
        blocks.append(.paragraph([.image(alt: alt, source: source ?? .unavailable)]))
        return
    }
    if let chartRef = frame.firstDescendant(Ns.chart, "chart"),
        let rid = chartRef.attrQualified(Ns.r, "id"),
        let (part, bytes) = try ctx.relPart(rid)
    {
        do {
            let root = try parseXml(bytes)
            blocks.append(contentsOf: DrawingMl.chartBlocks(root))
        } catch let e as ConvertError where e.isFatal {
            throw e
        } catch let e as ConvertError {
            Log.warn("skipping corrupt chart part \(part): \(e.message)")
        }
        return
    }
    if let relIds = frame.firstDescendant(Ns.dgm, "relIds"),
        let rid = relIds.attrQualified(Ns.r, "dm"),
        let (part, bytes) = try ctx.relPart(rid)
    {
        do {
            let root = try parseXml(bytes)
            blocks.append(contentsOf: DrawingMl.diagramBlocks(root))
        } catch let e as ConvertError where e.isFatal {
            throw e
        } catch let e as ConvertError {
            Log.warn("skipping corrupt diagram part \(part): \(e.message)")
        }
    }
}

/// DrawingML slide table: origins carry `gridSpan`/`rowSpan`; merged
/// continuation cells (`hMerge`/`vMerge`) consume covered positions.
private func parseTable(
    _ tbl: XmlElement, _ ctx: SlideCtx, _ blocks: inout [Block]
) throws {
    let firstRow = tbl.find(Ns.a, "tblPr")
        .flatMap { $0.attr(Ns.a, "firstRow") }
        .map { $0 == "1" || $0 == "true" } ?? false
    let headerRows = firstRow ? 1 : 0
    var builder = GridBuilder()
    for tr in tbl.findAll(Ns.a, "tr") {
        builder.nextRow()
        for tc in tr.findAll(Ns.a, "tc") {
            let hMerge = tc.attr(Ns.a, "hMerge")
            let vMerge = tc.attr(Ns.a, "vMerge")
            let merged = hMerge == "1" || hMerge == "true" || vMerge == "1" || vMerge == "true"
            if merged {
                builder.covered()
                continue
            }
            let colSpan = max(tc.attr(Ns.a, "gridSpan").flatMap { UInt32($0) } ?? 1, 1)
            let rowSpan = max(tc.attr(Ns.a, "rowSpan").flatMap { UInt32($0) } ?? 1, 1)
            var cellBlocks: [Block] = []
            if let tx = tc.find(Ns.a, "txBody") {
                try parseTextBody(tx, ctx, nil, &cellBlocks)
            }
            try builder.place(Cell.spanning(cellBlocks, colSpan: colSpan, rowSpan: rowSpan))
        }
    }
    var table = builder.finish(.data)
    if table.grid.isEmpty {
        return
    }
    table.headerRows = resolveHeaderRows(table, declared: headerRows)
    blocks.append(.table(table))
}
