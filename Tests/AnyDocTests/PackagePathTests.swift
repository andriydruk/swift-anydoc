// Ported from src/package/path.rs tests.
import Testing
@testable import AnyDoc

@Suite struct PackagePathTests {
    private func path(_ base: String, _ r: String) throws -> String {
        try resolvePackageReference(basePart: base, reference: r).path
    }

    @Test func relativeAgainstBaseDirectory() throws {
        #expect(try path("word/document.xml", "media/image1.png") == "word/media/image1.png")
        #expect(try path("word/document.xml", "styles.xml") == "word/styles.xml")
        #expect(try path("content.opf", "ch1.xhtml") == "ch1.xhtml")
    }

    @Test func absoluteTargetsResolveFromRoot() throws {
        #expect(try path("word/document.xml", "/docProps/core.xml") == "docProps/core.xml")
    }

    @Test func dotSegmentsResolveAndClampAtRoot() throws {
        #expect(try path("OEBPS/text/ch1.xhtml", "../images/i.png") == "OEBPS/images/i.png")
        #expect(try path("a/b.xml", "./c.xml") == "a/c.xml")
        #expect(try path("a/b.xml", "../../../x.xml") == "x.xml")
    }

    @Test func fragmentsAndQueriesSplitOff() throws {
        var t = try resolvePackageReference(basePart: "OEBPS/ch1.xhtml", reference: "ch2.xhtml#sec-2")
        #expect(t.path == "OEBPS/ch2.xhtml")
        #expect(t.fragment == "sec-2")
        t = try resolvePackageReference(basePart: "OEBPS/ch1.xhtml", reference: "ch2.xhtml?x=1#f")
        #expect(t.path == "OEBPS/ch2.xhtml")
        #expect(t.fragment == "f")
    }

    @Test func fragmentsArePercentDecoded() throws {
        let t = try resolvePackageReference(
            basePart: "OEBPS/ch1.xhtml", reference: "ch2.xhtml#caf%C3%A9%20menu")
        #expect(t.fragment == "café menu")
        #expect(decodeFragment("caf%C3%A9") == "café")
    }

    @Test func percentDecodingWithinSegments() throws {
        #expect(try path("OEBPS/x.opf", "my%20file.xhtml") == "OEBPS/my file.xhtml")
    }

    @Test func encodedSeparatorsRejected() {
        #expect(throws: ConvertError.self) {
            try resolvePackageReference(basePart: "a/b.xml", reference: "x%2Fy.xml")
        }
        #expect(throws: ConvertError.self) {
            try resolvePackageReference(basePart: "a/b.xml", reference: "x%5Cy.xml")
        }
    }

    @Test func encodedTraversalRejected() {
        #expect(throws: ConvertError.self) {
            try resolvePackageReference(basePart: "a/b.xml", reference: "%2E%2E/secret.xml")
        }
        #expect(throws: ConvertError.self) {
            try resolvePackageReference(basePart: "a/b.xml", reference: "%2e%2e/secret.xml")
        }
    }

    @Test func plainFragmentOnlyReference() throws {
        let t = try resolvePackageReference(basePart: "OEBPS/ch1.xhtml", reference: "#local")
        #expect(t.path == "OEBPS/ch1.xhtml")
        #expect(t.fragment == "local")
    }

    @Test func rejectionMessagesQuoteTheSegment() {
        do {
            _ = try resolvePackageReference(basePart: "a/b.xml", reference: "x%2Fy.xml")
            Issue.record("expected an error")
        } catch let e as ConvertError {
            #expect(
                e.message
                    == "malformed document: percent-encoded separator in package reference "
                    + "segment \"x%2Fy.xml\"")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
