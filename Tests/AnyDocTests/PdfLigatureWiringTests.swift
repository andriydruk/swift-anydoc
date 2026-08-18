// Ligature expansion, applied to every text run rather than to `/ActualText`
// alone.
//
// `pdfExpandLigatures` was a faithful port from the start; what was missing
// was a caller. These tests pin the two halves — the function's behaviour,
// and the fact that ordinary decoded text now goes through it.
import Testing

@testable import AnyDoc

@Suite struct PdfLigatureWiringTests {
    @Test func ligaturesBecomeTheirComponentLetters() {
        #expect(pdfExpandLigatures("\u{FB01}rst") == "first")
        #expect(pdfExpandLigatures("\u{FB00}\u{FB01}\u{FB02}") == "fffifl")
        #expect(pdfExpandLigatures("\u{FB03}x\u{FB04}") == "ffixffl")
        #expect(pdfExpandLigatures("\u{FB05}\u{FB06}") == "stst")
    }

    @Test func controlCharactersAreStrippedAndTabsKept() {
        #expect(pdfExpandLigatures("a\u{0000}b") == "ab")
        #expect(pdfExpandLigatures("a\u{0001}\u{001F}b") == "ab")
        #expect(pdfExpandLigatures("a\tb\nc\rd") == "a\tb\nc\rd")
    }

    @Test func invisibleFormattingCharactersAreRemoved() {
        #expect(pdfExpandLigatures("con\u{00AD}tent") == "content")
        #expect(pdfExpandLigatures("a\u{200B}b\u{FEFF}c") == "abc")
        #expect(pdfExpandLigatures("a\u{200C}b\u{200D}c\u{2060}d") == "abcd")
    }

    /// Typographic spaces fold to ASCII so the joining logic sees a word
    /// boundary — but a non-breaking space is left alone, because the
    /// coordinate-based spacing depends on telling the two apart.
    @Test func typographicSpacesFoldButNonBreakingSpaceSurvives() {
        #expect(pdfExpandLigatures("a\u{2003}b") == "a b")
        #expect(pdfExpandLigatures("x\u{2009}y") == "x y")
        #expect(pdfExpandLigatures("a\u{2000}b\u{200A}c") == "a b c")
        #expect(pdfExpandLigatures("a\u{00A0}b") == "a\u{00A0}b")
    }

    /// End to end: a `/Differences` array naming `/fi` must reach the
    /// Markdown as two letters. Before the expansion was wired this produced
    /// `\u{FB01}` — which reads identically and is not the same text.
    @Test func aLigatureGlyphNameReachesTheMarkdownAsLetters() throws {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]"
                + " /Resources << /Font << /F1 4 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /TrueType /BaseFont /Helvetica"
                + " /FirstChar 0 /LastChar 255 /Encoding 5 0 R >>",
            "<< /Type /Encoding /Differences [65 /fi] >>",
        ]
        let content = "BT /F1 24 Tf 72 700 Td <7841> Tj ET\n"
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")

        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        out += "startxref\n\(xref)\n%%EOF\n"

        let markdown = try pdfMarkdown(Array(out.utf8))
        #expect(markdown.contains("xfi"))
        #expect(!markdown.contains("\u{FB01}"))
    }
}
