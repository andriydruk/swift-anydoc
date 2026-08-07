// Coverage for src/package/relationships.rs (the Rust file carries no unit
// tests; these pin the parsing and determinism contracts it documents).
import Testing
@testable import AnyDoc

@Suite struct RelationshipsTests {
    private static let rels = """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId2" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
        Target="word/other.xml"/>
            <Relationship Id="rId1" \
        Type="http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument" \
        Target="word/document.xml"/>
            <Relationship Id="rId3" Type="hyperlink" Target="https://example.com" \
        TargetMode="External"/>
            <Relationship Id="rId4" Target="no-type.xml"/>
        </Relationships>
        """

    private func makePackage() throws -> Package {
        try Package.open(makeZip([("_rels/.rels", Array(Self.rels.utf8))]))
    }

    @Test func readsTypedRelationships() throws {
        let rels = try readRels(makePackage(), "_rels/.rels")
        let r1 = try #require(rels.get("rId1"))
        // Strict relationship types normalize onto the Transitional family.
        #expect(r1.relType == RelType.officeDocument)
        #expect(r1.mode == .internalMode)
        #expect(rels.internalTarget("rId1") == "word/document.xml")
        let r3 = try #require(rels.get("rId3"))
        #expect(r3.mode == .external)
        #expect(rels.internalTarget("rId3") == nil)
        #expect(rels.get("rId4")?.relType == "")
    }

    @Test func firstOfTypePicksTheLowestId() throws {
        let rels = try readRels(makePackage(), "_rels/.rels")
        // Both rId1 and rId2 carry the type; the lowest id wins.
        #expect(rels.firstOfType(RelType.officeDocument)?.target == "word/document.xml")
    }

    @Test func absentPartYieldsEmptyRelationships() throws {
        let pkg = try Package.open(makeZip([("word/a.xml", Array("<x/>".utf8))]))
        let rels = try readRels(pkg, "word/_rels/a.xml.rels")
        #expect(rels.all.isEmpty)
        #expect(rels.firstOfType(RelType.officeDocument) == nil)
    }

    @Test func relTargetBytesResolvesAgainstTheBasePart() throws {
        let rels = """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                <Relationship Id="rId1" Type="image" Target="media/i.png"/>
                <Relationship Id="rId2" Type="hyperlink" Target="https://x" TargetMode="External"/>
            </Relationships>
            """
        let pkg = try Package.open(
            makeZip([
                ("word/_rels/document.xml.rels", Array(rels.utf8)),
                ("word/media/i.png", [1, 2, 3]),
            ]))
        let parsed = try readRels(pkg, "word/_rels/document.xml.rels")
        let target = try #require(
            try relTargetBytes(pkg, parsed, basePart: "word/document.xml", relId: "rId1"))
        #expect(target.path == "word/media/i.png")
        #expect(target.bytes == [1, 2, 3])
        // External targets and unknown ids degrade to nil.
        #expect(
            try relTargetBytes(pkg, parsed, basePart: "word/document.xml", relId: "rId2") == nil)
        #expect(
            try relTargetBytes(pkg, parsed, basePart: "word/document.xml", relId: "nope") == nil)
    }

    @Test func relsPartForConventionalNames() {
        #expect(relsPartFor("word/document.xml") == "word/_rels/document.xml.rels")
        #expect(relsPartFor("content.opf") == "_rels/content.opf.rels")
    }
}
