/// OpenDocument Text (.odt), Spreadsheet (.ods), and Presentation (.odp).

func parseOdf(_ bytes: [UInt8]) throws -> Document {
    let pkg = try Package.open(bytes)

    if try odfIsEncrypted(pkg) {
        throw ConvertError.encrypted
    }

    // styles.xml is optional; corrupt -> skipped (default styling).
    let stylesTree = try pkg.optionalXmlPart("styles.xml")

    let contentTree = try pkg.requiredXmlPart("content.xml")

    let styles = OdfStyles()
    if let tree = stylesTree {
        styles.collect(tree)
    }
    styles.collect(contentTree)

    guard
        let body = contentTree.find(Ns.office, "document-content")?.find(Ns.office, "body")
    else {
        throw ConvertError.malformedPart("content.xml", "no office:body")
    }

    let assets = MutBox(AssetSink())
    let ctx = OdfCtx(styles: styles, pkg: pkg, assets: assets)

    let blocks: [Block]
    if let text = body.find(Ns.office, "text") {
        blocks = try parseContainer(text, ctx)
    } else if let sheet = body.find(Ns.office, "spreadsheet") {
        blocks = try parseSpreadsheet(sheet, ctx)
    } else if let pres = body.find(Ns.office, "presentation") {
        blocks = try parsePresentation(pres, ctx)
    } else {
        throw ConvertError.malformedPart(
            "content.xml",
            "no recognized office body (text, spreadsheet, or presentation)")
    }

    return Document(blocks: blocks, notes: ctx.notes, assets: assets.value.assets)
}

/// Encrypted ODF packages carry `manifest:encryption-data` elements on file
/// entries. The manifest is parsed properly - substring matching would
/// classify a document as encrypted over a mere comment. An absent or
/// unreadable manifest proves nothing (content parsing decides), but fatal
/// resource-limit errors propagate.
private func odfIsEncrypted(_ pkg: Package) throws -> Bool {
    guard let tree = try pkg.optionalXmlPart("META-INF/manifest.xml") else {
        return false
    }
    return tree.firstDescendant(Ns.manifest, "encryption-data") != nil
}

private func parsePresentation(_ pres: XmlElement, _ ctx: OdfCtx) throws -> [Block] {
    var blocks: [Block] = []
    for page in pres.findAll(Ns.draw, "page") {
        var title: [Block] = []
        var body: [Block] = []
        var notes: [Block] = []
        try walkShapes(page, ctx, &title, &body, &notes)
        blocks.append(contentsOf: title)
        blocks.append(contentsOf: body)
        // Speaker notes are included (fixed policy), set off as a quote.
        if !notes.isEmpty {
            blocks.append(.blockQuote(notes))
        }
    }
    return blocks
}

/// Walk a page's shapes in document order, recursing into `draw:g` groups.
private func walkShapes(
    _ parent: XmlElement,
    _ ctx: OdfCtx,
    _ title: inout [Block],
    _ body: inout [Block],
    _ notes: inout [Block]
) throws {
    for child in parent.childElements {
        if child.named(Ns.presentation, "notes") {
            for frame in child.descendants(Ns.draw, "frame") {
                if let textBox = frame.find(Ns.draw, "text-box") {
                    notes.append(contentsOf: try parseContainer(textBox, ctx))
                }
            }
            continue
        }
        guard child.ns == Ns.draw else {
            continue
        }
        switch child.local {
        case "frame":
            let cls = child.attr(Ns.presentation, "class") ?? ""
            if cls == "page-number" || cls == "date-time" || cls == "footer" || cls == "header" {
                continue
            }
            var inner: [Block] = []
            for content in child.childElements {
                if content.named(Ns.draw, "text-box") {
                    inner.append(contentsOf: try parseContainer(content, ctx))
                } else if content.named(Ns.table, "table") {
                    inner.append(contentsOf: try parseTable(content, ctx))
                } else if content.named(Ns.draw, "image") {
                    var out: [Inline] = []
                    var boxes: [Block] = []
                    try walkFrame(child, ctx, &out, &boxes)
                    if !inlinesAreEmpty(out) {
                        inner.append(.paragraph(out))
                    }
                    inner.append(contentsOf: boxes)
                    break
                }
            }
            if cls == "title" {
                pushTitleHeading(inner, &title)
            } else {
                body.append(contentsOf: inner)
            }
        case "g":
            try walkShapes(child, ctx, &title, &body, &notes)
        case "custom-shape", "rect", "ellipse", "polygon", "path", "line", "connector",
            "caption":
            for content in child.childElements {
                if content.named(Ns.text, "p") || content.named(Ns.text, "list") {
                    body.append(contentsOf: try parseContainer(child, ctx))
                    break
                }
            }
        default:
            break
        }
    }
}

/// Collapse a title frame's paragraphs into one slide heading.
private func pushTitleHeading(_ inner: [Block], _ blocks: inout [Block]) {
    var inlines: [Inline] = []
    for block in inner {
        guard case .paragraph(let para) = block else { continue }
        if inlinesAreEmpty(para) {
            continue
        }
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
