// Ported from src/package/xml.rs tests.
import Testing
@testable import AnyDoc

@Suite struct XmlTests {
    @Test func resolvesNamespacesRegardlessOfPrefix() throws {
        let xml = #"<x:root xmlns:x="urn:a" xmlns:y="urn:b"><y:kid x:id="1" plain="p"/></x:root>"#
        let root = try parseXml(Array(xml.utf8))
        let r = try #require(root.find("urn:a", "root"))
        let kid = try #require(r.find("urn:b", "kid"))
        #expect(kid.attr("urn:a", "id") == "1")
        #expect(kid.attr("urn:whatever", "plain") == "p")
        #expect(r.find("urn:b", "root") == nil)
    }

    @Test func qualifiedAndUnqualifiedLookupsAreSeparate() throws {
        let xml = #"<x:root xmlns:x="urn:a" xmlns:r="urn:r"><x:kid r:id="rel" id="plain"/></x:root>"#
        let root = try parseXml(Array(xml.utf8))
        let kid = try #require(root.firstDescendant("urn:a", "kid"))
        #expect(kid.attrQualified("urn:r", "id") == "rel")
        #expect(kid.attrUnqualified("id") == "plain")
        #expect(kid.attr("urn:r", "id") == "rel")
        #expect(kid.attrQualified("urn:other", "id") == nil)
    }

    @Test func strictOoxmlNamespacesNormalizeToTransitional() throws {
        #expect(normalizeOoxmlUri("http://purl.oclc.org/ooxml/wordprocessingml/main") == Ns.w)
        #expect(normalizeOoxmlUri("http://purl.oclc.org/ooxml/officeDocument/relationships") == Ns.r)
        #expect(
            normalizeOoxmlUri("http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument")
                == "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument")
        #expect(normalizeOoxmlUri(Ns.w) == nil)
        #expect(normalizeOoxmlUri("urn:schemas-microsoft-com:vml") == nil)

        let xml = #"<w:document xmlns:w="http://purl.oclc.org/ooxml/wordprocessingml/main"><w:body/></w:document>"#
        let root = try parseXml(Array(xml.utf8))
        let doc = try #require(root.find(Ns.w, "document"))
        #expect(doc.find(Ns.w, "body") != nil)
    }

    @Test func defaultNamespaceAppliesToElementsNotAttributes() throws {
        let xml = #"<root xmlns="urn:d"><kid id="1"/></root>"#
        let root = try parseXml(Array(xml.utf8))
        let r = try #require(root.find("urn:d", "root"))
        let kid = try #require(r.find("urn:d", "kid"))
        #expect(kid.attrAny("id") == "1")
    }

    @Test func requiresPrefixesResolveInTheirLexicalScope() throws {
        let xml = """
            <mc:AlternateContent
                xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">
                <mc:Choice xmlns:z="urn:one" Requires="z"/>
                <mc:Choice xmlns:z="urn:two" Requires="z unknownprefix"/>
            </mc:AlternateContent>
            """
        let root = try parseXml(Array(xml.utf8))
        let alt = try #require(root.find(Ns.mc, "AlternateContent"))
        let choices = alt.findAll(Ns.mc, "Choice")
        #expect(choices[0].attrAny("Requires") == "urn:one")
        #expect(choices[1].attrAny("Requires") == "urn:two unknownprefix")
    }

    @Test func utf16WithBomDecodes() throws {
        let text = "<r a=\"caf\u{e9}\">\u{4f60}\u{597d}</r>"
        var bytes: [UInt8] = [0xFF, 0xFE]
        for unit in text.utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        let root = try parseXml(bytes)
        let r = try #require(root.childElements.first)
        #expect(r.attrAny("a") == "caf\u{e9}")
        #expect(r.text() == "\u{4f60}\u{597d}")
    }

    @Test func unclosedElementsRecovered() throws {
        let root = try parseXml(Array("<a><b>text".utf8))
        let a = try #require(root.childElements.first)
        #expect(a.local == "a")
        #expect(a.text() == "text")
    }

    @Test func depthLimitIsHardError() {
        var xml: [UInt8] = []
        for _ in 0..<(Limits.maxXmlDepth + 2) {
            xml.append(contentsOf: Array("<d>".utf8))
        }
        #expect(throws: ConvertError.self) {
            _ = try parseXml(xml)
        }
    }

    @Test func deepDomTraversalIsIterative() throws {
        let depth = Limits.maxXmlDepth - 1
        var xml: [UInt8] = []
        for _ in 0..<depth {
            xml.append(contentsOf: Array("<d>".utf8))
        }
        xml.append(contentsOf: Array("leaf".utf8))
        for _ in 0..<depth {
            xml.append(contentsOf: Array("</d>".utf8))
        }
        let root = try parseXml(xml)
        #expect(root.text() == "leaf")
        #expect(root.descendants("", "never").isEmpty)
    }

    @Test func entitiesInTextAndAttributes() throws {
        // Text uses the extended table; attributes only the predefined five
        // and numeric references, with raw fallback on unknown ones.
        let root = try parseXml(Array(#"<r a="a&amp;b" b="x&nbsp;y">&mdash;&#65;&unknown;</r>"#.utf8))
        let r = try #require(root.childElements.first)
        #expect(r.attrAny("a") == "a&b")
        #expect(r.attrAny("b") == "x&nbsp;y")  // raw fallback, unnormalized
        #expect(r.text() == "\u{2014}A&unknown;")
    }

    @Test func cdataAndComments() throws {
        let root = try parseXml(Array("<r><!-- note --><![CDATA[a<b&c]]>tail</r>".utf8))
        let r = try #require(root.childElements.first)
        #expect(r.text() == "a<b&ctail")
    }
}
