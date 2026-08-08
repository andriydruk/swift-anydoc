// The content-stream interpreter and ToUnicode decoding, checked against
// the fixture's actual text.
import Foundation
import Testing

@testable import AnyDoc

private func loadFixture() throws -> PdfDocument {
    let path = fixtureRoot.appendingPathComponent("pdf/text.pdf").path
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    return try PdfDocument(bytes: bytes)
}

/// The pages of a document, in tree order.
func pdfPages(_ document: inout PdfDocument) -> [PdfDictionary] {
    guard let catalog = document.catalog,
        let root = document.value(catalog, "Pages")?.asDictionary
    else { return [] }
    var out: [PdfDictionary] = []
    var queue: [PdfDictionary] = [root]
    var visited = 0
    while !queue.isEmpty, visited < 10_000 {
        let node = queue.removeFirst()
        visited += 1
        let type = node["Type"]?.asName
        if type == Array("Page".utf8) {
            out.append(node)
            continue
        }
        guard let kids = document.value(node, "Kids")?.asArray else { continue }
        var children: [PdfDictionary] = []
        for kid in kids {
            if let dict = document.resolve(kid).asDictionary { children.append(dict) }
        }
        queue.insert(contentsOf: children, at: 0)
    }
    return out
}

/// The ToUnicode CMaps of a page's fonts, by resource name.
func pdfPageFontCMaps(_ document: inout PdfDocument, _ page: PdfDictionary)
    -> [String: PdfToUnicodeCMap]
{
    var out: [String: PdfToUnicodeCMap] = [:]
    guard let resources = document.value(page, "Resources")?.asDictionary,
        let fonts = document.value(resources, "Font")?.asDictionary
    else { return out }
    for key in fonts.keys {
        let name = String(decoding: key, as: UTF8.self)
        guard let font = document.value(fonts, name)?.asDictionary,
            let toUnicode = document.value(font, "ToUnicode")?.asStream,
            let data = document.decodedStream(toUnicode)
        else { continue }
        out[name] = parsePdfToUnicode(data)
    }
    return out
}

/// The glyph metrics of a page's fonts, by resource name.
func pdfPageFontMetrics(_ document: inout PdfDocument, _ page: PdfDictionary)
    -> [String: PdfFontWidths]
{
    var out: [String: PdfFontWidths] = [:]
    guard let resources = document.value(page, "Resources")?.asDictionary,
        let fonts = document.value(resources, "Font")?.asDictionary
    else { return out }
    for key in fonts.keys {
        let name = String(decoding: key, as: UTF8.self)
        guard let font = document.value(fonts, name)?.asDictionary,
            let info = pdfParseFontWidths(&document, font)
        else { continue }
        out[name] = info
    }
    return out
}

/// Every text run of a page, decoded through its fonts' ToUnicode CMaps.
func pdfPageTextRuns(_ document: inout PdfDocument, _ page: PdfDictionary) -> [PdfTextRun] {
    let cmaps = pdfPageFontCMaps(&document, page)
    let metrics = pdfPageFontMetrics(&document, page)
    var data: [UInt8] = []
    // /Contents is a stream or an array of streams that concatenate.
    if let single = document.value(page, "Contents")?.asStream {
        data = document.decodedStream(single) ?? []
    } else if let array = document.value(page, "Contents")?.asArray {
        for entry in array {
            guard let stream = document.resolve(entry).asStream,
                let decoded = document.decodedStream(stream)
            else { continue }
            data.append(contentsOf: decoded)
            data.append(0x0A)
        }
    }
    let operations = pdfParseContentStream(data)
    return pdfExtractTextRuns(operations, metrics: { metrics[$0] }) { fontName, bytes in
        guard let cmap = cmaps[fontName] else {
            // Without a CMap the bytes are their own code points, which is
            // right for the ASCII a simple font shows.
            return String(decoding: bytes, as: UTF8.self)
        }
        var out = ""
        let width = cmap.codeByteLength
        var i = 0
        while i < bytes.count {
            var code: UInt32 = 0
            for k in 0..<width where i + k < bytes.count {
                code = (code << 8) | UInt32(bytes[i + k])
            }
            out += cmap.lookup(code) ?? ""
            i += width
        }
        return out
    }
}

@Suite struct PdfContentStreamTests {
    /// Operands accumulate until an operator consumes them.
    @Test func operationsSplitAtOperators() {
        let ops = pdfParseContentStream(Array("1 0 0 1 72 720 cm BT /F1 12 Tf (Hi) Tj ET".utf8))
        #expect(ops.map(\.`operator`) == ["cm", "BT", "Tf", "Tj", "ET"])
        #expect(ops[0].operands.count == 6)
        #expect(ops[2].operands.first?.asName == Array("F1".utf8))
        #expect(ops[3].operands.first?.asStringBytes == Array("Hi".utf8))
        #expect(ops[1].operands.isEmpty)
    }

    /// `true`/`false`/`null` are operands, not operators.
    @Test func keywordOperandsAreNotOperators() {
        let ops = pdfParseContentStream(Array("true false null gs".utf8))
        #expect(ops.count == 1)
        #expect(ops[0].`operator` == "gs")
        #expect(ops[0].operands.count == 3)
    }

    /// A TJ array mixes strings and displacements.
    @Test func textArraysParse() {
        let ops = pdfParseContentStream(Array("[(A) -250 (B)] TJ".utf8))
        #expect(ops.count == 1)
        let array = ops[0].operands.first?.asArray
        #expect(array?.count == 3)
        #expect(array?[1].asNumber == -250)
    }

    /// Inline image data is binary and must not be lexed as operators.
    @Test func inlineImagesAreSkipped() {
        // The payload deliberately contains bytes that look like operators.
        let source = "BI /W 2 /H 2 ID \u{1}BT ET Tj\u{2} EI (after) Tj"
        let ops = pdfParseContentStream(Array(source.utf8))
        #expect(ops.map(\.`operator`) == ["Tj"])
        #expect(ops.first?.operands.first?.asStringBytes == Array("after".utf8))
    }

    /// A malformed token is skipped rather than ending the stream.
    @Test func malformedTokensResynchronize() {
        let ops = pdfParseContentStream(Array("( unterminated BT (ok) Tj".utf8))
        // The bad string is dropped; the operators after it still run.
        #expect(ops.map(\.`operator`).contains("Tj"))
    }
}

@Suite struct PdfToUnicodeTests {
    /// `bfchar` maps single codes.
    @Test func bfcharMapsCodes() {
        let cmap = parsePdfToUnicode(
            Array(
                """
                /CIDInit /ProcSet findresource begin
                1 begincodespacerange <00> <FF> endcodespacerange
                2 beginbfchar
                <41> <0041>
                <42> <00420043>
                endbfchar
                end
                """.utf8))
        #expect(cmap.codeByteLength == 1)
        #expect(cmap.lookup(0x41) == "A")
        // A destination of several units is a multi-scalar mapping.
        #expect(cmap.lookup(0x42) == "BC")
        #expect(cmap.lookup(0x43) == nil)
    }

    /// `bfrange` maps a span, incrementing the destination.
    @Test func bfrangeIncrementsDestinations() {
        let cmap = parsePdfToUnicode(
            Array(
                """
                1 begincodespacerange <0000> <FFFF> endcodespacerange
                1 beginbfrange
                <0041> <0043> <0061>
                endbfrange
                """.utf8))
        #expect(cmap.codeByteLength == 2)
        #expect(cmap.lookup(0x41) == "a")
        #expect(cmap.lookup(0x42) == "b")
        #expect(cmap.lookup(0x43) == "c")
        #expect(cmap.lookup(0x44) == nil)
    }

    /// A `bfrange` may list its destinations explicitly.
    @Test func bfrangeArrayDestinations() {
        let cmap = parsePdfToUnicode(
            Array(
                """
                1 beginbfrange
                <01> <03> [<0058> <0059> <005A>]
                endbfrange
                """.utf8))
        #expect(cmap.lookup(1) == "X")
        #expect(cmap.lookup(2) == "Y")
        #expect(cmap.lookup(3) == "Z")
    }

    /// Surrogate pairs in a destination become one scalar.
    @Test func surrogatePairsCombine() {
        let cmap = parsePdfToUnicode(
            Array("1 beginbfchar\n<01> <D834DD1E>\nendbfchar".utf8))
        // U+1D11E MUSICAL SYMBOL G CLEF, which the fixture also uses.
        #expect(cmap.lookup(1) == "\u{1D11E}")
    }

    /// An absurd range is rejected rather than materialized.
    @Test func runawayRangesAreRejected() {
        let cmap = parsePdfToUnicode(
            Array("1 beginbfrange\n<0000> <FFFFFF> <0041>\nendbfrange".utf8))
        #expect(cmap.isEmpty)
    }
}

@Suite struct PdfFixtureTextTests {
    /// The fixture's fonts all carry a ToUnicode CMap; without them the
    /// text would come out as glyph indices.
    @Test func fixtureFontsCarryCMaps() throws {
        var document = try loadFixture()
        let pages = pdfPages(&document)
        #expect(pages.count == 2)
        var total = 0
        for page in pages {
            let cmaps = pdfPageFontCMaps(&document, page)
            for (_, cmap) in cmaps {
                #expect(!cmap.isEmpty)
                total += cmap.map.count
            }
        }
        #expect(total > 0, "no ToUnicode mappings were parsed")
        print("pdf cmaps: \(total) code mappings")
    }

    /// End to end: the fixture's own words must come out of the pipeline.
    @Test func fixtureTextExtracts() throws {
        var document = try loadFixture()
        let pages = pdfPages(&document)
        var all = ""
        var runs = 0
        for page in pages {
            let pageRuns = pdfPageTextRuns(&document, page)
            runs += pageRuns.count
            all += pageRuns.map(\.text).joined()
        }
        print("pdf text: \(runs) runs, \(all.count) characters")
        // Strings taken from the committed golden for this fixture.
        for expected in [
            "Fixture Document", "Plain paragraph", "Lists", "First numbered", "Roman sub sub",
            "Notes and special text", "Links and anchors", "Quote and code",
        ] {
            #expect(all.contains(expected), "extracted text is missing \(expected.debugDescription)")
        }
        // The astral character the fixture uses to test surrogate handling.
        #expect(all.contains("\u{1D11E}"), "the musical clef did not survive decoding")
    }

    /// Runs must carry usable geometry: the fixture is a normal upright
    /// page, so text descends the page and sizes are plausible.
    @Test func runsCarryPlausibleGeometry() throws {
        var document = try loadFixture()
        let pages = pdfPages(&document)
        let runs = pdfPageTextRuns(&document, pages[0])
        #expect(!runs.isEmpty)
        for run in runs {
            #expect(run.fontSize > 0 && run.fontSize < 100, "implausible size \(run.fontSize)")
            #expect(run.x.isFinite && run.y.isFinite)
        }
        // The first run should sit near the top of a US Letter page.
        let first = try #require(runs.first)
        #expect(first.y > 600, "the first run is not near the top: \(first.y)")
    }
}

@Suite struct PdfFontWidthTests {
    /// A simple font's `/Widths` is indexed from `/FirstChar`.
    @Test func simpleFontWidthsIndexFromFirstChar() throws {
        var document = try loadFixture()
        var font = PdfDictionary()
        font["Subtype"] = .name(Array("TrueType".utf8))
        font["FirstChar"] = .integer(65)
        font["LastChar"] = .integer(67)
        font["Widths"] = .array([.integer(500), .integer(600), .integer(700)])
        let info = try #require(pdfParseFontWidths(&document, font))
        #expect(info.width(of: 65) == 500)
        #expect(info.width(of: 66) == 600)
        #expect(info.width(of: 67) == 700)
        // Outside the declared span a simple font has no width.
        #expect(info.width(of: 68) == 0)
        #expect(!info.isCid)
        #expect(info.unitsScale == 0.001)
        // No code 32 in the table, so the standard-grid default applies.
        #expect(info.spaceWidth == 250)
    }

    /// A `/Widths` array longer than `/LastChar` allows is truncated.
    @Test func widthsStopAtLastChar() throws {
        var document = try loadFixture()
        var font = PdfDictionary()
        font["Subtype"] = .name(Array("Type1".utf8))
        font["FirstChar"] = .integer(65)
        font["LastChar"] = .integer(66)
        font["Widths"] = .array([.integer(500), .integer(600), .integer(700)])
        let info = try #require(pdfParseFontWidths(&document, font))
        #expect(info.widths.count == 2)
        #expect(info.width(of: 67) == 0)
    }

    /// Type 3 fonts declare their own grid through `/FontMatrix`.
    @Test func type3FontsUseTheirFontMatrix() throws {
        var document = try loadFixture()
        var font = PdfDictionary()
        font["Subtype"] = .name(Array("Type3".utf8))
        font["FirstChar"] = .integer(97)
        font["LastChar"] = .integer(97)
        font["Widths"] = .array([.integer(1024)])
        font["FontMatrix"] = .array([
            .real(0.000488), .real(0), .real(0), .real(0.000488), .real(0), .real(0),
        ])
        let info = try #require(pdfParseFontWidths(&document, font))
        #expect(abs(info.unitsScale - 0.000488) < 1e-6)
        // Off the standard grid, the space is estimated from the average.
        #expect(info.spaceWidth != 250)
    }

    /// The `/W` array's two forms: a consecutive list and a range.
    @Test func cidWidthArrayHandlesBothForms() throws {
        var document = try loadFixture()
        var widths: [UInt16: UInt16] = [:]
        // 1 [100 200 300]  then  10 12 900
        let array: [PdfObject] = [
            .integer(1), .array([.integer(100), .integer(200), .integer(300)]),
            .integer(10), .integer(12), .integer(900),
        ]
        parseCidWidthArray(&document, array, into: &widths)
        #expect(widths[1] == 100)
        #expect(widths[2] == 200)
        #expect(widths[3] == 300)
        #expect(widths[10] == 900)
        #expect(widths[11] == 900)
        #expect(widths[12] == 900)
        #expect(widths[13] == nil)
    }

    /// A composite font falls back to `/DW` for codes the `/W` array omits.
    @Test func compositeFontsUseTheDefaultWidth() throws {
        var document = try loadFixture()
        var cidFont = PdfDictionary()
        cidFont["DW"] = .integer(1000)
        cidFont["W"] = .array([.integer(32), .array([.integer(500)])])
        var font = PdfDictionary()
        font["Subtype"] = .name(Array("Type0".utf8))
        font["DescendantFonts"] = .array([.dictionary(cidFont)])
        let info = try #require(pdfParseFontWidths(&document, font))
        #expect(info.isCid)
        #expect(info.width(of: 32) == 500)
        #expect(info.width(of: 999) == 1000)
        #expect(info.spaceWidth == 500)
    }

    /// The string width sums glyphs and adds the spacing that applies per
    /// glyph and per space.
    @Test func stringWidthAddsSpacing() {
        var font = PdfFontWidths()
        font.widths = [65: 500, 32: 250]
        font.unitsScale = 0.001
        let bytes: [UInt8] = [65, 32, 65]
        // (500 + 250 + 500)/1000 * 10 = 12.5
        #expect(
            abs(pdfStringWidth(bytes, font, fontSize: 10, charSpacing: 0, wordSpacing: 0) - 12.5)
                < 1e-4)
        // Three glyphs of char spacing, one space of word spacing.
        let spaced = pdfStringWidth(bytes, font, fontSize: 10, charSpacing: 1, wordSpacing: 2)
        #expect(abs(spaced - (12.5 + 3 + 2)) < 1e-4)
    }

    /// The fixture's fonts must all yield metrics, and its runs must have
    /// non-zero widths now that they are measured.
    @Test func fixtureRunsHaveMeasuredWidths() throws {
        var document = try loadFixture()
        let pages = pdfPages(&document)
        let metrics = pdfPageFontMetrics(&document, pages[0])
        #expect(!metrics.isEmpty, "no font metrics were parsed")
        for (name, info) in metrics {
            #expect(!info.widths.isEmpty, "font \(name) has no widths")
        }
        let runs = pdfPageTextRuns(&document, pages[0])
        let measured = runs.filter { $0.width > 0 }
        #expect(
            measured.count > runs.count / 2,
            "only \(measured.count) of \(runs.count) runs were measured")
        print("pdf widths: \(measured.count)/\(runs.count) runs measured")
    }

    /// The advance is checked exactly, on a stream whose every quantity is
    /// known, rather than statistically across the fixture. With a space
    /// width of 250/1000, the space threshold is 100 and the column-gap
    /// threshold 400, both in the thousandths TJ counts in.
    @Test func tjAdvanceIsExact() {
        var font = PdfFontWidths()
        font.widths = [65: 500, 66: 500]
        font.unitsScale = 0.001
        font.spaceWidth = 250

        // A -200 displacement is wider than a space but narrower than a
        // column gap: one run, with a space in it.
        // "AB" = 10.0, the gap = 2.0, "AB" = 10.0, so the advance is 22.0.
        let source = "BT /F1 10 Tf 100 700 Td [(AB) -200 (AB)] TJ (AB) Tj ET"
        let runs = pdfExtractTextRuns(
            pdfParseContentStream(Array(source.utf8)), metrics: { _ in font }
        ) { _, bytes in String(decoding: bytes, as: UTF8.self) }

        #expect(runs.count == 2)
        #expect(runs[0].text == "AB AB")
        #expect(abs(runs[0].x - 100) < 1e-4)
        #expect(abs(runs[0].width - 22) < 1e-4)
        // The following Tj starts exactly where the array ended.
        #expect(abs(runs[1].x - 122) < 1e-4, "the next run began at \(runs[1].x), expected 122")
        #expect(abs(runs[1].width - 10) < 1e-4)
    }

    /// A column-scale displacement splits the array instead, so a run never
    /// spans a slot another glyph occupies.
    @Test func columnGapsSplitTheArray() {
        var font = PdfFontWidths()
        font.widths = [65: 500, 66: 500]
        font.unitsScale = 0.001
        font.spaceWidth = 250

        // -1000 is past the column-gap threshold: two runs, 10.0 of text,
        // then a 10.0 hole, then 10.0 of text.
        let source = "BT /F1 10 Tf 100 700 Td [(AB) -1000 (AB)] TJ ET"
        let runs = pdfExtractTextRuns(
            pdfParseContentStream(Array(source.utf8)), metrics: { _ in font }
        ) { _, bytes in String(decoding: bytes, as: UTF8.self) }

        #expect(runs.count == 2)
        #expect(runs[0].text == "AB")
        #expect(runs[1].text == "AB")
        #expect(abs(runs[0].x - 100) < 1e-4)
        #expect(abs(runs[0].width - 10) < 1e-4)
        // The second segment starts past the hole, not at the first's end.
        #expect(abs(runs[1].x - 120) < 1e-4, "the second segment began at \(runs[1].x)")
    }

    /// A displacement too small to be a space does not become one.
    @Test func smallDisplacementsDoNotBecomeSpaces() {
        var font = PdfFontWidths()
        font.widths = [65: 500]
        font.unitsScale = 0.001
        font.spaceWidth = 250
        let source = "BT /F1 10 Tf [(A) -50 (A)] TJ ET"
        let runs = pdfExtractTextRuns(
            pdfParseContentStream(Array(source.utf8)), metrics: { _ in font }
        ) { _, bytes in String(decoding: bytes, as: UTF8.self) }
        #expect(runs.first?.text == "AA")
    }

    /// Runs must not pile up at one x, which is what a missing advance
    /// would produce.
    @Test func runsDoNotShareOneOrigin() throws {
        var document = try loadFixture()
        let pages = pdfPages(&document)
        let runs = pdfPageTextRuns(&document, pages[0])
        let distinctX = Set(runs.map { Int($0.x.rounded()) })
        #expect(distinctX.count > runs.count / 4, "runs cluster at too few positions")
    }
}

@Suite struct PdfLayoutTests {
    private func run(_ text: String, _ x: Float, _ y: Float, width: Float = 20) -> PdfTextRun {
        PdfTextRun(
            text: text, x: x, y: y, fontSize: 10, width: width, fontName: "F1", renderingMode: 0)
    }

    /// Runs group by baseline, and a writer's back-jump joins the line it
    /// belongs to instead of starting a new one.
    @Test func runsGroupByBaseline() {
        let runs = [
            run("one", 100, 700), run("two", 130, 700),
            // Emitted last, positioned first, and half a point off the
            // baseline — exactly the shape the fixture produces.
            run("back", 10, 700.5),
            run("next", 100, 680),
        ]
        let lines = pdfGroupIntoLines(runs)
        #expect(lines.count == 2)
        #expect(lines[0].items.map(\.text) == ["back", "one", "two"])
        #expect(lines[1].items.map(\.text) == ["next"])
    }

    /// Lines come out top to bottom, which is descending y in PDF space.
    @Test func linesAreOrderedTopToBottom() {
        let runs = [run("bottom", 0, 100), run("top", 0, 700), run("middle", 0, 400)]
        #expect(pdfGroupIntoLines(runs).map { $0.items[0].text } == ["top", "middle", "bottom"])
    }

    /// The horizontal gap decides whether two runs are one word or two.
    @Test func gapsBecomeWordBoundaries() {
        func item(_ text: String, _ x: Float, _ width: Float) -> PdfLayoutItem {
            PdfLayoutItem(text: text, x: x, y: 0, width: width, fontSize: 10, fontName: "F")
        }
        // Touching runs are one word.
        #expect(!pdfNeedsSpace(item("Hel", 0, 15), item("lo", 15, 10), "Hel"))
        // A gap of a third of an em is a word boundary.
        #expect(pdfNeedsSpace(item("Hello", 0, 25), item("World", 28, 25), "Hello"))
        // Punctuation follows without a space.
        #expect(!pdfNeedsSpace(item("www", 0, 15), item(".com", 20, 20), "www"))
        // A colon before a value takes one.
        #expect(pdfNeedsSpace(item("Key:", 0, 20), item("value", 21, 25), "Key:"))
        // A hyphen binds the words it joins.
        #expect(!pdfNeedsSpace(item("well-", 0, 25), item("known", 30, 25), "well-"))
        // A column-scale void always separates.
        #expect(pdfNeedsSpace(item("left", 0, 20), item("right", 300, 25), "left"))
    }

    /// An explicit space in a run is a word boundary. The runs are trimmed
    /// before joining, so this is the case most easily lost.
    @Test func explicitSpacesSurviveTrimming() {
        func item(_ text: String, _ x: Float, _ width: Float) -> PdfLayoutItem {
            PdfLayoutItem(text: text, x: x, y: 0, width: width, fontSize: 10, fontName: "F")
        }
        // Abutting runs that would otherwise join, but the writer stated the
        // boundary outright.
        #expect(pdfNeedsSpace(item("with ", 0, 25), item("bold", 25, 20), "with"))
        #expect(pdfNeedsSpace(item("and", 0, 15), item(" struck", 15, 30), "and"))
    }

    /// Digits and their separators stay one number across small gaps.
    @Test func numbersStayJoined() {
        func item(_ text: String, _ x: Float, _ width: Float) -> PdfLayoutItem {
            PdfLayoutItem(text: text, x: x, y: 0, width: width, fontSize: 10, fontName: "F")
        }
        #expect(!pdfNeedsSpace(item("34,", 0, 15), item("208", 16, 15), "34,"))
        #expect(!pdfNeedsSpace(item("+13.", 0, 20), item("0", 21, 5), "+13."))
    }

    /// Lines separated by more than the usual pitch start a paragraph.
    @Test func paragraphsBreakOnVerticalGaps() {
        func line(_ text: String, _ y: Float, x: Float = 100) -> PdfTextLine {
            PdfTextLine(
                items: [
                    PdfLayoutItem(text: text, x: x, y: y, width: 50, fontSize: 10, fontName: "F")
                ], y: y)
        }
        // A 12pt pitch, then a 40pt jump.
        let paragraphs = pdfGroupIntoParagraphs([
            line("a", 700), line("b", 688), line("c", 676), line("d", 636),
        ])
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].count == 3)
        #expect(paragraphs[1].count == 1)
    }

    /// A step in the left edge is a new block even at the usual pitch.
    @Test func paragraphsBreakOnIndentChanges() {
        func line(_ text: String, _ y: Float, _ x: Float) -> PdfTextLine {
            PdfTextLine(
                items: [
                    PdfLayoutItem(text: text, x: x, y: y, width: 50, fontSize: 10, fontName: "F")
                ], y: y)
        }
        let paragraphs = pdfGroupIntoParagraphs([
            line("a", 700, 100), line("b", 688, 100), line("c", 676, 140),
        ])
        #expect(paragraphs.count == 2)
        #expect(paragraphs[1][0].items[0].text == "c")
    }
}

@Suite struct PdfFixtureLayoutTests {
    /// The fixture laid out must read as prose, in document order.
    @Test func fixtureLaysOutIntoReadableLines() throws {
        var document = try loadFixture()
        let pages = pdfPages(&document)
        var allLines: [String] = []
        for page in pages {
            for line in pdfGroupIntoLines(pdfPageTextRuns(&document, page)) {
                let text = pdfLineText(line)
                if !text.isEmpty { allLines.append(text) }
            }
        }
        print("pdf layout: \(allLines.count) lines")

        // These are the golden's own sentences, with the emphasis markers
        // dropped — the plain text a correct layout must produce.
        #expect(allLines.contains { $0 == "Fixture Document" })
        #expect(
            allLines.contains { $0 == "Plain paragraph with bold, italic, and struck runs." },
            "the opening paragraph did not lay out as prose")
        #expect(
            allLines.contains { $0 == "Style-bold paragraph with a NotBold-styled span inside." })
        // List markers abut their text in the reference's output too.
        #expect(allLines.contains { $0 == "1.First numbered" })
        #expect(allLines.contains { $0 == "a)Alpha sub one" })

        // Document order.
        let titleAt = try #require(allLines.firstIndex { $0.contains("Fixture Document") })
        let listsAt = try #require(allLines.firstIndex { $0 == "Lists" })
        let notesAt = try #require(allLines.firstIndex { $0.contains("Notes and special text") })
        #expect(titleAt < listsAt)
        #expect(listsAt < notesAt)
    }

    /// The back-jumped glyphs land in their line, in the right place.
    @Test func backJumpedGlyphsJoinTheirLine() throws {
        var document = try loadFixture()
        let pages = pdfPages(&document)
        let lines = pdfGroupIntoLines(pdfPageTextRuns(&document, pages[0]))
        let clefLine = try #require(
            lines.first { line in line.items.contains { $0.text.contains("\u{1D11E}") } },
            "the clef run vanished")
        let text = pdfLineText(clefLine)
        #expect(text.contains("Music"))
        let clefAt = try #require(text.range(of: "\u{1D11E}"))
        let appearsAt = try #require(text.range(of: "appears"))
        #expect(clefAt.lowerBound < appearsAt.lowerBound, "the clef landed out of order: \(text)")
    }

    /// Lines group into a plausible number of paragraphs, not one each.
    @Test func fixtureGroupsIntoParagraphs() throws {
        var document = try loadFixture()
        let pages = pdfPages(&document)
        let lines = pdfGroupIntoLines(pdfPageTextRuns(&document, pages[0]))
            .filter { !pdfLineText($0).isEmpty }
        let paragraphs = pdfGroupIntoParagraphs(lines)
        #expect(paragraphs.count > 1)
        #expect(paragraphs.count < lines.count, "every line became its own paragraph")
        print("pdf paragraphs: \(paragraphs.count) from \(lines.count) lines")
    }
}

@Suite struct PdfMarkdownTests {
    private func line(_ text: String, size: Float, y: Float, x: Float = 72) -> PdfTextLine {
        PdfTextLine(
            items: [
                PdfLayoutItem(text: text, x: x, y: y, width: 100, fontSize: size, fontName: "F")
            ], y: y)
    }

    /// The body size is the most common one, weighted by how much text is
    /// set in it — not by how many runs use it.
    @Test func bodySizeIsTheMostCommonByTextVolume() {
        let lines = [
            line("A very long paragraph of body text here", size: 10, y: 700),
            line("More body text at the same size", size: 10, y: 688),
            line("Big", size: 24, y: 730),
        ]
        #expect(pdfBodyFontSize(lines) == 10)
    }

    /// Tiers are the distinct sizes above the body, largest first, clustered.
    @Test func tiersClusterNearbySizes() {
        let lines = [
            line("Title", size: 24, y: 730),
            line("Section", size: 16, y: 700),
            // Within half a point of the tier above: the same tier.
            line("Another section", size: 16.3, y: 680),
            line("body body body body", size: 10, y: 660),
        ]
        let tiers = pdfHeadingTiers(lines, bodySize: 10)
        #expect(tiers.count == 2)
        #expect(tiers[0] == 24)
        #expect(abs(tiers[1] - 16.3) < 0.5)
    }

    /// A line with no letters cannot define a tier — a large page number
    /// would otherwise claim the top level.
    @Test func digitOnlyLinesDoNotDefineTiers() {
        let lines = [
            line("42", size: 30, y: 60),
            line("Real Heading", size: 16, y: 700),
            line("body body body", size: 10, y: 660),
        ]
        let tiers = pdfHeadingTiers(lines, bodySize: 10)
        #expect(tiers == [16])
    }

    /// Size decides the level; body-sized text is not a heading.
    @Test func levelsFollowTheTiers() {
        let tiers: [Float] = [24, 16]
        #expect(pdfHeadingLevel(fontSize: 24, bodySize: 10, tiers: tiers) == 1)
        #expect(pdfHeadingLevel(fontSize: 16, bodySize: 10, tiers: tiers) == 2)
        #expect(pdfHeadingLevel(fontSize: 10, bodySize: 10, tiers: tiers) == nil)
        // Just under a fifth larger is still body text.
        #expect(pdfHeadingLevel(fontSize: 11.9, bodySize: 10, tiers: tiers) == nil)
        // Much larger but matching no tier lands after the known tiers.
        #expect(pdfHeadingLevel(fontSize: 40, bodySize: 10, tiers: []) == 1)
    }

    /// Blocks come out as headings and paragraphs, and render as Markdown.
    @Test func blocksRenderAsMarkdown() {
        let lines = [
            line("Title", size: 20, y: 730),
            line("First body line here", size: 10, y: 700),
            line("continuing the paragraph", size: 10, y: 688),
            line("Section", size: 14, y: 650),
            line("Another paragraph of text", size: 10, y: 620),
        ]
        let markdown = pdfRenderMarkdown(pdfBuildBlocks(lines))
        #expect(markdown.hasPrefix("# Title\n\n"))
        #expect(markdown.contains("## Section"))
        #expect(markdown.contains("First body line here continuing the paragraph"))
        #expect(markdown.hasSuffix("\n"))
        #expect(!markdown.hasSuffix("\n\n"))
    }
}

@Suite struct PdfFixtureMarkdownTests {
    /// End to end: the fixture through the whole pipeline, compared against
    /// the reference's own headings.
    @Test func fixtureRendersHeadingsAndProse() throws {
        var document = try loadFixture()
        var lines: [PdfTextLine] = []
        for page in pdfPages(&document) {
            lines += pdfGroupIntoLines(pdfPageTextRuns(&document, page))
        }
        let blocks = pdfBuildBlocks(lines)
        let markdown = pdfRenderMarkdown(blocks)
        let headings = blocks.compactMap { block -> String? in
            if case .heading(let level, let text) = block {
                return "\(level):\(text)"
            }
            return nil
        }
        print("pdf markdown: \(markdown.count) chars, \(headings.count) headings")
        for heading in headings.prefix(8) { print("  H \(heading)") }

        // The golden's own heading text, at the levels it assigns.
        #expect(headings.contains("1:Fixture Document"))
        #expect(headings.contains { $0 == "2:Lists" })
        #expect(headings.contains { $0.hasSuffix(":Notes and special text") })
        // Prose survives into the body.
        #expect(markdown.contains("Plain paragraph with bold, italic, and struck runs."))
        #expect(markdown.hasSuffix("\n"))
    }
}
