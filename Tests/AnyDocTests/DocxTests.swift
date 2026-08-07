// Ported from src/formats/docx/mod.rs tests.
import Testing
@testable import AnyDoc

@Suite struct DocxTests {
    private func docxParts(_ parts: [(String, String)]) -> [UInt8] {
        makeZip(parts.map { ($0.0, Array($0.1.utf8)) })
    }

    private func docx(_ document: String, _ rels: String) -> [UInt8] {
        docxParts([
            ("word/document.xml", document),
            ("word/_rels/document.xml.rels", rels),
        ])
    }

    private let w = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#

    private func findImage(_ blocks: [Block]) -> Inline? {
        for block in blocks {
            guard case .paragraph(let inlines) = block else { continue }
            if let image = inlines.first(where: { inline in
                if case .image = inline { return true }
                return false
            }) {
                return image
            }
        }
        return nil
    }

    @Test func linkedImageRelationshipBecomesAnExternalSource() throws {
        // M9: `r:link` with an external-mode relationship must carry the URL
        // instead of failing the internal-part loader.
        let document = #"""
            <w:document
            xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
            <w:body><w:p><w:r><w:drawing>
                <a:blip r:link="rId9"/>
            </w:drawing></w:r></w:p></w:body></w:document>
            """#
        let rels = #"""
            <Relationships
            xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId9"
                Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
                Target="https://e.com/pic.png" TargetMode="External"/>
            </Relationships>
            """#
        let doc = try parseDocx(docx(document, rels))
        let image = try #require(findImage(doc.blocks), "image inline")
        guard case .image(_, let source) = image else {
            Issue.record("expected image: \(image)")
            return
        }
        #expect(source == .external("https://e.com/pic.png"))
        #expect(doc.assets.isEmpty, "external images are not retained as assets")
    }

    private func numberingWithStart(_ start: String) -> String {
        """
        <w:numbering \(w)>
        <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0">
            <w:numFmt w:val="decimal"/><w:start w:val="\(start)"/>
        </w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        </w:numbering>
        """
    }

    private func numberedParagraphs() -> String {
        let para = #"""
            <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
            <w:r><w:t>item</w:t></w:r></w:p>
            """#
        return "<w:document \(w)><w:body>\(para)\(para)</w:body></w:document>"
    }

    @Test func hugeNumberingStartValuesCannotOverflow() throws {
        // H2: w:start is ST_DecimalNumber (xsd:int); out-of-range values are
        // clamped so document-order increments can never overflow.
        for start in ["18446744073709551615", "-5", "2147483647"] {
            let bytes = docxParts([
                ("word/document.xml", numberedParagraphs()),
                ("word/numbering.xml", numberingWithStart(start)),
            ])
            let doc = try parseDocx(bytes)
            #expect(!doc.blocks.isEmpty, "\(start)")
        }
    }

    @Test func partialNumPrInheritsPropertyByProperty() throws {
        // M1: a direct numPr carrying only ilvl merges with the style's
        // numId instead of suppressing numbering.
        let document = """
            <w:document \(w)><w:body>
            <w:p><w:pPr><w:pStyle w:val="Listy"/>
                <w:numPr><w:ilvl w:val="1"/></w:numPr></w:pPr>
                <w:r><w:t>second level</w:t></w:r></w:p>
            </w:body></w:document>
            """
        let styles = """
            <w:styles \(w)>
            <w:style w:type="paragraph" w:styleId="Listy">
                <w:pPr><w:numPr><w:numId w:val="1"/></w:numPr></w:pPr>
            </w:style></w:styles>
            """
        let numbering = """
            <w:numbering \(w)>
            <w:abstractNum w:abstractNumId="0">
                <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:start w:val="1"/></w:lvl>
                <w:lvl w:ilvl="1"><w:numFmt w:val="lowerLetter"/><w:start w:val="1"/></w:lvl>
            </w:abstractNum>
            <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
            </w:numbering>
            """
        let bytes = docxParts([
            ("word/document.xml", document),
            ("word/styles.xml", styles),
            ("word/numbering.xml", numbering),
        ])
        let doc = try parseDocx(bytes)
        guard case .list(let list)? = doc.blocks.first else {
            Issue.record("expected a list, got \(String(describing: doc.blocks.first))")
            return
        }
        #expect(list.marker == .lowerAlpha, "level 1 of the style's numbering")
    }

    @Test func unpreservedEdgeWhitespaceIsDiscarded() throws {
        // M3: w:t edge whitespace is significant only under
        // xml:space="preserve".
        let document = """
            <w:document \(w)><w:body><w:p>
            <w:r><w:t>lead</w:t></w:r>
            <w:r><w:t>   discarded   </w:t></w:r>
            <w:r><w:t xml:space="preserve"> kept </w:t></w:r>
            <w:r><w:t>tail</w:t></w:r>
            </w:p></w:body></w:document>
            """
        let doc = try parseDocx(docxParts([("word/document.xml", document)]))
        guard case .paragraph(let inlines)? = doc.blocks.first else {
            Issue.record("\(doc.blocks)")
            return
        }
        #expect(inlinesToPlainText(inlines) == "leaddiscarded kept tail")
    }

    @Test func unpreservedNoBreakSpaceIsKept() throws {
        // The xml:space contract governs XML whitespace; a no-break space is
        // character data, so it survives an unmarked edge.
        let nbsp = "\u{a0}"
        let document = """
            <w:document \(w)><w:body><w:p>
            <w:r><w:t>before\(nbsp)</w:t></w:r>
            <w:r><w:t>after</w:t></w:r>
            </w:p></w:body></w:document>
            """
        let doc = try parseDocx(docxParts([("word/document.xml", document)]))
        guard case .paragraph(let inlines)? = doc.blocks.first else {
            Issue.record("\(doc.blocks)")
            return
        }
        #expect(inlinesToPlainText(inlines) == "before after")
    }

    @Test func pageBreakBetweenRunsKeepsTheWordBoundary() throws {
        // A w:br is unrepresentable in Markdown whatever its type, but the
        // runs it separates must not merge into a word the document never
        // had. A break ending a paragraph still leaves no stray marker.
        let cases: [(String, String)] = [
            (
                #"<w:p><w:r><w:t>Alfa</w:t><w:br w:type="page"/><w:t>Beta</w:t></w:r></w:p>"#,
                "Alfa\\\nBeta\n"
            ),
            (
                #"""
                <w:p><w:r><w:t>Alfa</w:t><w:br w:type="page"/></w:r></w:p>
                <w:p><w:r><w:t>Beta</w:t></w:r></w:p>
                """#,
                "Alfa\n\nBeta\n"
            ),
        ]
        for (body, expected) in cases {
            let document = "<w:document \(w)><w:body>\(body)</w:body></w:document>"
            let bytes = docxParts([("word/document.xml", document)])
            let markdown = try AnyDoc.markdown(bytes, format: .docx)
            #expect(markdown == expected, "body: \(body)")
        }
    }

    @Test func numberedHeadingKeepsItsNumber() throws {
        // H1: a heading style with numbering shows its label and advances
        // the sequence.
        let document = """
            <w:document \(w)><w:body>
            <w:p><w:pPr><w:pStyle w:val="H1"/></w:pPr><w:r><w:t>Intro</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="H1"/></w:pPr><w:r><w:t>Details</w:t></w:r></w:p>
            </w:body></w:document>
            """
        let styles = """
            <w:styles \(w)>
            <w:style w:type="paragraph" w:styleId="H1"><w:name w:val="heading 1"/>
                <w:pPr><w:numPr><w:numId w:val="1"/></w:numPr></w:pPr>
            </w:style></w:styles>
            """
        let numbering = """
            <w:numbering \(w)>
            <w:abstractNum w:abstractNumId="0">
                <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:start w:val="1"/>
                    <w:lvlText w:val="%1."/><w:pStyle w:val="H1"/></w:lvl>
            </w:abstractNum>
            <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
            </w:numbering>
            """
        let bytes = docxParts([
            ("word/document.xml", document),
            ("word/styles.xml", styles),
            ("word/numbering.xml", numbering),
        ])
        let doc = try parseDocx(bytes)
        var headings: [String] = []
        for block in doc.blocks {
            if case .heading(_, _, let content) = block {
                headings.append(inlinesToPlainText(content))
            }
        }
        #expect(headings == ["1. Intro", "2. Details"])
    }
}
