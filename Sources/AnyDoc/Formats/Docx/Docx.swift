/// OOXML WordprocessingML (.docx / .docm).
///
/// Resolution pipeline: package parts -> style/numbering models ->
/// spec-order property resolution -> document model.

func parseDocx(_ bytes: [UInt8]) throws -> Document {
    let pkg: Package
    do {
        pkg = try Package.open(bytes)
    } catch let e as ConvertError {
        throw probeOle(bytes) ?? e
    }

    // OPC part discovery: the main part comes from the package-level
    // officeDocument relationship; its own parts (styles, numbering, notes)
    // from the main part's typed relationships. Conventional paths are the
    // fallback for packages with missing or unusable rels.
    let rootRels = try readRels(pkg, "_rels/.rels")
    var mainPart = "word/document.xml"
    if let rel = rootRels.firstOfType(RelType.officeDocument),
        let target = try? resolvePackageReference(basePart: "", reference: rel.target)
    {
        mainPart = target.path
    }
    let docRels = try readRels(pkg, relsPartFor(mainPart))

    let stylesPart = typedPartPath(docRels, mainPart, RelType.styles, "styles.xml")
    let stylesTree = try pkg.optionalXmlPart(stylesPart)
    let styles = DocxStyles.parseOpt(stylesTree?.find(Ns.w, "styles"))

    let numberingPart = typedPartPath(docRels, mainPart, RelType.numbering, "numbering.xml")
    let numberingTree = try pkg.optionalXmlPart(numberingPart)
    let numbering: DocxNumbering
    if let root = numberingTree?.find(Ns.w, "numbering") {
        numbering = try parseNumbering(root, styleNumId: { styles.directNumId($0) })
    } else {
        numbering = DocxNumbering()
    }

    let docTree = try pkg.requiredXmlPart(mainPart)
    guard let body = docTree.find(Ns.w, "document")?.find(Ns.w, "body") else {
        throw ConvertError.malformedPart(mainPart, "no document body")
    }

    let counters = MutBox(DocxCounters())
    let assets = MutBox(AssetSink())

    let footnotesPart = typedPartPath(docRels, mainPart, RelType.footnotes, "footnotes.xml")
    let endnotesPart = typedPartPath(docRels, mainPart, RelType.endnotes, "endnotes.xml")

    let ctx = DocxCtx(
        pkg: pkg,
        rels: docRels,
        basePart: mainPart,
        styles: styles,
        numbering: numbering,
        counters: counters,
        assets: assets)
    let blocks = try parseBlocks(body, ctx)

    var notes: [Note] = []
    let noteSpecs: [(part: String, root: String, elem: String, prefix: String, kind: NoteKind)] = [
        (footnotesPart, "footnotes", "footnote", "fn", .footnote),
        (endnotesPart, "endnotes", "endnote", "en", .endnote),
    ]
    for spec in noteSpecs {
        guard let tree = try pkg.optionalXmlPart(spec.part) else {
            continue
        }
        guard let root = tree.find(Ns.w, spec.root) else {
            continue
        }
        let noteRels = try readRels(pkg, relsPartFor(spec.part))
        let noteCtx = ctx.forPart(noteRels, spec.part)
        for note in root.findAll(Ns.w, spec.elem) {
            switch note.attr(Ns.w, "type") {
            case "separator", "continuationSeparator", "continuationNotice":
                continue
            default:
                break
            }
            guard let id = note.attr(Ns.w, "id") else { continue }
            notes.append(
                Note(
                    id: "\(spec.prefix)\(id)",
                    kind: spec.kind,
                    blocks: try parseBlocks(note, noteCtx)))
        }
    }

    return Document(blocks: blocks, notes: notes, assets: assets.value.assets)
}

/// Path of a typed related part, resolved against the main part; falls back
/// to the conventional sibling name when the relationship is absent.
private func typedPartPath(
    _ rels: Relationships, _ base: String, _ relType: String, _ fallback: String
) -> String {
    let reference = rels.firstOfType(relType)?.target ?? fallback
    do {
        return try resolvePackageReference(basePart: base, reference: reference).path
    } catch let e as ConvertError {
        Log.warn(
            "skipping unresolvable related-part target \(rustDebugQuoted(reference)): \(e.message)")
        return (try? resolvePackageReference(basePart: base, reference: fallback).path) ?? fallback
    } catch {
        return (try? resolvePackageReference(basePart: base, reference: fallback).path) ?? fallback
    }
}
