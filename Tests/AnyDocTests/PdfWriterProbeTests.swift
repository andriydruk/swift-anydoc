import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the whole line-to-Markdown conversion against
/// `to_markdown_from_lines_with_tables_and_images`.
///
/// This is the first probe in the project to compare *finished Markdown* —
/// the analysis prologue and the writer together, against the reference
/// actually running. It supersedes `PdfPrologueProbeTests`, which could only
/// compare against a transcription of the prologue.
@Suite struct PdfWriterProbeTests {
    @Test func markdownConversionMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(contentsOfFile: path + "/writer-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/writer-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n").map(String.init)
        let expected = expectedText.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).filter { $0.hasPrefix("wt") }
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, line) in cases.enumerated() where index < expected.count {
            guard let ours = answer(for: line) else { continue }
            if ours != expected[index] {
                mismatches.append("\(line)\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        print("pdf writer probe: \(cases.count) documents compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) writer divergences:\n\(report)")
    }

    private func parseLines(_ specs: [String]) -> [PdfTextLine] {
        var out: [PdfTextLine] = []
        for spec in specs {
            let append = spec.hasPrefix("+")
            let f = spec.drop(while: { $0 == "+" }).split(
                separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 8 else { continue }
            var item = PdfLayoutItem(
                text: f[7...].joined(separator: ",").replacingOccurrences(of: "~", with: " "),
                x: Float(f[2]) ?? 0, y: Float(f[1]) ?? 0, width: 40,
                fontSize: Float(f[3]) ?? 12, fontName: String(f[6]))
            item.isBold = f[4] == "1"
            item.isItalic = f[5] == "1"
            if append, !out.isEmpty {
                out[out.count - 1].items.append(item)
            } else {
                out.append(PdfTextLine(items: [item], y: item.y, page: Int(f[0]) ?? 1))
            }
        }
        return out
    }

    /// `lineIndex:Role` pairs. The mcid is the line index, stamped onto that
    /// line's items so the resolver can find it.
    private func parseRoles(_ spec: String, _ lines: inout [PdfTextLine]) -> PdfStructRoleMap? {
        if spec == "!" { return nil }
        var map: PdfStructRoleMap = [:]
        if spec == "." { return map }
        for pair in spec.split(separator: ",") {
            let f = pair.split(separator: ":")
            guard f.count >= 2, let index = Int(f[0]), index < lines.count else { continue }
            for itemIndex in lines[index].items.indices { lines[index].items[itemIndex].mcid = index }
            map[lines[index].page, default: [:]][index] = PdfStructRole.fromName(String(f[1]))
        }
        return map
    }

    private func parseBlocks(_ spec: String) -> [Int: [PdfPositionedMarkdown]] {
        if spec == "-" { return [:] }
        var map: [Int: [PdfPositionedMarkdown]] = [:]
        // `@`, not `|` — a rendered table is full of pipes.
        for block in spec.split(separator: "@") {
            let f = block.split(separator: ":")
            guard f.count >= 4 else { continue }
            let markdown = f[3...].joined(separator: ":")
                .replacingOccurrences(of: "~", with: " ")
                .replacingOccurrences(of: "^", with: "\n")
            map[Int(f[0]) ?? 1, default: []].append(
                PdfPositionedMarkdown(
                    y: Float(f[1]) ?? 0, x: Float(f[2]) ?? 0, markdown: markdown, chartOrder: nil))
        }
        return map
    }

    private func answer(for line: String) -> String? {
        let space = line.firstIndex(of: " ")
        let tag = space.map { String(line[line.startIndex..<$0]) } ?? line
        guard tag == "W" else { return nil }
        let rest = space.map { String(line[line.index(after: $0)...]) } ?? ""
        let fields = rest.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
        guard let semi = fields.firstIndex(of: ";"), semi >= 6 else { return nil }

        var options = PdfMarkdownOptions()
        if fields[0] != "d" {
            let flags = Array(fields[0])
            func flag(_ index: Int) -> Bool { (index < flags.count ? flags[index] : "1") == "1" }
            options.detectHeaders = flag(0)
            options.detectLists = flag(1)
            options.detectCode = flag(2)
            options.detectBold = flag(3)
            options.detectItalic = flag(4)
            options.detectUnderline = flag(5)
            options.includePageNumbers = flag(6)
            options.fixHyphenation = flag(7)
            options.formatUrls = flag(8)
            options.removePageNumbers = flag(9)
            options.includeImages = flag(10)
        }
        options.baseFontSize = fields[1] == "-" ? nil : Float(fields[1])

        var lines = parseLines(Array(fields[(semi + 1)...]))
        let structRoles = parseRoles(fields[2], &lines)
        let bandSplitPages: Set<Int> =
            fields[5] == "-" ? [] : Set(fields[5].split(separator: ",").compactMap { Int($0) })

        let analysis = pdfAnalyseDocument(lines, options: options, structRoles: structRoles)
        let markdown = pdfWriteMarkdown(
            analysis, options: options, pageTables: parseBlocks(fields[3]),
            pageImages: parseBlocks(fields[4]), bandSplitPages: bandSplitPages,
            structRoles: structRoles)
        return "wt " + markdown.replacingOccurrences(of: "\n", with: "^")
    }
}
