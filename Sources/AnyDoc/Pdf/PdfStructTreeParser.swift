/// Reading the structure tree out of a document, ported from `StructTree`,
/// `parse_role_map`, `parse_kids`, `parse_kid` and `parse_struct_element_dict`
/// in pdf-inspector's `structure_tree.rs`.
///
/// Wave 48 ported the tree's shape and the operations over it; this is what
/// builds one from a PDF. With it the struct-tree table path runs end to end:
/// document → tree → tables.
///
/// The `/K` entry is the awkward part. It may be a single integer, a
/// dictionary, a stream or an array of any mixture of those, and an integer
/// means "marked content belonging to *this* element" while a dictionary means
/// "a child element" — so the same key carries two different relationships.

/// Recursion limit, against a malformed tree that points at itself.
private let pdfMaxStructDepth = 64

/// Parse the structure tree, or `nil` when the document is not tagged.
func pdfParseStructTree(_ document: inout PdfDocument) -> [PdfStructElement]? {
    guard let catalog = document.catalog,
        let rootObject = catalog["StructTreeRoot"],
        let root = pdfResolveDictionary(&document, rootObject)
    else { return nil }

    let roleMap = pdfParseRoleMap(&document, root)
    let children = pdfParseStructKids(
        &document, root, roleMap: roleMap, inheritedPage: nil, depth: 0)
    // An empty tree is reported as absent: a `/StructTreeRoot` with nothing
    // under it tells a caller no more than having none.
    return children.isEmpty ? nil : children
}

/// The `/RoleMap`: a document's custom tag names against standard ones.
func pdfParseRoleMap(
    _ document: inout PdfDocument, _ structRoot: PdfDictionary
) -> [String: String] {
    var map: [String: String] = [:]
    guard let raw = structRoot["RoleMap"],
        let dictionary = pdfResolveDictionary(&document, raw)
    else { return map }
    for (key, value) in dictionary.entries {
        if case .name(let name) = value {
            map[String(decoding: key, as: UTF8.self)] = String(decoding: name, as: UTF8.self)
        }
    }
    return map
}

/// A role name resolved through the role map.
///
/// The chain is followed until a standard type is reached, up to eight hops —
/// a document may map its own tag onto another of its own. The hop limit is
/// what stops a cycle spinning.
func pdfStructRole(named name: String, roleMap: [String: String]) -> PdfStructRole {
    var current = name
    for _ in 0..<8 {
        let role = PdfStructRole.fromName(current)
        if case .other = role {} else { return role }
        guard let mapped = roleMap[current] else { return role }
        current = mapped
    }
    return PdfStructRole.fromName(current)
}

/// Children of an element, from its `/K`.
func pdfParseStructKids(
    _ document: inout PdfDocument, _ dictionary: PdfDictionary, roleMap: [String: String],
    inheritedPage: PdfObjectId?, depth: Int
) -> [PdfStructElement] {
    if depth >= pdfMaxStructDepth { return [] }
    guard let kids = dictionary["K"] else { return [] }

    // `/Pg` here is inherited by everything below, so a child that omits it
    // still knows which page its content is on.
    let pageID = pdfPageReference(&document, dictionary) ?? inheritedPage

    var children: [PdfStructElement] = []
    if case .array(let entries) = kids {
        for entry in entries {
            let resolved = document.resolve(entry)
            pdfParseStructKid(
                &document, resolved, roleMap: roleMap, inheritedPage: pageID, depth: depth,
                into: &children)
        }
    } else {
        let resolved = document.resolve(kids)
        pdfParseStructKid(
            &document, resolved, roleMap: roleMap, inheritedPage: pageID, depth: depth,
            into: &children)
    }
    return children
}

/// One `/K` entry.
func pdfParseStructKid(
    _ document: inout PdfDocument, _ object: PdfObject, roleMap: [String: String],
    inheritedPage: PdfObjectId?, depth: Int, into out: inout [PdfStructElement]
) {
    switch object {
    case .integer(let mcid):
        // A bare id at this level is content of the *parent*, but the
        // reference wraps it in a synthetic `Span` rather than passing it
        // back up — so the tree gains a node the document never declared.
        out.append(
            PdfStructElement(
                role: .span,
                contentRefs: [PdfMarkedContentRef(mcid: Int(mcid), pageID: inheritedPage)]))
    case .dictionary(let dictionary):
        pdfParseStructElement(
            &document, dictionary, roleMap: roleMap, inheritedPage: inheritedPage,
            depth: depth, into: &out)
    case .stream(let stream):
        // Rare, but some producers wrap an element in a stream.
        pdfParseStructElement(
            &document, stream.dict, roleMap: roleMap, inheritedPage: inheritedPage,
            depth: depth, into: &out)
    default:
        break
    }
}

/// A dictionary that may be a structure element, a marked-content reference,
/// or an object reference.
func pdfParseStructElement(
    _ document: inout PdfDocument, _ dictionary: PdfDictionary, roleMap: [String: String],
    inheritedPage: PdfObjectId?, depth: Int, into out: inout [PdfStructElement]
) {
    if depth >= pdfMaxStructDepth { return }

    // `/Type /MCR` — a marked-content reference, which becomes another
    // synthetic `Span`.
    if pdfIsTypeNamed(dictionary, "MCR") {
        if let value = dictionary["MCID"], case .integer(let mcid) = value {
            let pageID = pdfPageReference(&document, dictionary) ?? inheritedPage
            out.append(
                PdfStructElement(
                    role: .span,
                    contentRefs: [PdfMarkedContentRef(mcid: Int(mcid), pageID: pageID)]))
        }
        return
    }
    // `/Type /OBJR` points at an annotation or form field rather than content.
    if pdfIsTypeNamed(dictionary, "OBJR") { return }

    // Without `/S` there is no role, and the element is dropped entirely.
    guard let typeObject = dictionary["S"] else { return }
    guard case .name(let nameBytes) = document.resolve(typeObject) else { return }
    let role = pdfStructRole(
        named: String(decoding: nameBytes, as: UTF8.self), roleMap: roleMap)
    let pageID = pdfPageReference(&document, dictionary) ?? inheritedPage

    var element = PdfStructElement(role: role)
    element.altText = pdfStructTextString(dictionary, "Alt")
    element.actualText = pdfStructTextString(dictionary, "ActualText")
    element.language = pdfStructTextString(dictionary, "Lang")

    if let kids = dictionary["K"] {
        switch document.resolve(kids) {
        case .integer(let mcid):
            element.contentRefs.append(
                PdfMarkedContentRef(mcid: Int(mcid), pageID: pageID))
        case .array(let entries):
            for entry in entries {
                switch document.resolve(entry) {
                case .integer(let mcid):
                    element.contentRefs.append(
                        PdfMarkedContentRef(mcid: Int(mcid), pageID: pageID))
                case .dictionary(let child):
                    if pdfIsTypeNamed(child, "MCR") {
                        if let value = child["MCID"], case .integer(let mcid) = value {
                            let page = pdfPageReference(&document, child) ?? pageID
                            element.contentRefs.append(
                                PdfMarkedContentRef(mcid: Int(mcid), pageID: page))
                        }
                    } else if pdfIsTypeNamed(child, "OBJR") {
                        // Nothing to take from an object reference.
                    } else {
                        pdfParseStructElement(
                            &document, child, roleMap: roleMap, inheritedPage: pageID,
                            depth: depth + 1, into: &element.children)
                    }
                case .stream(let stream):
                    pdfParseStructElement(
                        &document, stream.dict, roleMap: roleMap,
                        inheritedPage: pageID, depth: depth + 1, into: &element.children)
                default:
                    break
                }
            }
        case .dictionary(let child):
            if pdfIsTypeNamed(child, "MCR") {
                if let value = child["MCID"], case .integer(let mcid) = value {
                    let page = pdfPageReference(&document, child) ?? pageID
                    element.contentRefs.append(
                        PdfMarkedContentRef(mcid: Int(mcid), pageID: page))
                }
            } else {
                // Note the lone-dictionary case does *not* check for `OBJR`,
                // unlike the array case above — an object reference here is
                // parsed as an element and dropped for want of an `/S`.
                pdfParseStructElement(
                    &document, child, roleMap: roleMap, inheritedPage: pageID,
                    depth: depth + 1, into: &element.children)
            }
        default:
            break
        }
    }

    out.append(element)
}

/// A dictionary from an object that may be one directly or a reference to one.
func pdfResolveDictionary(
    _ document: inout PdfDocument, _ object: PdfObject
) -> PdfDictionary? {
    if case .dictionary(let dictionary) = object { return dictionary }
    if case .reference = object { return document.resolve(object).asDictionary }
    return nil
}

// MARK: - small helpers

/// Whether a dictionary's `/Type` is the given name.
func pdfIsTypeNamed(_ dictionary: PdfDictionary, _ expected: String) -> Bool {
    guard let value = dictionary["Type"], case .name(let name) = value else { return false }
    return name == Array(expected.utf8)
}

/// The `/Pg` page reference, which must stay a *reference* — resolving it to
/// the page dictionary would lose the identity the tables key on.
func pdfPageReference(
    _ document: inout PdfDocument, _ dictionary: PdfDictionary
) -> PdfObjectId? {
    guard let value = dictionary["Pg"] else { return nil }
    if case .reference(let id) = value { return id }
    if case .reference(let id) = document.resolve(value) { return id }
    return nil
}

/// A text string entry, decoded as PDF text.
func pdfStructTextString(_ dictionary: PdfDictionary, _ key: String) -> String? {
    guard let value = dictionary[key], case .string(let bytes, _) = value else { return nil }
    return pdfDecodeTextString(bytes)
}
