import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the wrapped-bold cluster against
/// `markdown/convert.rs`.
@Suite struct PdfWrappedBoldProbeTests {
    @Test func wrappedBoldMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/wrapped-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/wrapped-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let expected = expectedText.split(separator: "\n").filter { !$0.isEmpty }.map(String.init)
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
        print("pdf wrapped-bold probe: \(cases.count) cases compared — \(shape)")
        let report = mismatches.prefix(5).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) wrapped-bold divergences:\n\(report)")
    }

    private func parseLines(_ fields: ArraySlice<String>) -> [PdfTextLine] {
        var out: [PdfTextLine] = []
        for spec in fields {
            let append = spec.hasPrefix("+")
            let f = (append ? String(spec.dropFirst()) : spec)
                .split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 6, let page = Int(f[0]), let y = Float(f[1]),
                let x = Float(f[2]), let size = Float(f[3])
            else { continue }
            var item = PdfLayoutItem(
                // Rejoined so a comma in the text survives this split.
                text: f[5...].joined(separator: ",").replacingOccurrences(of: "~", with: " "),
                x: x, y: y, width: 40,
                fontSize: size, fontName: "F1")
            item.isBold = f[4] == "1"
            if append, !out.isEmpty {
                out[out.count - 1].items.append(item)
            } else {
                out.append(PdfTextLine(items: [item], y: y, page: page))
            }
        }
        return out
    }

    private func answer(for line: String) -> String? {
        let split = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let tag = split.first.map(String.init) else { return nil }
        let rest = split.count > 1 ? String(split[1]) : ""
        let fields = rest.split(separator: " ").filter { !$0.isEmpty }.map(String.init)

        switch tag {
        case "N":
            let text = rest.replacingOccurrences(of: "~", with: " ")
            return "wn \(pdfStartsWithSectionNumberAndTitle(text) ? 1 : 0)"
        case "M":
            guard let semi = fields.firstIndex(of: ";"), fields.count > 1 else { return nil }
            let merged = pdfMergeWrappedBoldHeadingGroups(
                parseLines(fields[(semi + 1)...]), baseSize: Float(fields[0]) ?? 10,
                paraThreshold: Float(fields[1]) ?? 20)
            return "wm \(merged.count)"
                + merged.map { " \(Int($0.y.rounded(.toNearestOrEven))):\($0.items.count)" }
                .joined()
        case "C":
            let markdown = rest.replacingOccurrences(of: "~", with: " ")
                .replacingOccurrences(of: "^", with: "\n")
            return "wc \(pdfCountTableColumns(markdown))"
        case "A":
            guard let semi = fields.firstIndex(of: ";"), !fields.isEmpty else { return nil }
            let base = Float(fields[0]) ?? 10
            let built = parseLines(fields[(semi + 1)...])
            return "wa "
                + built.map { pdfIsBodySizeAllBoldLine($0, bodySize: base) ? "1" : "0" }.joined()
        case "W":
            guard let semi = fields.firstIndex(of: ";"), !fields.isEmpty else { return nil }
            let threshold = Float(fields[0]) ?? 20
            let built = parseLines(fields[(semi + 1)...])
            var out = "ww "
            for index in 0..<max(built.count - 1, 0) {
                out +=
                    pdfIsWrappedSameStyleLine(
                        built[index], built[index + 1], paragraphThreshold: threshold) ? "1" : "0"
            }
            return out
        case "F":
            guard let semi = fields.firstIndex(of: ";"), fields.count > 1 else { return nil }
            let built = parseLines(fields[(semi + 1)...])
            let found = pdfFindWrappedBoldParagraphLines(
                built, bodySize: Float(fields[0]) ?? 10,
                paragraphThreshold: Float(fields[1]) ?? 20)
            var out = "wf \(found.count)"
            for key in found.sorted() { out += " \(key)" }
            return out
        case "R":
            let role = PdfStructRole.fromName(rest)
            return "wr \(pdfStructRoleHeadingLevel(role).map(String.init) ?? "-")"
        default:
            return nil
        }
    }
}
