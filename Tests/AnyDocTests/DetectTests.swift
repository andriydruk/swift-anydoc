// Ported from src/formats/detect.rs tests (OLE construction cases wait on
// the CFB implementation), plus real-fixture detection and the archive-layer
// error strings the malformed goldens pin.
import Foundation
import Testing
@testable import AnyDoc

@Suite struct DetectTests {
    @Test func signatures() {
        #expect(Format.detect(from: Array("%PDF-1.7\n".utf8)) == .pdf)
        // Leading junk before the header is accepted, bounded.
        var junk = [UInt8](repeating: UInt8(ascii: " "), count: 500)
        junk += Array("%PDF-1.4".utf8)
        #expect(Format.detect(from: junk) == .pdf)
        var far = [UInt8](repeating: UInt8(ascii: " "), count: 1200)
        far += Array("%PDF-1.4".utf8)
        #expect(Format.detect(from: far) == nil)
        #expect(Format.detect(from: Array("{\\rtf1\\ansi hi}".utf8)) == .rtf)
        #expect(Format.detect(from: Array("a,b,c\n1,2,3\n".utf8)) == nil)
        #expect(Format.detect(from: []) == nil)
    }

    @Test func containerSignatureWinsOverAnEarlyEmbeddedPdf() {
        let pkg = makeZip([
            ("embedded.pdf", Array("%PDF-1.7\n".utf8)),
            ("word/document.xml", Array("<document/>".utf8)),
        ])
        #expect(Format.detect(from: pkg) == .docx)
    }

    // The Rust suite constructs OLE files with the cfb crate and asserts
    // WordDocument/PowerPoint Document/Workbook stream detection. Until
    // Shared/Cfb.swift lands, an OLE compound file cannot be opened, so
    // every OLE input detects as nil. Flip this to the stream-name
    // assertions (doc/ppt/xls fixtures) when CompoundFile is implemented.
    @Test func oleFilesDetectAsNilUntilCfbLands() throws {
        let doc = try readFile(fixturePath("doc/text.doc"))
        #expect(doc.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]))
        #expect(Format.detect(from: doc) == nil)
        let xls = try readFile(fixturePath("xls/sheet.xls"))
        #expect(Format.detect(from: xls) == nil)
    }

    @Test func mimetypeIdentifiesOdfAndEpub() {
        for (mime, format): (String, Format) in [
            ("application/vnd.oasis.opendocument.text", .odt),
            ("application/vnd.oasis.opendocument.text-template", .odt),
            ("application/vnd.oasis.opendocument.spreadsheet", .ods),
            ("application/vnd.oasis.opendocument.presentation", .odp),
            ("application/epub+zip", .epub),
        ] {
            #expect(Format.detect(from: makeZip([("mimetype", Array(mime.utf8))])) == format)
        }
        #expect(Format.detect(from: makeZip([("mimetype", Array("application/zip".utf8))])) == nil)
    }

    @Test func opcMainPartContentTypeWinsOverItsPath() {
        // Main part at a nonconventional path; only the content type says
        // this is a presentation.
        let rels = """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="/custom/main.xml"/>
            </Relationships>
            """
        let types = """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
                <Override PartName="/custom/main.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
            </Types>
            """
        let pkg = makeZip([
            ("_rels/.rels", Array(rels.utf8)),
            ("[Content_Types].xml", Array(types.utf8)),
            ("custom/main.xml", Array("<p/>".utf8)),
        ])
        #expect(Format.detect(from: pkg) == .pptx)
    }

    @Test func opcStaleContentTypesDeferToTheRootElement() {
        // The Override names a part that does not exist; the real main part
        // only gets the generic Default. Its w:document root decides.
        let rels = """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="content/main.xml"/>
            </Relationships>
            """
        let types = """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
                <Default Extension="xml" ContentType="application/xml"/>
                <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            </Types>
            """
        let main = """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body/></w:document>
            """
        let pkg = makeZip([
            ("_rels/.rels", Array(rels.utf8)),
            ("[Content_Types].xml", Array(types.utf8)),
            ("content/main.xml", Array(main.utf8)),
        ])
        #expect(Format.detect(from: pkg) == .docx)
    }

    @Test func opcFallsBackToConventionalPaths() {
        // No content types: the main-part path decides.
        let rels = """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
            </Relationships>
            """
        let withRels = makeZip([
            ("_rels/.rels", Array(rels.utf8)),
            ("word/document.xml", Array("<d/>".utf8)),
        ])
        #expect(Format.detect(from: withRels) == .docx)

        // No rels at all: conventional part existence decides.
        let noRels = makeZip([("xl/workbook.bin", [0])])
        #expect(Format.detect(from: noRels) == .excel)
    }

    @Test func brokenOdfAndEpubFallBackToManifestAndContainer() {
        let manifest = """
            <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0">
                <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
            </manifest:manifest>
            """
        let odf = makeZip([
            ("META-INF/manifest.xml", Array(manifest.utf8)),
            ("content.xml", Array("<c/>".utf8)),
        ])
        #expect(Format.detect(from: odf) == .ods)

        let epub = makeZip([("META-INF/container.xml", Array("<container/>".utf8))])
        #expect(Format.detect(from: epub) == .epub)

        // A plain zip is not a document.
        #expect(Format.detect(from: makeZip([("readme.txt", Array("hi".utf8))])) == nil)
    }

    @Test func realFixturesDetect() throws {
        for (path, format): (String, Format?) in [
            ("docx/text.docx", .docx),
            ("docx/handmade-strict.docx", .docx),
            ("docx/handmade-altpath.docx", .docx),
            ("odt/text.odt", .odt),
            ("ods/sheet.ods", .ods),
            ("odp/pres.odp", .odp),
            ("epub/book.epub", .epub),
            ("epub/handmade-features.epub", .epub),
            ("pdf/text.pdf", .pdf),
            ("rtf/text.rtf", .rtf),
            ("xlsx/sheet.xlsx", .excel),
            ("pptx/pres.pptx", .pptx),
            ("pptx/handmade-strict.pptx", .pptx),
            ("csv/sheet.csv", nil),
            ("csv/handmade-utf16.csv", nil),
        ] {
            let bytes = try readFile(fixturePath(path))
            #expect(Format.detect(from: bytes) == format, "fixture \(path)")
        }
    }

    @Test func malformedDocxFixturesPinTheArchiveErrorString() throws {
        for name in ["malformed/empty--errors.docx", "malformed/truncated--errors.docx"] {
            let bytes = try readFile(fixturePath(name))
            do {
                _ = try Package.open(bytes)
                Issue.record("expected \(name) to fail to open")
            } catch let e as ConvertError {
                #expect(
                    e.message
                        == "malformed document: not a readable zip archive: "
                        + "invalid Zip archive: Could not find EOCD",
                    "fixture \(name)")
            }
        }
    }
}

func fixturePath(_ relative: String) -> String {
    fixtureRoot.appendingPathComponent(relative).path
}
