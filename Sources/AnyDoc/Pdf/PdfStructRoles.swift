/// The structure tree flattened to a role per marked-content id, ported from
/// `mcid_to_roles` and `collect_mcid_roles` in `structure_tree.rs`.
///
/// A tagged PDF says what its content *means* — this is a heading, that is a
/// table cell — and the writer prefers those declarations to any geometric
/// guess. The link between the two is the marked-content id: the structure
/// element names an id and a page, and the content stream's `BDC` stamps the
/// same id onto the runs it wraps.
///
/// This is the last piece of the tagged path. The tree walker, the role
/// vocabulary, the extractor's `BDC`/`EMC` tracking and every consumer were
/// ported in earlier waves; nothing joined them.

/// Every tagged marked-content id, by page and then by id.
///
/// - Parameter pageNumbers: object id to page number, which is what turns
///   the tree's page *references* into the page numbers items carry.
func pdfStructRoleMap(
    _ elements: [PdfStructElement], pageNumbers: [PdfObjectId: Int]
) -> PdfStructRoleMap {
    var map: PdfStructRoleMap = [:]
    func walk(_ elements: [PdfStructElement]) {
        for element in elements {
            for reference in element.contentRefs {
                // An element that named no page cannot be placed, and one
                // naming a page outside the document is dropped rather than
                // guessed at.
                guard let pageID = reference.pageID, let page = pageNumbers[pageID] else {
                    continue
                }
                // A later element claiming the same id wins, which is the
                // insertion order of the reference's own walk.
                map[page, default: [:]][reference.mcid] = element.role
            }
            walk(element.children)
        }
    }
    walk(elements)
    return map
}

/// How many marked-content references a tree holds.
///
/// The reference uses this to judge whether a tree is worth trusting: a
/// document that tags a handful of its runs is partially tagged, and its
/// declarations cover too little to rely on.
func pdfStructMcidCount(_ elements: [PdfStructElement]) -> Int {
    elements.reduce(0) { $0 + $1.contentRefs.count + pdfStructMcidCount($1.children) }
}
