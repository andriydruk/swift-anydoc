// Adversarial PDF corpus, compared against lopdf.
//
// The committed fixture is one narrow shape; whole branches of the reader
// (cross-reference streams, object streams, CID fonts, the other filters,
// the PNG predictors, incremental updates) are written but never exercised
// by it. `scripts/gen-pdf-corpus.py` builds files that do exercise them.
//
// The corpus is not committed — it is generated. Point ANYDOC_PDF_CORPUS at
// the output directory to run this suite; without it the tests skip, so a
// checkout without the corpus still passes.
//
//   scripts/gen-pdf-corpus.py /tmp/pdfcorpus
//   for f in /tmp/pdfcorpus/*.pdf; do
//     scratchpad/pdfprobe/target/release/pdfprobe "$f" > "$f.expected" 2>/dev/null
//   done
//   ANYDOC_PDF_CORPUS=/tmp/pdfcorpus swift test --filter PdfCorpus
import Foundation
import Testing

@testable import AnyDoc

private var corpusDirectory: URL? {
    guard let path = ProcessInfo.processInfo.environment["ANYDOC_PDF_CORPUS"],
        !path.isEmpty
    else { return nil }
    return URL(fileURLWithPath: path)
}

/// lopdf decompresses an object stream *in place* while loading it, so by
/// the time the probe reports a stream's raw length it may already be the
/// decoded one. That is an artifact of the oracle mutating what it read, not
/// a parsing difference — the decoded lengths still have to agree — so a
/// stream the oracle reports as `raw == decoded` is compared on its decoded
/// length alone.
func normalizeOracleArtifacts(_ dump: String, against expected: String) -> String {
    var expectedRawEqualsDecoded: Set<String> = []
    for line in expected.split(separator: "\n") {
        let fields = line.split(separator: " ")
        guard fields.count >= 5, fields[2] == "stream",
            let raw = fields.first(where: { $0.hasPrefix("raw=") }),
            let decoded = fields.first(where: { $0.hasPrefix("decoded=") }),
            raw.dropFirst(4) == decoded.dropFirst(8)
        else { continue }
        expectedRawEqualsDecoded.insert(String(fields[0]))
    }
    guard !expectedRawEqualsDecoded.isEmpty else { return dump }
    return dump.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        let fields = line.split(separator: " ")
        guard fields.count >= 5, fields[2] == "stream",
            expectedRawEqualsDecoded.contains(String(fields[0])),
            let decoded = fields.first(where: { $0.hasPrefix("decoded=") })
        else { return String(line) }
        return fields.map { field -> String in
            field.hasPrefix("raw=") ? "raw=" + decoded.dropFirst(8) : String(field)
        }.joined(separator: " ")
    }.joined(separator: "\n")
}

@Suite struct PdfCorpusTests {
    /// Every file the oracle accepts must yield the same object graph here,
    /// and every file it rejects must not silently produce one.
    @Test func objectGraphsMatchTheOracle() throws {
        guard let directory = corpusDirectory else { return }
        let files = walkFiles(directory).filter { $0.pathExtension == "pdf" }.sorted {
            $0.path < $1.path
        }
        #expect(!files.isEmpty, "ANYDOC_PDF_CORPUS is set but holds no PDFs")

        var compared = 0
        var agreedRejections = 0
        for file in files {
            let name = file.lastPathComponent
            let expectedPath = file.appendingPathExtension("expected")
            let expected = try? String(contentsOf: expectedPath, encoding: .utf8)
            let bytes = [UInt8](try Data(contentsOf: file))

            guard let expected, expected.hasPrefix("#OBJECTS") else {
                // The oracle rejected it, so the reader must too — or at
                // least must not invent a document.
                if let document = try? PdfDocument(bytes: bytes) {
                    var copy = document
                    let resolved = copy.xref.entries.keys.filter {
                        !copy.object(PdfObjectId(number: $0, generation: 0)).isNull
                    }
                    let detail =
                        "\(name): the oracle rejects this but the reader resolved "
                        + "\(resolved.count) objects"
                    #expect(resolved.isEmpty, "\(detail)")
                } else {
                    agreedRejections += 1
                }
                continue
            }

            var document = try PdfDocument(bytes: bytes)
            var dump = normalizeOracleArtifacts(pdfObjectDump(&document), against: expected)
            // lopdf *consumes* the `/Encrypt` dictionary when it decrypts a
            // document and drops it from the object table; this reader keeps
            // it, since it is a reader and removing objects would be
            // surprising. That is a difference in what the two model, not in
            // what they parsed — the stream lengths either side of it agree
            // byte for byte — so the object is dropped from this dump and
            // the count corrected before comparing.
            if document.encryption != nil {
                // Identified by *number*, from the trailer's own reference —
                // matching on its keys broke the moment a document used a
                // crypt filter and carried `/CF`, `/StmF` and `/StrF` too.
                let encryptNumber = document.trailer["Encrypt"]?.asReference?.number
                let lines = dump.split(separator: "\n").map(String.init)
                let kept = lines.filter { line in
                    guard let number = encryptNumber else { return true }
                    return !line.hasPrefix("\(number) ")
                }
                if kept.count < lines.count {
                    var rebuilt = kept
                    if let first = rebuilt.first, first.hasPrefix("#OBJECTS ") {
                        rebuilt[0] = "#OBJECTS \(rebuilt.count - 1)"
                    }
                    dump = rebuilt.joined(separator: "\n")
                }
            }
            let expectedGraph = expected.split(separator: "\n", omittingEmptySubsequences: false)
                .prefix { !$0.hasPrefix("#PAGES") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // On a mismatch the useful thing is the diverging lines, not two
            // whole graphs side by side.
            var diff: [String] = []
            let ours = dump.split(separator: "\n").map(String.init)
            let theirs = expectedGraph.split(separator: "\n").map(String.init)
            for i in 0..<max(ours.count, theirs.count) {
                let a = i < ours.count ? ours[i] : "<none>"
                let b = i < theirs.count ? theirs[i] : "<none>"
                if a != b { diff.append("  ours:  \(a)\n  lopdf: \(b)") }
            }
            #expect(
                dump == expectedGraph,
                "\(name): object graph diverges from lopdf\n\(diff.joined(separator: "\n"))")
            compared += 1
        }
        print("pdf corpus: \(compared) graphs compared, \(agreedRejections) rejections agreed")
    }

    /// Whatever the file, the reader must not crash or hang, and must reach
    /// the end of the pipeline.
    @Test func everyFileSurvivesTheWholePipeline() throws {
        guard let directory = corpusDirectory else { return }
        var rendered = 0
        for file in walkFiles(directory).filter({ $0.pathExtension == "pdf" }).sorted(by: {
            $0.path < $1.path
        }) {
            let bytes = [UInt8](try Data(contentsOf: file))
            guard var document = try? PdfDocument(bytes: bytes) else { continue }
            var lines: [PdfTextLine] = []
            for page in pdfPages(&document) {
                let styles = pdfPageFontStyles(&document, page)
                let graphics = pdfExtractGraphics(pdfPageOperations(&document, page))
                for var line in pdfGroupIntoLines(pdfPageTextRuns(&document, page)) {
                    pdfApplyFontStyles(&line.items, styles)
                    pdfMarkUnderlines(
                        &line.items, rectangles: pdfUnderlineInk(graphics),
                        lines: graphics.lines)
                    lines.append(line)
                }
            }
            let markdown = pdfRenderMarkdown(pdfBuildBlocks(lines, formatted: true))
            if !markdown.isEmpty {
                #expect(markdown.hasSuffix("\n"), "\(file.lastPathComponent): no trailing newline")
                rendered += 1
            }
        }
        print("pdf corpus: \(rendered) files rendered to markdown")
    }
}

/// Links and form fields, read from the corpus's `annotations.pdf`.
///
/// These live in dictionaries the content stream never mentions, so nothing
/// else in the suite reaches them: a hyperlink is a rectangle plus an action,
/// and a field value hangs off the trailer.
@Suite struct PdfAnnotationTests {
    private func annotatedDocument() throws -> PdfDocument? {
        guard let directory = corpusDirectory else { return nil }
        let path = directory.appendingPathComponent("annotations.pdf")
        return try PdfDocument(bytes: [UInt8](Data(contentsOf: path)))
    }

    @Test func linkAnnotationsCarryTheirUriAndRectangle() throws {
        guard var document = try annotatedDocument() else { return }
        let pages = pdfPages(&document)
        let links = pdfPageLinks(&document, page: try #require(pages.first), pageNumber: 1)

        // Four annotations on the page; the internal /Dest jump has no URI so
        // it is dropped, and the /Text annotation is not a link.
        #expect(links.count == 2, "got \(links.map(\.text))")
        let first = try #require(links.first)
        #expect(first.text == "https://example.test/a")
        #expect(first.kind == .link("https://example.test/a"))
        #expect(first.x == 100)
        #expect(first.y == 700)
        #expect(first.width == 200)
        #expect(first.height == 20)

        // A reversed rectangle is passed through as given, negative extents
        // and all — the reference does not normalise a link's rect.
        let reversed = try #require(links.last)
        #expect(reversed.width == -200)
        #expect(reversed.height == -20)
    }

    @Test func formFieldsAreQualifiedAndFiltered() throws {
        guard var document = try annotatedDocument() else { return }
        let pages = pdfPages(&document)
        #expect(pdfPageObjectIds(&document).count == pages.count)
        let fields = pdfFormFields(&document, pageNumbers: pdfPageNumbers(&document))
        let texts = fields.map(\.text)

        // The text field inherits its group's name; the checkbox reports Yes;
        // the unchecked box and the signature field are dropped.
        #expect(texts.contains("address.city: Lisbon"), "got \(texts)")
        #expect(texts.contains("agree: Yes"), "got \(texts)")
        #expect(!texts.contains { $0.hasPrefix("spam") })
        #expect(!texts.contains { $0.hasPrefix("sig") })

        // A field's rectangle *is* normalised, unlike a link's.
        let city = try #require(fields.first { $0.text.hasSuffix("Lisbon") })
        #expect(city.x == 100)
        #expect(city.y == 600)
        #expect(city.width == 200)
        #expect(city.height == 20)
        #expect(city.page == 1)
    }
}
