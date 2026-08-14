import Foundation
import Testing

@testable import AnyDoc

/// Differential check of `clean_markdown` — the composition of the cleanup
/// helpers — against `markdown/postprocess.rs`.
///
/// The eight helpers are already covered individually by
/// `PdfPostprocessProbeTests` in `PdfClassifyProbeTests.swift`, from wave 5.
/// This adds two things that probe does not have: the **composed** pass in
/// both profiles, whose ordering, newline collapsing and final trim are its
/// own behaviour; and a second, differently-shaped corpus over the helpers,
/// since two corpora reach branches one does not.
@Suite struct PdfCleanMarkdownProbeTests {
    @Test func markdownCleanupMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/postprocess-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/postprocess-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let expected = expectedText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }.map(String.init)
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var verdicts: [String: Int] = [:]
        for (index, line) in cases.enumerated() where index < expected.count {
            guard let ours = answer(for: line) else { continue }
            verdicts[String(ours.prefix(2)), default: 0] += 1
            if ours != expected[index] {
                mismatches.append("\(line)\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        let shape = verdicts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
        print("pdf postprocess probe: \(cases.count) cases compared — \(shape)")
        let report = mismatches.prefix(6).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) postprocess divergences:\n\(report)")
    }

    private func answer(for line: String) -> String? {
        let split = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let tag = split.first.map(String.init) else { return nil }
        let text = decode(split.count > 1 ? String(split[1]) : "")

        switch tag {
        case "SP": return "sp " + encode(pdfCollapseConsecutiveSpaces(text))
        case "BR": return "br " + encode(pdfRemoveSpacesBeforeClosingBrackets(text))
        case "PU": return "pu " + encode(pdfRemoveSpacesBeforeSentencePunctuation(text))
        case "DL": return "dl " + encode(pdfCollapseDotLeaders(text))
        case "HY": return "hy " + encode(pdfFixHyphenation(text))
        case "PN": return "pn " + encode(pdfRemovePageNumbers(text))
        case "IP": return "ip " + (pdfIsPageNumberLine(text.rustTrim()) ? "1" : "0")
        case "UR": return "ur " + encode(pdfFormatUrls(text))
        case "CM":
            return "cm " + encode(pdfCleanMarkdown(text, options: PdfCleanupOptions()))
        case "CC":
            var options = PdfCleanupOptions()
            options.collapseDotLeaders = true
            return "cc " + encode(pdfCleanMarkdown(text, options: options))
        default: return nil
        }
    }

    private func decode(_ raw: String) -> String {
        raw.replacingOccurrences(of: "~", with: " ")
            .replacingOccurrences(of: "^", with: "\n")
    }

    private func encode(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "~")
            .replacingOccurrences(of: "\n", with: "^")
    }
}
