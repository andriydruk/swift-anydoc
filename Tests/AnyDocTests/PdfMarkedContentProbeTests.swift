import Foundation
import Testing

@testable import AnyDoc

/// Differential check of marked-content tracking against the reference's own
/// extractor, driven by the content streams of the generated corpus.
///
/// The Rust side reads the whole PDF; the Swift side is fed the same content
/// stream directly, which is the only part marked-content tracking depends on.
@Suite struct PdfMarkedContentProbeTests {
    @Test func markedContentIdsMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_MCID_CORPUS"],
            !path.isEmpty
        else { return }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let names = files.filter { $0.hasSuffix(".content") }.map {
            String($0.dropLast(".content".count))
        }.sorted()
        guard !names.isEmpty else { return }

        var mismatches: [String] = []
        var compared = 0
        for name in names {
            guard
                let content = try? String(
                    contentsOfFile: path + "/\(name).content", encoding: .isoLatin1),
                let expectedText = try? String(
                    contentsOfFile: path + "/\(name).expected", encoding: .utf8)
            else { continue }
            compared += 1

            let runs = pdfExtractTextRuns(
                pdfParseContentStream(Array(content.utf8)),
                metrics: { _ in nil }
            ) { _, bytes in String(decoding: bytes, as: UTF8.self) }

            var ours = "#PAGE 1\n"
            for run in runs {
                let id = run.mcid.map(String.init) ?? "-"
                ours += "m \(id) " + String(format: "%.3f %.3f %.3f %.3f", run.x, run.y,
                    run.width, run.fontSize)
                ours += " \(run.text.replacingOccurrences(of: " ", with: "~"))\n"
            }

            if ours != expectedText {
                mismatches.append("\(name)\n    ours: \(ours)    rust: \(expectedText)")
            }
        }
        print("pdf marked-content probe: \(compared) cases compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) marked-content divergences:\n\(report)")
    }
}
