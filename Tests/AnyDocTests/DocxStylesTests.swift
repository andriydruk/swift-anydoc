// Ported from src/formats/docx/styles.rs tests.
import Testing
@testable import AnyDoc

@Suite struct DocxStylesTests {
    // parseXml returns a synthetic root wrapping the document element.
    private func parse(_ doc: String) throws -> XmlElement {
        try parseXml(Array(doc.utf8))
    }

    @Test func onOffCoversTheFullValueSpace() throws {
        let cases: [(String, Bool?)] = [
            (#"<w:b/>"#, true),
            (#"<w:b w:val="1"/>"#, true),
            (#"<w:b w:val="true"/>"#, true),
            (#"<w:b w:val="on"/>"#, true),
            (#"<w:b w:val="0"/>"#, false),
            (#"<w:b w:val="false"/>"#, false),
            (#"<w:b w:val="off"/>"#, false),
            ("", nil),
        ]
        for (xml, expect) in cases {
            let root = try parse(
                #"<w:rPr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\#(xml)</w:rPr>"#
            )
            let rpr = try #require(root.find(Ns.w, "rPr"))
            #expect(onOff(rpr, "b") == expect, "for \(xml)")
        }
    }

    @Test func togglesFlipTheBaseAndDoubleFlipsCancel() {
        let base = Style(bold: true)
        let flip = Toggles(bold: true)
        #expect(!flip.applyOver(base).bold)
        #expect(flip.xor(flip).applyOver(base).bold)
    }

    @Test func styleFalseContributesNothingToParity() throws {
        let stylesXml = #"""
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                <w:style w:type="character" w:styleId="NotBold"><w:rPr><w:b w:val="0"/></w:rPr></w:style>
                <w:style w:type="character" w:styleId="Flip"><w:basedOn w:val="NotBold"/><w:rPr><w:b/></w:rPr></w:style>
            </w:styles>
            """#
        let root = try parse(stylesXml)
        let styles = DocxStyles.parse(try #require(root.find(Ns.w, "styles")))
        #expect(try styles.runToggles("NotBold") == Toggles())
        #expect(try styles.runToggles("Flip").bold)
    }
}
