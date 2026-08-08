/// Hyperlinks and form fields, ported from pdf-inspector's
/// `extractor/links.rs`.
///
/// Neither lives in the content stream. A hyperlink is a `/Link` annotation:
/// a rectangle on the page plus an action holding the URI, with no connection
/// to the text underneath beyond sitting on top of it. A form field's value
/// lives in the AcroForm tree, off the trailer, and is never drawn at all
/// unless the producer also flattened it. Both are recovered by position and
/// then flow into the layout with everything else.

/// An annotation or field recovered from the page's dictionaries.
struct PdfAnnotationItem: Equatable {
    enum Kind: Equatable {
        /// A hyperlink, carrying its URI.
        case link(String)
        /// A form field's value, already rendered as `name: value`.
        case formField
    }
    var text: String
    var x: Float
    var y: Float
    var width: Float
    var height: Float
    var page: Int
    var kind: Kind
}

/// The `/Link` annotations on a page, as positioned items.
///
/// An annotation with no URI — an internal `/Dest` jump — is dropped, which
/// is what the reference does: resolving named destinations would need the
/// name tree, and it does not walk it.
func pdfPageLinks(
    _ document: inout PdfDocument, page: PdfDictionary, pageNumber: Int
) -> [PdfAnnotationItem] {
    guard let annotations = document.value(page, "Annots")?.asArray else { return [] }

    var links: [PdfAnnotationItem] = []
    for entry in annotations {
        guard let annotation = document.resolve(entry).asDictionary else { continue }
        // A missing /Subtype is *not* skipped: the reference only rejects a
        // subtype that is present and is not Link.
        if let subtype = document.value(annotation, "Subtype")?.asName,
            String(decoding: subtype, as: UTF8.self) != "Link"
        {
            continue
        }
        guard let uri = pdfLinkUri(&document, annotation) else { continue }
        guard let rectangle = document.value(annotation, "Rect")?.asArray, rectangle.count >= 4
        else { continue }

        // The rectangle is taken as given, so a reversed one yields negative
        // extents. The reference does not normalise here either.
        let numbers = rectangle.map { Float(document.resolve($0).asNumber ?? 0) }
        links.append(
            PdfAnnotationItem(
                text: uri,
                x: numbers[0], y: numbers[1],
                width: numbers[2] - numbers[0], height: numbers[3] - numbers[1],
                page: pageNumber, kind: .link(uri)))
    }
    return links
}

/// The URI an annotation's action points at.
func pdfLinkUri(_ document: inout PdfDocument, _ annotation: PdfDictionary) -> String? {
    guard let action = document.value(annotation, "A")?.asDictionary,
        let uri = document.value(action, "URI")?.asStringBytes
    else { return nil }
    // Lossy UTF-8, as the reference decodes it: a URI with invalid bytes
    // still yields a link rather than being dropped.
    return String(decoding: uri, as: UTF8.self)
}

/// A node deeper than this in the page tree is a malformed or hostile file,
/// not a document. The reference relies on lopdf's own page walk, which
/// keeps a visited set; this bound serves the same purpose.
private let pdfPageTreeMaxNodes = 10_000

/// The object ids of a document's pages, in tree order.
///
/// A form field names its page by reference, so turning that into the page
/// *number* the reference reports needs the tree walked once.
func pdfPageObjectIds(_ document: inout PdfDocument) -> [PdfObjectId] {
    guard let catalog = document.catalog,
        let rootReference = catalog["Pages"]?.asReference
    else { return [] }

    var pages: [PdfObjectId] = []
    var queue: [PdfObjectId] = [rootReference]
    var seen: Set<PdfObjectId> = []
    var visited = 0
    while !queue.isEmpty, visited < pdfPageTreeMaxNodes {
        let id = queue.removeFirst()
        visited += 1
        // A /Kids cycle would otherwise spin until the node bound.
        guard seen.insert(id).inserted, let node = document.object(id).asDictionary else {
            continue
        }
        if node["Type"]?.asName == Array("Page".utf8) {
            pages.append(id)
            continue
        }
        guard let kids = document.value(node, "Kids")?.asArray else { continue }
        queue.insert(contentsOf: kids.compactMap(\.asReference), at: 0)
    }
    return pages
}

/// Each page's number, keyed by object id, for resolving a field's `/P`.
func pdfPageNumbers(_ document: inout PdfDocument) -> [PdfObjectId: Int] {
    var numbers: [PdfObjectId: Int] = [:]
    for (index, id) in pdfPageObjectIds(&document).enumerated() { numbers[id] = index + 1 }
    return numbers
}

/// How deep the field tree may be walked before it is treated as a cycle.
///
/// The reference recurses without a bound because a malformed tree only costs
/// it a stack overflow it can catch; this port has no such backstop, so the
/// depth is capped. A tree deeper than this is not a real form.
private let pdfFormFieldMaxDepth = 32

/// The filled-in values of a document's AcroForm fields, positioned at each
/// field's rectangle so they lay out with the page's text.
func pdfFormFields(
    _ document: inout PdfDocument, pageNumbers: [PdfObjectId: Int]
) -> [PdfAnnotationItem] {
    guard let root = document.value(document.trailer, "Root")?.asDictionary,
        let acroForm = document.value(root, "AcroForm")?.asDictionary,
        let fields = document.value(acroForm, "Fields")?.asArray
    else { return [] }

    var items: [PdfAnnotationItem] = []
    var visited: Set<PdfObjectId> = []
    for field in fields {
        guard let id = field.asReference else { continue }
        pdfWalkFormFields(
            &document, id, inheritedType: nil, parentName: "", pageNumbers: pageNumbers,
            depth: 0, visited: &visited, into: &items)
    }
    return items
}

/// Walk one branch of the field tree, emitting its leaves.
private func pdfWalkFormFields(
    _ document: inout PdfDocument,
    _ id: PdfObjectId,
    inheritedType: String?,
    parentName: String,
    pageNumbers: [PdfObjectId: Int],
    depth: Int,
    visited: inout Set<PdfObjectId>,
    into items: inout [PdfAnnotationItem]
) {
    guard depth < pdfFormFieldMaxDepth, visited.insert(id).inserted else { return }
    guard let field = document.object(id).asDictionary else { return }

    // Field names are qualified by their ancestors, so a leaf reads
    // `address.city` rather than just `city`.
    let localName = document.value(field, "T")?.asStringBytes
        .map { String(decoding: $0, as: UTF8.self) }
    let name: String
    switch (parentName.isEmpty, localName ?? "") {
    case (true, let local): name = local
    case (false, ""): name = parentName
    case (false, let local): name = parentName + "." + local
    }

    // The type may be declared on an ancestor rather than the leaf.
    let type =
        document.value(field, "FT")?.asName.map { String(decoding: $0, as: UTF8.self) }
        ?? inheritedType

    // A node with children is a group, never a value.
    if let kids = document.value(field, "Kids")?.asArray {
        for kid in kids {
            guard let kidId = kid.asReference else { continue }
            pdfWalkFormFields(
                &document, kidId, inheritedType: type, parentName: name,
                pageNumbers: pageNumbers, depth: depth + 1, visited: &visited, into: &items)
        }
        return
    }

    guard let type, type != "Sig" else { return }
    guard let value = document.value(field, "V") else { return }

    let rendered: String
    switch type {
    case "Tx", "Ch":
        if let string = value.asStringBytes {
            let text = String(decoding: string, as: UTF8.self)
            if text.isEmpty { return }
            rendered = text
        } else if let array = value.asArray {
            let parts = array.compactMap {
                $0.asStringBytes.map { String(decoding: $0, as: UTF8.self) }
            }
            if parts.isEmpty { return }
            rendered = parts.joined(separator: ", ")
        } else {
            return
        }
    case "Btn":
        // A checkbox's value is a name; `Off` means unchecked, and the two
        // conventional on-states are both reported as `Yes`.
        guard let name = value.asName.map({ String(decoding: $0, as: UTF8.self) }),
            name != "Off"
        else { return }
        rendered = (name == "Yes" || name == "1") ? "Yes" : name
    default:
        return
    }

    var x: Float = 0
    var y: Float = 0
    var width: Float = 0
    var height: Float = 0
    if let rectangle = document.value(field, "Rect")?.asArray, rectangle.count >= 4 {
        let numbers = rectangle.map { Float(document.resolve($0).asNumber ?? 0) }
        // Unlike a link's rectangle, a field's is normalised — the reference
        // takes the lower Y and the absolute extents here.
        x = numbers[0]
        y = min(numbers[1], numbers[3])
        width = abs(numbers[2] - numbers[0])
        height = abs(numbers[3] - numbers[1])
    }

    // A field with no /P is assumed to be on the first page.
    let page = document.value(field, "P")?.asReference.flatMap { pageNumbers[$0] } ?? 1

    items.append(
        PdfAnnotationItem(
            text: name.isEmpty ? rendered : "\(name): \(rendered)",
            x: x, y: y, width: width, height: height, page: page, kind: .formField))
}
