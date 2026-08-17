import Foundation
import Testing

@testable import AnyDoc

/// The whole of `PdfPageAnalysis`, against the reference's own answers.
///
/// Gated on `ANYDOC_PAGEANALYSIS_CORPUS`, with `<name>.pdf.pageanalysis`
/// dumps from `graphicsprobe --pageanalysis` — a probe added to the vendored
/// oracle in wave 121 for the same reason as `--pagefonts` in wave 119: the
/// built-in `--detector` mode feeds constructed values to `page_ocr_reasons`
/// and never touches a document.
///
/// Thirteen fields per page, so this is a far stricter check than the four
/// the font probe compares — a miscounted path operator or a missed nested
/// XObject shows up here and nowhere else.
@Suite struct PdfPageAnalysisProbeTests {
    @Test func pageAnalysisMatchesTheReference() throws {
        guard let root = ProcessInfo.processInfo.environment["ANYDOC_PAGEANALYSIS_CORPUS"],
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
        // Which fields ever varied across the corpus. A field that is
        // constant everywhere is untested however many documents agree.
        var varying: Set<Int> = []
        var firstRow: [String]?

        for name in names.sorted() where name.hasSuffix(".pdf") {
            let path = root + "/" + name
            guard
                let expected = try? String(
                    contentsOfFile: path + ".pageanalysis", encoding: .utf8),
                let data = FileManager.default.contents(atPath: path)
            else { continue }

            var document: PdfDocument
            do { document = try PdfDocument(bytes: [UInt8](data)) } catch { continue }

            var ours = ""
            for page in pdfDocumentPages(&document) {
                let a = pdfAnalyzePageContent(&document, page)
                ours += "a \(a.textOperatorCount) \(a.hasImages ? 1 : 0)"
                    + " \(a.hasTemplateImage ? 1 : 0) \(a.uniqueTextCharacters)"
                    + " \(a.hasVectorText ? 1 : 0) \(a.hasIdentityHNoToUnicode ? 1 : 0)"
                    + " \(a.hasOnlyType3Fonts ? 1 : 0) \(a.totalImageArea)"
                    + " \(a.imageCount) \(a.uniqueAlphanumericCharacters)"
                    + " \(a.pathOperatorCount) \(a.fontChangeCount)"
                    + " \(a.hasDecodableTextFonts ? 1 : 0)\n"
            }
            compared += 1

            for line in expected.split(separator: "\n") {
                let fields = line.split(separator: " ").map(String.init)
                if let first = firstRow {
                    for index in 0..<min(first.count, fields.count) where first[index] != fields[index] {
                        varying.insert(index)
                    }
                } else {
                    firstRow = fields
                }
            }

            if ours != expected {
                mismatches.append(
                    "\(name)\n      ours: \(ours.debugDescription)"
                        + "\n      rust: \(expected.debugDescription)")
            }
        }

        print("pageanalysis: \(compared) compared, \(mismatches.count) differ, "
            + "\(varying.count)/13 fields exercised")
        let report: Comment = "\(mismatches.prefix(6).joined(separator: "\n   "))"
        #expect(mismatches.isEmpty, report)
    }
}
