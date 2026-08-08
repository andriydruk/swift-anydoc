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

    /// With widths applied, a run's advance must land where the next run
    /// actually starts. This is the real check on the width math: if the
    /// glyph widths were wrong, the predicted end of one run would drift
    /// from the observed start of the next.
    ///
    /// Content order is *not* visual order — a writer may jump backwards to
    /// place a glyph from another font, which the fixture does twice — so
    /// only forward-advancing pairs are measured, and reordering is the
    /// layout wave's problem rather than a defect here.
    @Test func runAdvanceLandsWhereTheNextRunStarts() throws {
        var document = try loadFixture()
        let pages = pdfPages(&document)
        let runs = pdfPageTextRuns(&document, pages[0])
        var byLine: [Int: [PdfTextRun]] = [:]
        for run in runs { byLine[Int(run.y.rounded()), default: []].append(run) }

        var measured = 0
        var accurate = 0
        for (_, lineRuns) in byLine where lineRuns.count > 1 {
            for (previous, next) in zip(lineRuns, lineRuns.dropFirst()) {
                // Only pairs the writer emitted left to right are comparable.
                guard next.x > previous.x, previous.width > 0 else { continue }
                measured += 1
                // The gap past the predicted end is the writer's own
                // kerning/positioning, which is small; a wrong width would
                // show up as a large, systematic drift.
                let predictedEnd = previous.x + previous.width
                if abs(next.x - predictedEnd) < 2.0 { accurate += 1 }
            }
        }
        #expect(measured > 100, "too few adjacent pairs to judge: \(measured)")
        let ratio = Double(accurate) / Double(max(measured, 1))
        #expect(ratio > 0.9, "only \(accurate)/\(measured) advances land within 2pt")
        print("pdf advance: \(accurate)/\(measured) within 2pt")
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
