import Testing

@testable import AnyDoc

/// Structure-tree parsing, pinned without the oracle.
@Suite struct PdfStructTreeParserTests {
    // MARK: role mapping

    @Test func aRoleMapRedirectsACustomTag() {
        #expect(pdfStructRole(named: "MyHead", roleMap: ["MyHead": "H1"]) == .h1)
    }

    @Test func aRoleMapChainIsFollowed() {
        #expect(pdfStructRole(named: "A", roleMap: ["A": "B", "B": "H2"]) == .h2)
    }

    @Test func aRoleMapCycleStopsAtTheHopLimit() {
        // Eight hops, then whatever the name resolves to on its own.
        #expect(pdfStructRole(named: "A", roleMap: ["A": "B", "B": "A"]) == .other("A"))
    }

    @Test func aStandardNameIsNeverRemapped() {
        // The chain is only followed when the name is *not* already standard,
        // so a document cannot redefine `H1`.
        #expect(pdfStructRole(named: "H1", roleMap: ["H1": "P"]) == .h1)
    }

    @Test func anUnmappedCustomTagFallsThrough() {
        #expect(pdfStructRole(named: "Whatever", roleMap: [:]) == .other("Whatever"))
    }

    // MARK: dictionary helpers

    @Test func typeNamesAreCompared() {
        var dictionary = PdfDictionary()
        dictionary["Type"] = .name(Array("MCR".utf8))
        #expect(pdfIsTypeNamed(dictionary, "MCR"))
        #expect(!pdfIsTypeNamed(dictionary, "OBJR"))
        #expect(!pdfIsTypeNamed(PdfDictionary(), "MCR"))
    }

    @Test func aPageEntryMustStayAReference() {
        // Resolving `/Pg` to the page dictionary would lose the identity the
        // tables key on, so only a reference counts.
        var dictionary = PdfDictionary()
        var document = tagged("<< /Type /StructTreeRoot >>")!
        dictionary["Pg"] = .reference(PdfObjectId(number: 3, generation: 0))
        #expect(pdfPageReference(&document, dictionary)?.number == 3)
        dictionary["Pg"] = .dictionary(PdfDictionary())
        #expect(pdfPageReference(&document, dictionary) == nil)
        #expect(pdfPageReference(&document, PdfDictionary()) == nil)
    }

    @Test func textStringsAreDecodedAsPdfText() {
        var dictionary = PdfDictionary()
        dictionary["Alt"] = .string(Array("a seal".utf8), .literal)
        #expect(pdfStructTextString(dictionary, "Alt") == "a seal")
        // A UTF-16BE string with its byte-order mark.
        dictionary["Alt"] = .string([0xFE, 0xFF, 0x00, 0x41], .literal)
        #expect(pdfStructTextString(dictionary, "Alt") == "A")
        // Anything that is not a string yields nothing.
        dictionary["Alt"] = .name(Array("A".utf8))
        #expect(pdfStructTextString(dictionary, "Alt") == nil)
    }

    // MARK: parsing whole documents

    /// A minimal tagged document whose structure root is object 5.
    private func tagged(_ root: String, _ extra: [String] = []) -> PdfDocument? {
        let content = "BT /F1 12 Tf 100 700 Td (hi) Tj ET"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 5 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            root,
        ]
        objects.append(contentsOf: extra)

        var bytes = Array("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes += Array("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8)
        }
        let xref = bytes.count
        bytes += Array("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
        for offset in offsets {
            bytes += Array(String(format: "%010d 00000 n \n", offset).utf8)
        }
        bytes += Array(
            "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
                .utf8)
        return try? PdfDocument(bytes: bytes)
    }

    @Test func anUntaggedDocumentHasNoTree() {
        var document = tagged("<< /Type /StructTreeRoot >>")!
        #expect(pdfParseStructTree(&document) == nil)
    }

    @Test func anEmptyTreeIsReportedAsAbsent() {
        // A root with nothing under it tells a caller no more than none.
        var document = tagged("<< /Type /StructTreeRoot /K [] >>")!
        #expect(pdfParseStructTree(&document) == nil)
    }

    @Test func anIntegerKeyIsContentOfItsOwnElement() {
        var document = tagged(
            "<< /Type /StructTreeRoot /K 6 0 R >>",
            ["<< /Type /StructElem /S /P /Pg 3 0 R /K [0 1 2] >>"])!
        let tree = pdfParseStructTree(&document)!
        #expect(tree.count == 1)
        #expect(tree[0].contentRefs.map(\.mcid) == [0, 1, 2])
        #expect(tree[0].children.isEmpty)
    }

    @Test func aPageIsInheritedByDescendants() {
        var document = tagged(
            "<< /Type /StructTreeRoot /K 6 0 R >>",
            [
                "<< /Type /StructElem /S /Sect /Pg 3 0 R /K [7 0 R] >>",
                "<< /Type /StructElem /S /P /K 5 >>",
            ])!
        let tree = pdfParseStructTree(&document)!
        #expect(tree[0].children[0].contentRefs[0].pageID?.number == 3)
    }

    @Test func aBareIntegerBecomesASyntheticSpan() {
        // The reference wraps it rather than attaching it to the parent, so
        // the tree gains a node the document never declared.
        var document = tagged("<< /Type /StructTreeRoot /Pg 3 0 R /K [0 1] >>")!
        let tree = pdfParseStructTree(&document)!
        #expect(tree.count == 2)
        #expect(tree.allSatisfy { $0.role == .span })
    }

    @Test func objectReferencesCarryNoContent() {
        var document = tagged(
            "<< /Type /StructTreeRoot /K 6 0 R >>",
            [
                "<< /Type /StructElem /S /P /Pg 3 0 R "
                    + "/K [<< /Type /OBJR /Obj 3 0 R >> 7] >>"
            ])!
        let tree = pdfParseStructTree(&document)!
        #expect(tree[0].contentRefs.map(\.mcid) == [7])
    }

    @Test func anElementWithoutATypeIsDropped() {
        var document = tagged(
            "<< /Type /StructTreeRoot /K [6 0 R 7 0 R] >>",
            [
                "<< /Type /StructElem /Pg 3 0 R /K 0 >>",
                "<< /Type /StructElem /S /P /Pg 3 0 R /K 1 >>",
            ])!
        let tree = pdfParseStructTree(&document)!
        #expect(tree.count == 1)
        #expect(tree[0].role == .p)
    }

    @Test func attributesAreCarried() {
        var document = tagged(
            "<< /Type /StructTreeRoot /K 6 0 R >>",
            [
                "<< /Type /StructElem /S /Figure /Pg 3 0 R /Alt (a seal) "
                    + "/ActualText (fi) /Lang (en-US) /K 0 >>"
            ])!
        let tree = pdfParseStructTree(&document)!
        #expect(tree[0].altText == "a seal")
        #expect(tree[0].actualText == "fi")
        #expect(tree[0].language == "en-US")
    }

    @Test func aSelfReferentialElementStopsAtTheDepthLimit() {
        // Sixty-four levels, then the recursion refuses to go further.
        var document = tagged(
            "<< /Type /StructTreeRoot /K 6 0 R >>",
            ["<< /Type /StructElem /S /Div /Pg 3 0 R /K [6 0 R] >>"])!
        let tree = pdfParseStructTree(&document)!
        #expect(pdfFlattenStructElements(tree).count == 64)
    }

    @Test func aTaggedTableParsesIntoRowsAndCells() {
        var document = tagged(
            "<< /Type /StructTreeRoot /K 6 0 R >>",
            [
                "<< /Type /StructElem /S /Table /Pg 3 0 R /K [7 0 R 8 0 R] >>",
                "<< /Type /StructElem /S /TR /K [9 0 R 10 0 R] >>",
                "<< /Type /StructElem /S /TR /K [11 0 R 12 0 R] >>",
                "<< /Type /StructElem /S /TH /K 0 >>",
                "<< /Type /StructElem /S /TH /K 1 >>",
                "<< /Type /StructElem /S /TD /K 2 >>",
                "<< /Type /StructElem /S /TD /K 3 >>",
            ])!
        let tree = pdfParseStructTree(&document)!
        let pages = [PdfObjectId(number: 3, generation: 0): UInt32(1)]
        let tables = pdfCollectStructTables(tree, pageNumbers: pages)
        #expect(tables.count == 1)
        #expect(tables[0].rows.count == 2)
        #expect(tables[0].rows[0].cells.allSatisfy { $0.isHeader })
    }
}
