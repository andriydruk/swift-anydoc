import Testing

@testable import AnyDoc

/// The structure tree flattened to a role per marked-content id.
@Suite struct PdfStructRoleMapTests {
    private func element(
        _ role: PdfStructRole, mcids: [(Int, PdfObjectId?)] = [],
        children: [PdfStructElement] = []
    ) -> PdfStructElement {
        PdfStructElement(
            role: role,
            contentRefs: mcids.map { PdfMarkedContentRef(mcid: $0.0, pageID: $0.1) },
            children: children)
    }

    private let pageOne = PdfObjectId(number: 3, generation: 0)
    private let pageTwo = PdfObjectId(number: 9, generation: 0)

    @Test func rolesAreKeyedByPageAndMarkedContentId() {
        let map = pdfStructRoleMap(
            [element(.h1, mcids: [(0, pageOne)]), element(.listItem, mcids: [(1, pageOne)])],
            pageNumbers: [pageOne: 1])
        #expect(map[1]?[0] == .h1)
        #expect(map[1]?[1] == .listItem)
    }

    @Test func nestedElementsAreWalked() {
        // A heading inside a section inside the root still reaches the map.
        let tree = [element(.sect, children: [element(.h2, mcids: [(4, pageOne)])])]
        #expect(pdfStructRoleMap(tree, pageNumbers: [pageOne: 1])[1]?[4] == .h2)
    }

    @Test func aReferenceWithNoPageIsDropped() {
        // An element that named no page cannot be placed against any item.
        let map = pdfStructRoleMap([element(.h1, mcids: [(0, nil)])], pageNumbers: [pageOne: 1])
        #expect(map.isEmpty)
    }

    @Test func aPageOutsideTheDocumentIsDropped() {
        // Rather than guessed at: a stale reference names an object that is
        // no longer a page.
        let map = pdfStructRoleMap([element(.h1, mcids: [(0, pageTwo)])], pageNumbers: [pageOne: 1])
        #expect(map.isEmpty)
    }

    @Test func idsAreCountedAcrossTheWholeTree() {
        // The count is what decides whether a partially tagged document is
        // worth trusting.
        let tree = [
            element(.sect, mcids: [(0, pageOne)], children: [element(.p, mcids: [(1, pageOne), (2, pageOne)])])
        ]
        #expect(pdfStructMcidCount(tree) == 3)
    }
}
