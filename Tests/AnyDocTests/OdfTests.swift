// Ported from src/formats/odf/mod.rs and src/formats/odf/text.rs tests, plus
// dedicated abuse-fixture coverage for the repeat-expansion budgets.
import Testing
@testable import AnyDoc

@Suite struct OdfTests {
    private let content = """
        <office:document-content
            xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
            <office:body><office:text><text:p>hello</text:p></office:text></office:body>
            </office:document-content>
        """

    private func odt(_ manifest: [UInt8]) -> [UInt8] {
        makeZip([
            ("META-INF/manifest.xml", manifest),
            ("content.xml", Array(content.utf8)),
        ])
    }

    @Test func corruptManifestDoesNotClassifyAsEncrypted() throws {
        let doc = try parseOdf(odt(Array("<manifest:manifest <<< not xml".utf8)))
        #expect(!doc.blocks.isEmpty)
    }

    private func odtWithContent(_ content: String) -> [UInt8] {
        makeZip([("content.xml", Array(content.utf8))])
    }

    private func tableDoc(_ rows: String) -> String {
        """
        <office:document-content
            xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
            xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0">
            <office:body><office:text><table:table>\(rows)</table:table></office:text></office:body>
            </office:document-content>
        """
    }

    @Test func repeatedRowsCannotAmplifyTextBeyondTheByteBudget() throws {
        // H3: the slot budget alone would admit 1000 copies of a 100 KB
        // cell (~100 MB); the duplicated-bytes budget rejects it up front.
        let fat = String(repeating: "x", count: 100_000)
        let rows = """
            <table:table-row table:number-rows-repeated="1000">
            <table:table-cell><text:p>\(fat)</text:p></table:table-cell>
            </table:table-row>
            """
        do {
            _ = try parseOdf(odtWithContent(tableDoc(rows)))
            Issue.record("expected the text-byte budget to trip")
        } catch let e as ConvertError {
            guard case .resourceLimit(let limit, _) = e else {
                Issue.record("expected the text-byte budget, got: \(e.message)")
                return
            }
            #expect(limit == "max_expansion_text_bytes")
        }
    }

    @Test func repeatedRowsParseContentOnce() throws {
        // A note inside a repeated row must register once, not per copy.
        let rows = """
            <table:table-row table:number-rows-repeated="3">
            <table:table-cell><text:p>cell<text:note text:id="n1">
            <text:note-body><text:p>note body</text:p></text:note-body>
            </text:note></text:p></table:table-cell>
            </table:table-row>
            """
        let doc = try parseOdf(odtWithContent(tableDoc(rows)))
        #expect(doc.notes.count == 1, "repeated rows must not duplicate notes")
    }

    @Test func styledRunsStopAtTablesAndWorkInsideCells() throws {
        let content = """
            <office:document-content
                xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
                xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
                xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0">
                <office:automatic-styles>
                  <style:style style:name="Source_20_Code" style:family="paragraph"/>
                </office:automatic-styles>
                <office:body><office:text>
                  <text:p text:style-name="Source_20_Code">before table</text:p>
                  <table:table><table:table-row><table:table-cell>
                    <text:p text:style-name="Source_20_Code">inside cell</text:p>
                  </table:table-cell></table:table-row></table:table>
                  <text:p>after table</text:p>
                </office:text></office:body>
                </office:document-content>
            """
        let doc = try parseOdf(odtWithContent(content))
        guard doc.blocks.count == 3,
            case .codeBlock(_, let before) = doc.blocks[0],
            case .table(let table) = doc.blocks[1],
            case .paragraph(let after) = doc.blocks[2]
        else {
            Issue.record("unexpected block order: \(doc.blocks)")
            return
        }
        #expect(before == "before table")
        #expect(inlinesToPlainText(after) == "after table")
        guard case .origin(let cell) = table.grid[0][0] else {
            Issue.record("expected an origin cell")
            return
        }
        guard cell.blocks.count == 1, case .codeBlock(_, let inside) = cell.blocks[0] else {
            Issue.record("unexpected cell blocks: \(cell.blocks)")
            return
        }
        #expect(inside == "inside cell")
    }

    @Test func resourceLimitInManifestIsFatal() throws {
        var manifest: [UInt8] = []
        for _ in 0..<(Limits.maxXmlDepth + 2) {
            manifest.append(contentsOf: Array("<d>".utf8))
        }
        do {
            _ = try parseOdf(odt(manifest))
            Issue.record("expected a fatal resource-limit error")
        } catch let e as ConvertError {
            guard case .resourceLimit(let limit, _) = e else {
                Issue.record("encryption probing must not swallow fatal errors, got: \(e.message)")
                return
            }
            #expect(limit == "max_xml_depth")
        }
    }

    // Ported from src/formats/odf/text.rs.
    @Test func internalHrefFragmentsArePercentDecoded() {
        #expect(odfClassifyHref("#caf%C3%A9%20menu") == .anchor("café menu"))
    }

    /// The three ods abuse fixtures exercise the repeat-expansion budgets
    /// through ODF's number-columns/rows-repeated and span handling: each
    /// must fail fast with `resourceLimit`, not by exhausting memory.
    @Test(arguments: ["emptyrowrepeat", "hugerepeat", "hugespan"])
    func abuseFixturesTripTheExpansionBudgetQuickly(_ name: String) throws {
        let path = fixtureRoot.appendingPathComponent("abuse/\(name)--errors.ods").path
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try AnyDoc.markdown(contentsOf: path)
            Issue.record("\(name): expected a resource-limit error")
        } catch let e as ConvertError {
            guard case .resourceLimit = e else {
                Issue.record("\(name): expected resourceLimit, got: \(e.message)")
                return
            }
        }
        let elapsed = clock.now - start
        #expect(
            elapsed < .seconds(10),
            "\(name): the budget must trip quickly, took \(elapsed)")
    }
}
