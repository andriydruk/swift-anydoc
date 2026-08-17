import Foundation
import Testing

@testable import AnyDoc

/// The document-level classification, against the reference's own verdicts.
///
/// Gated on `ANYDOC_DETECTDOC_CORPUS`, with `<name>.pdf.detectdoc` dumps
/// from `graphicsprobe --detectdoc` — the third oracle probe this port has
/// added, after `--pagefonts` (wave 119) and `--pageanalysis` (wave 121),
/// all for the same reason: the built-in `--detector` mode feeds constructed
/// values to `page_ocr_reasons` and never opens a document.
///
/// The verdict distribution is asserted, not just agreement. A corpus where
/// every document classified the same way would pass this suite while
/// testing one branch of six.
@Suite struct PdfDocumentDetectorProbeTests {
    private func render(_ result: PdfTypeResult) -> String {
        var out = "t \(result.pdfType.rawValue) \(result.pageCount) \(result.pagesSampled)"
        out += " \(result.pagesWithText) "
        out += String(format: "%.3f", result.confidence)
        out += " \(result.ocrRecommended ? 1 : 0)\n"
        for page in result.pagesNeedingOcr {
            out += "n \(page) \((result.ocrReasonsByPage[page] ?? []).joined(separator: ","))\n"
        }
        if let title = result.title { out += "title \(title)\n" }
        return out
    }

    @Test func documentClassificationMatchesTheReference() throws {
        guard let root = ProcessInfo.processInfo.environment["ANYDOC_DETECTDOC_CORPUS"],
            !root.isEmpty,
            let names = try? FileManager.default.contentsOfDirectory(atPath: root)
        else { return }

        var compared = 0
        var mismatches: [String] = []
        var kinds: Set<String> = []
        var reasons: Set<String> = []

        for name in names.sorted() where name.hasSuffix(".pdf") {
            let path = root + "/" + name
            guard let expected = try? String(contentsOfFile: path + ".detectdoc", encoding: .utf8),
                let data = FileManager.default.contents(atPath: path)
            else { continue }

            var document: PdfDocument
            do { document = try PdfDocument(bytes: [UInt8](data)) } catch { continue }

            let ours = render(pdfDetectDocumentType(&document))
            compared += 1
            for line in expected.split(separator: "\n") {
                let fields = line.split(separator: " ").map(String.init)
                if fields.first == "t", fields.count > 1 { kinds.insert(fields[1]) }
                if fields.first == "n", fields.count > 2 { reasons.formUnion(fields[2].split(separator: ",").map(String.init)) }
            }
            if ours != expected {
                mismatches.append(
                    "\(name)\n      ours: \(ours.debugDescription)"
                        + "\n      rust: \(expected.debugDescription)")
            }
        }

        print("detectdoc: \(compared) compared, \(mismatches.count) differ, "
            + "kinds=\(kinds.sorted()) reasons=\(reasons.sorted())")
        let report: Comment = "\(mismatches.prefix(8).joined(separator: "\n   "))"
        #expect(mismatches.isEmpty, report)
        if compared > 0 {
            let spread: Comment = "only saw \(kinds.sorted())"
            #expect(kinds.count >= 2, spread)
        }
    }
}
