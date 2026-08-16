import Testing

@testable import AnyDoc

/// The per-page pass order, pinned.
///
/// Waves 100 and 101 both lost time to a pass that was ported, tested and
/// simply not connected — or connected at the wrong level. These tests
/// assert the *effects* of the order rather than the order itself, so they
/// fail if a pass is dropped from `pdfMarkdown` however the code is
/// arranged.
@Suite struct PdfPipelineOrderTests {
    /// A PDF whose content stream draws the given operators, built the way
    /// `scripts/gen-pdf-corpus.py` builds its files.
    private func document(_ content: String) -> [UInt8] {
        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objects.append(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                + "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>")
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        // Explicit widths, as the corpus generator's font has: every glyph
        // 500/1000 em, so the advance is 6pt at 12pt and the gaps below mean
        // what the reference's thresholds expect. Without them the advance
        // falls back to a default and every threshold test measures a
        // different gap.
        let widths = Array(repeating: "500", count: 95).joined(separator: " ")
        objects.append(
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica "
                + "/FirstChar 32 /LastChar 126 /Widths [\(widths)] >>")

        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        out += "startxref\n\(xref)\n%%EOF\n"
        return Array(out.utf8)
    }

    @Test func fragmentsAreMergedIntoWords() throws {
        // A PDF does not draw words: this is `Hello world` as four `Tj` at
        // explicit positions. Without `pdfMergeTextItems` in the pipeline it
        // comes out spaced apart.
        let markdown = try pdfMarkdown(
            document(
                "BT /F1 12 Tf 100 700 Td (Hel) Tj 18 0 Td (lo) Tj 12 0 Td (wor) Tj"
                    + " 18 0 Td (ld) Tj ET"))
        #expect(markdown.contains("Helloworld"))
    }

    @Test func aLetterspacedRunIsPutBackTogether() {
        // `T R A C K` drawn a glyph at a time is one word. This needs the
        // merge passes *and* the letter-spacing measurement that follows
        // them — the measurement has to see merged words, not fragments.
        let markdown = try? pdfMarkdown(
            document(
                "BT /F1 12 Tf 100 670 Td (T) Tj 9 0 Td (R) Tj 9 0 Td (A) Tj"
                    + " 9 0 Td (C) Tj 9 0 Td (K) Tj ET"))
        #expect(markdown?.contains("TRACK") == true)
        #expect(markdown?.contains("T R A C K") == false)
    }

    @Test func aMixedCasePairKeepsItsSpace() {
        // The threshold is tighter for a mixed-case pair (0.08em) than for a
        // lowercase one (0.13em), so the same 1.2pt gap splits `AB cd` and
        // joins `abcd`.
        let mixed = try? pdfMarkdown(
            document("BT /F1 12 Tf 100 700 Td (AB) Tj 13.2 0 Td (cd) Tj ET"))
        #expect(mixed?.contains("AB cd") == true)
        let lower = try? pdfMarkdown(
            document("BT /F1 12 Tf 100 700 Td (ab) Tj 13.2 0 Td (cd) Tj ET"))
        #expect(lower?.contains("abcd") == true)
    }

    @Test func aSubscriptIsFoldedIntoItsWord() {
        // `H`, a raised `2` at 6pt, then `O` — one token, not three.
        let markdown = try? pdfMarkdown(
            document(
                "BT /F1 12 Tf 100 640 Td (H) Tj ET\nBT /F1 6 Tf 106 638 Td (2) Tj ET\n"
                    + "BT /F1 12 Tf 109 640 Td (O) Tj ET"))
        #expect(markdown?.contains("H₂O") == true)
    }
}
