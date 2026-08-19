// The result fields the Markdown cannot show.
//
// `PdfProcessResult` carries two things no other oracle exposes:
// `has_encoding_issues`, an OR across the OCR reasons and the finished
// Markdown, and `layout`, computed from the page's items, rectangles and
// lines. Both were absent from this port's result type until wave 162 —
// `pdfLayoutComplexity` had been differentially verified since wave 61 and
// had no caller, because the result had nowhere to put it.
//
// Gated on `ANYDOC_PDF_CORPUS`, reading `<name>.pdf.result`.
import Foundation
import Testing

@testable import AnyDoc

@Suite struct PdfResultFieldsProbeTests {
    @Test func resultFieldsMatchTheReference() throws {
        guard let root = ProcessInfo.processInfo.environment["ANYDOC_PDF_CORPUS"],
            !root.isEmpty
        else { return }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root) else { return }

        var mismatches: [String] = []
        var compared = 0
        var verdicts: Set<String> = []
        for name in names.filter({ $0.hasSuffix(".pdf") }).sorted() {
            let path = root + "/" + name
            guard let expected = try? String(contentsOfFile: path + ".result", encoding: .utf8),
                let data = manager.contents(atPath: path)
            else { continue }

            let result: PdfTypeResult
            do { result = try pdfConvert([UInt8](data)).detection } catch { continue }

            let ours =
                "enc \(result.hasEncodingIssues ? 1 : 0)\n"
                + "layout \(result.layout.isComplex ? 1 : 0) "
                + "\(result.layout.pagesWithTables) \(result.layout.pagesWithColumns)\n"
            compared += 1
            verdicts.insert(ours)
            if ours != expected {
                mismatches.append(
                    "\(name)\n      ours: \(ours.debugDescription)"
                        + "\n      rust: \(expected.debugDescription)")
            }
        }

        #expect(compared > 0, "no .result dumps beside the corpus — run scripts/run-probes.sh")
        // The oracle must see more than one answer, or it proves nothing —
        // the lesson of wave 152's column of zeros.
        #expect(verdicts.count > 1, "every document produced the same result fields")
        print(
            "result fields: \(compared) compared, \(mismatches.count) differ, "
                + "\(verdicts.count) distinct")
        for line in mismatches.prefix(8) { print(line) }
        #expect(mismatches.isEmpty)
    }
}
