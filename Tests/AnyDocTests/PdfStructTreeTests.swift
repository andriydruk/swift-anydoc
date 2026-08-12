import Testing

@testable import AnyDoc

/// Structure-tree walks, pinned without the oracle.
@Suite struct PdfStructTreeTests {
    private func element(
        _ role: PdfStructRole, mcids: [(Int, UInt32)] = [], _ children: [PdfStructElement] = []
    ) -> PdfStructElement {
        PdfStructElement(
            role: role,
            contentRefs: mcids.map {
                PdfMarkedContentRef(mcid: $0.0, pageID: PdfObjectId(number: $0.1, generation: 0))
            },
            children: children)
    }

    private let pages: [PdfObjectId: UInt32] = [
        PdfObjectId(number: 1, generation: 0): 1,
        PdfObjectId(number: 2, generation: 0): 2,
    ]

    private func row(_ cells: [PdfStructElement]) -> PdfStructElement {
        element(.tableRow, mcids: [], cells)
    }

    // MARK: roles

    @Test func standardNamesMapToRolesAndTheRestFallThrough() {
        #expect(PdfStructRole.fromName("H1") == .h1)
        #expect(PdfStructRole.fromName("TOCI") == .tocItem)
        #expect(PdfStructRole.fromName("LBody") == .listBody)
        #expect(PdfStructRole.fromName("Weird") == .other("Weird"))
    }

    @Test func figureIsNotANonHeadingRole() {
        // Cover pages tag the document title inside a Figure, next to a seal
        // or logo, and that title is a real heading.
        #expect(!PdfStructRole.figure.isNonHeadingContent)
        // A formula or form field never is one, though.
        #expect(PdfStructRole.formula.isNonHeadingContent)
        #expect(PdfStructRole.form.isNonHeadingContent)
        // Nor is a table cell, so a short `TH` is not promoted.
        #expect(PdfStructRole.tableHeaderCell.isNonHeadingContent)
        // Headings and generic containers stay eligible.
        for role in [PdfStructRole.h, .h1, .p, .div, .sect, .span] {
            #expect(!role.isNonHeadingContent)
        }
    }

    // MARK: tables

    @Test func aTwoRowTableIsCollected() {
        let tree = [
            element(
                .table, mcids: [],
                [
                    row([element(.tableHeaderCell, mcids: [(1, 1)])]),
                    row([element(.tableDataCell, mcids: [(2, 1)])]),
                ])
        ]
        let tables = pdfCollectStructTables(tree, pageNumbers: pages)
        #expect(tables.count == 1)
        #expect(tables[0].rows.count == 2)
        #expect(tables[0].rows[0].cells[0].isHeader)
        #expect(!tables[0].rows[1].cells[0].isHeader)
    }

    @Test func oneRowIsNotATable() {
        let tree = [element(.table, mcids: [], [row([element(.tableDataCell)])])]
        #expect(pdfCollectStructTables(tree, pageNumbers: pages).isEmpty)
    }

    @Test func twoRowsWithNoCellsAreNotATable() {
        let tree = [element(.table, mcids: [], [row([]), row([])])]
        #expect(pdfCollectStructTables(tree, pageNumbers: pages).isEmpty)
    }

    @Test func groupingElementsAreDescendedThrough() {
        // THead/TBody/TFoot hold no rows of their own but are where real
        // documents put them.
        let tree = [
            element(
                .table, mcids: [],
                [
                    element(.tableHead, mcids: [], [row([element(.tableHeaderCell)])]),
                    element(.tableBody, mcids: [], [row([element(.tableDataCell)])]),
                    element(.tableFoot, mcids: [], [row([element(.tableDataCell)])]),
                ])
        ]
        #expect(pdfCollectStructTables(tree, pageNumbers: pages).first?.rows.count == 3)
    }

    @Test func aNestedTableIsNotCollectedSeparately() {
        // The outer table owns the descent, so the inner one's rows are not
        // reported as a second table.
        let inner = element(
            .table, mcids: [],
            [row([element(.tableDataCell)]), row([element(.tableDataCell)])])
        let tree = [
            element(
                .table, mcids: [],
                [
                    row([element(.tableDataCell, mcids: [], [inner])]),
                    row([element(.tableDataCell)]),
                ])
        ]
        #expect(pdfCollectStructTables(tree, pageNumbers: pages).count == 1)
    }

    @Test func aTableBuriedUnderContainersIsStillFound() {
        let table = element(
            .table, mcids: [],
            [row([element(.tableDataCell)]), row([element(.tableDataCell)])])
        let tree = [element(.document, mcids: [], [element(.sect, mcids: [], [table])])]
        #expect(pdfCollectStructTables(tree, pageNumbers: pages).count == 1)
    }

    @Test func nonCellChildrenOfARowAreIgnored() {
        let tree = [
            element(
                .table, mcids: [],
                [
                    row([element(.span, mcids: [(1, 1)]), element(.tableDataCell)]),
                    row([element(.tableDataCell)]),
                ])
        ]
        #expect(pdfCollectStructTables(tree, pageNumbers: pages).first?.rows[0].cells.count == 1)
    }

    // MARK: marked content

    @Test func mcidsAreGatheredFromTheWholeSubtree() {
        let cell = element(
            .tableDataCell, mcids: [(1, 1)],
            [element(.span, mcids: [(2, 1)], [element(.span, mcids: [(3, 2)])])])
        let collected = pdfCollectStructMcids(cell, pageNumbers: pages)
        #expect(collected.map(\.mcid) == [1, 2, 3])
        #expect(collected.map(\.page) == [1, 1, 2])
    }

    @Test func aReferenceWithNoResolvablePageIsDropped() {
        // The id alone is meaningless without knowing which stream indexes it.
        var cell = element(.tableDataCell, mcids: [(1, 1)])
        cell.contentRefs.append(PdfMarkedContentRef(mcid: 2, pageID: nil))
        cell.contentRefs.append(
            PdfMarkedContentRef(mcid: 3, pageID: PdfObjectId(number: 99, generation: 0)))
        #expect(pdfCollectStructMcids(cell, pageNumbers: pages).map(\.mcid) == [1])
    }

    // MARK: flattening

    @Test func flatteningIsDocumentOrderWithDepth() {
        var figure = element(.figure)
        figure.altText = "a seal"
        let tree = [
            element(
                .document, mcids: [],
                [element(.sect, mcids: [], [element(.h1), element(.p)]), figure])
        ]
        let flat = pdfFlattenStructElements(tree)
        #expect(flat.map(\.depth) == [0, 1, 2, 2, 1])
        #expect(flat.map(\.role) == [.document, .sect, .h1, .p, .figure])
        // The child count survives, which the flat view would otherwise lose.
        #expect(flat[0].childCount == 2)
        #expect(flat[2].childCount == 0)
        #expect(flat.last?.altText == "a seal")
    }

    @Test func anEmptyTreeFlattensToNothing() {
        #expect(pdfFlattenStructElements([]).isEmpty)
    }
}
