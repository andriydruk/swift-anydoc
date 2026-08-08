// The cross-reference layer, checked against `lopdf` itself.
//
// `Tests/Golden/pdf__text.pdf.objects.golden` is the object graph as lopdf
// reports it — object ids, their types, their dictionary keys, and the raw
// and decoded byte counts of every stream. The Swift reader has to
// reproduce it exactly, which pins the xref table, the object parser and
// the filter chain in one comparison.
//
// Regenerate the golden with `scratchpad/pdfprobe` (a small Rust program
// built against lopdf 0.41.0) if the reference is ever re-pinned.
import Foundation
import Testing

@testable import AnyDoc

/// The object graph in the oracle's format.
func pdfObjectDump(_ document: inout PdfDocument) -> String {
    var lines: [String] = []
    let ids = document.xref.entries.keys.sorted()
    var described: [(UInt32, UInt16, String)] = []
    for number in ids {
        let id = PdfObjectId(number: number, generation: 0)
        let object = document.object(id)
        // lopdf omits entries it could not read at all.
        if object.isNull, document.xref.entries[number] == nil { continue }
        if object.isNull { continue }
        var line = "\(number) 0 \(pdfKindName(object))"
        if let stream = object.asStream {
            // The raw length is the resolved one: a stream whose /Length is
            // an indirect reference has no content until it is looked up.
            let raw = document.rawStream(stream)?.content.count ?? 0
            let decoded = document.decodedStream(stream)
            let decodedCount = decoded.map { String($0.count) } ?? "\(UInt64.max)"
            line += " raw=\(raw) decoded=\(decodedCount)"
        }
        // The oracle prints keys only for dictionary objects: lopdf's
        // `as_dict()` does not match a stream, so neither does this.
        if case .dictionary(let dict) = object {
            let keys = dict.keys.map { String(decoding: $0, as: UTF8.self) }.sorted()
            line += " keys=[\(keys.joined(separator: ","))]"
        }
        described.append((number, 0, line))
    }
    lines.append("#OBJECTS \(described.count)")
    lines.append(contentsOf: described.map(\.2))
    return lines.joined(separator: "\n")
}

private func pdfKindName(_ object: PdfObject) -> String {
    switch object {
    case .null: return "null"
    case .boolean: return "bool"
    case .integer: return "int"
    case .real: return "real"
    case .name: return "name"
    case .string: return "string"
    case .array: return "array"
    case .dictionary: return "dict"
    case .stream: return "stream"
    case .reference: return "ref"
    }
}

private func loadFixture() throws -> PdfDocument {
    let path = fixtureRoot.appendingPathComponent("pdf/text.pdf").path
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    return try PdfDocument(bytes: bytes)
}

@Suite struct PdfDocumentTests {
    /// The whole object graph, against what lopdf reports for the same file.
    @Test func objectGraphMatchesTheReference() throws {
        var document = try loadFixture()
        let dump = pdfObjectDump(&document)
        let goldenPath = goldenRoot.appendingPathComponent("pdf__text.pdf.objects.golden")
        let golden = try String(contentsOf: goldenPath, encoding: .utf8)
        let expected = golden.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.hasPrefix("#PAGES") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if dump != expected {
            // Write the actual graph next to the golden so the divergence can
            // be diffed rather than squinted at in an assertion message.
            let actual = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pdf-objects-actual.txt")
            try? dump.write(to: actual, atomically: true, encoding: .utf8)
            print("object graph mismatch; actual written to \(actual.path)")
        }
        #expect(dump == expected, "the object graph diverges from lopdf's")
    }

    /// The trailer and catalog resolve, and the page tree is reachable.
    @Test func trailerAndCatalogResolve() throws {
        var document = try loadFixture()
        #expect(document.trailer["Size"]?.asInteger == 195)
        // The macro captures its argument immutably, so each lookup runs
        // first and only its result is asserted on.
        let catalogValue = document.catalog
        let catalog = try #require(catalogValue, "no document catalog")
        #expect(catalog["Type"]?.asName == Array("Catalog".utf8))
        let pagesValue = document.value(catalog, "Pages")?.asDictionary
        let pages = try #require(pagesValue)
        #expect(pages["Type"]?.asName == Array("Pages".utf8))
        // The fixture has two pages, as the oracle reports.
        let count = document.value(pages, "Count")?.asInteger
        #expect(count == 2)
        let kidsValue = document.value(pages, "Kids")?.asArray
        let kids = try #require(kidsValue)
        #expect(kids.count == 2)
        #expect(kids[0].asReference == PdfObjectId(number: 1, generation: 0))
        #expect(kids[1].asReference == PdfObjectId(number: 121, generation: 0))
    }

    /// Every cross-reference entry must resolve to a real object: a stale
    /// offset would silently yield null and lose content.
    @Test func everyXrefEntryResolves() throws {
        var document = try loadFixture()
        var resolved = 0
        for number in document.xref.entries.keys.sorted() {
            let object = document.object(PdfObjectId(number: number, generation: 0))
            #expect(!object.isNull, "object \(number) did not resolve")
            if !object.isNull { resolved += 1 }
        }
        #expect(resolved == 194)
        print("pdf xref: \(resolved) objects resolved")
    }

    /// Every stream in the fixture decodes; lopdf decodes all 22 of them.
    @Test func everyStreamDecodes() throws {
        var document = try loadFixture()
        var streams = 0
        var bytesOut = 0
        for number in document.xref.entries.keys.sorted() {
            guard let stream = document.object(PdfObjectId(number: number, generation: 0)).asStream
            else { continue }
            streams += 1
            let decodedValue = document.decodedStream(stream)
            let decoded = try #require(decodedValue, "stream \(number) did not decode")
            bytesOut += decoded.count
        }
        #expect(streams == 22)
        print("pdf streams: \(streams) decoded, \(bytesOut) bytes")
    }

    /// The content stream of page 1 must decode to real operators — the
    /// first thing the next wave will consume.
    @Test func pageContentDecodesToOperators() throws {
        var document = try loadFixture()
        let catalogValue = document.catalog
        let catalog = try #require(catalogValue)
        let pagesValue = document.value(catalog, "Pages")?.asDictionary
        let pages = try #require(pagesValue)
        let kidsValue = document.value(pages, "Kids")?.asArray
        let kids = try #require(kidsValue)
        let pageValue = document.resolve(kids[0]).asDictionary
        let page = try #require(pageValue)
        let contentsValue = document.value(page, "Contents")?.asStream
        let contents = try #require(contentsValue)
        let dataValue = document.decodedStream(contents)
        let data = try #require(dataValue)
        let text = String(decoding: data, as: UTF8.self)
        // BT/ET bracket a text object; Tf selects a font; TJ shows glyphs.
        #expect(text.contains("BT"))
        #expect(text.contains("ET"))
        #expect(text.contains("Tf"))
        #expect(data.count == 10442, "page 1 content length disagrees with the reference")
    }
}

@Suite struct PdfFilterTests {
    /// ASCII85 (§7.4.3), including `z` for four zero bytes and the partial
    /// final group.
    @Test func ascii85Decodes() {
        #expect(ascii85Decode(Array("87cURD]i,\"Ebo80~>".utf8)) == Array("Hello World!".utf8))
        #expect(ascii85Decode(Array("z~>".utf8)) == [0, 0, 0, 0])
        // Whitespace is ignored anywhere in the body.
        #expect(ascii85Decode(Array("87cU\nRD]i,\"Ebo80~>".utf8)) == Array("Hello World!".utf8))
        // A missing EOD marker is tolerated with a warning.
        #expect(ascii85Decode(Array("87cURD]i,\"Ebo80".utf8)) == Array("Hello World!".utf8))
        // `z` inside a group is malformed.
        #expect(ascii85Decode(Array("87z~>".utf8)) == nil)
    }

    /// A stream with no `/Filter` is stored as-is.
    @Test func unfilteredStreamsPassThrough() {
        var dict = PdfDictionary()
        dict["Length"] = .integer(3)
        let stream = PdfStream(dict: dict, content: [1, 2, 3])
        guard case .decoded(let out) = pdfDecodeStream(stream, maxOutput: 1024) else {
            Issue.record("expected the content back unchanged")
            return
        }
        #expect(out == [1, 2, 3])
    }

    /// Filters the reference does not implement are reported as such rather
    /// than decoded differently from it.
    @Test func unimplementedFiltersAreReported() {
        var dict = PdfDictionary()
        dict["Filter"] = .name(Array("ASCIIHexDecode".utf8))
        let stream = PdfStream(dict: dict, content: Array("48656C6C6F>".utf8))
        guard case .unsupported(let name) = pdfDecodeStream(stream, maxOutput: 1024) else {
            Issue.record("ASCIIHexDecode should report as unsupported, as it does upstream")
            return
        }
        #expect(name == "ASCIIHexDecode")
    }

    /// The PNG `Up` predictor adds the row above; this is the one xref
    /// streams overwhelmingly use.
    @Test func pngUpPredictorReverses() {
        // Two rows of three bytes, each prefixed by its filter type.
        let raw: [UInt8] = [2, 1, 2, 3, 2, 10, 20, 30]
        let out = pngDecodeFrame(raw, bytesPerPixel: 1, pixelsPerRow: 3)
        #expect(out == [1, 2, 3, 11, 22, 33])
    }

    /// A truncated final row is an error rather than a short read.
    @Test func truncatedPredictorRowsFail() {
        #expect(pngDecodeFrame([2, 1, 2], bytesPerPixel: 1, pixelsPerRow: 3) == nil)
        // An unknown filter type is likewise rejected.
        #expect(pngDecodeFrame([9, 1, 2, 3], bytesPerPixel: 1, pixelsPerRow: 3) == nil)
    }
}
