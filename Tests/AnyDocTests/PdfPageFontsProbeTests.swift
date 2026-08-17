import Foundation
import Testing

@testable import AnyDoc

/// The usage-based font verdicts, against the reference's own answers.
///
/// Gated on `ANYDOC_PAGEFONTS_CORPUS`, which holds PDFs alongside
/// `<name>.pdf.pagefonts` dumps from `graphicsprobe --pagefonts` — a probe
/// added to the vendored oracle in wave 119, because the existing
/// `--detector` mode is synthetic and never touches a document.
///
/// Four corpus documents exist for this and nothing else: a bare Identity-H
/// subset, the same font with Unicode-looking `/W`, a Type 3, and an
/// undecodable font beside a readable one. Every other document in the
/// corpus answers `1 0 0 1`, so without them this suite would pass on a port
/// that always said "one decodable font".
@Suite struct PdfPageFontsProbeTests {
    @Test func fontVerdictsMatchTheReference() throws {
        guard let root = ProcessInfo.processInfo.environment["ANYDOC_PAGEFONTS_CORPUS"],
            !root.isEmpty,
            let top = try? FileManager.default.contentsOfDirectory(atPath: root)
        else { return }
        // `detector/` holds documents the end-to-end pipeline cannot match
        // yet — image-backed pages, which the reference's own detector calls
        // scanned and renders as nothing. They are the only documents that
        // exercise the image fields, so this probe reads them and the
        // pipeline suite does not.
        let nested =
            (try? FileManager.default.contentsOfDirectory(atPath: root + "/detector"))?
            .map { "detector/" + $0 } ?? []
        let names = top + nested

        var compared = 0
        var mismatches: [String] = []
        var verdictsSeen: Set<String> = []

        for name in names.sorted() where name.hasSuffix(".pdf") {
            let path = root + "/" + name
            guard
                let expected = try? String(
                    contentsOfFile: path + ".pagefonts", encoding: .utf8),
                let data = FileManager.default.contents(atPath: path)
            else { continue }

            var document: PdfDocument
            do { document = try PdfDocument(bytes: [UInt8](data)) } catch { continue }

            var ours = ""
            for page in pdfDocumentPages(&document) {
                let verdicts = pdfPageFontVerdicts(&document, page)
                ours += "p \(verdicts.usedFontCount)"
                    + " \(verdicts.hasIdentityHNoToUnicode ? 1 : 0)"
                    + " \(verdicts.hasOnlyType3Fonts ? 1 : 0)"
                    + " \(verdicts.hasDecodableTextFonts ? 1 : 0)\n"
            }
            compared += 1
            verdictsSeen.formUnion(expected.split(separator: "\n").map(String.init))
            if ours != expected {
                mismatches.append(
                    "\(name)\n      ours: \(ours.debugDescription)"
                        + "\n      rust: \(expected.debugDescription)")
            }
        }

        print("pagefonts: \(compared) compared, \(mismatches.count) differ, "
            + "\(verdictsSeen.count) distinct verdicts")
        let report: Comment = "\(mismatches.joined(separator: "\n   "))"
        #expect(mismatches.isEmpty, report)

        // The gate-distribution check PLAN.md §2 asks for: a corpus that only
        // ever produced one verdict would pass this suite while testing none
        // of the branches.
        if compared > 0 {
            let distribution: Comment = "only saw \(verdictsSeen.sorted())"
            #expect(verdictsSeen.count >= 4, distribution)
        }
    }
}
