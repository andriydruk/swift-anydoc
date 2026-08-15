import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the section-numbering parser against
/// `markdown/heading.rs`.
@Suite struct PdfNumberingProbeTests {
    @Test func numberingMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/numbering-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/numbering-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let expected = expectedText.split(separator: "\n").filter { !$0.isEmpty }.map(String.init)
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var verdicts: [String: Int] = [:]
        for (index, line) in cases.enumerated() where index < expected.count {
            guard let ours = answer(for: line) else { continue }
            verdicts[String(ours.prefix(1)), default: 0] += 1
            if ours != expected[index] {
                mismatches.append("\(line)\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        let shape = verdicts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
        print("pdf numbering probe: \(cases.count) cases compared — \(shape)")
        let report = mismatches.prefix(6).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) numbering divergences:\n\(report)")
    }

    private func answer(for line: String) -> String? {
        let split = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let tag = split.first.map(String.init) else { return nil }
        let text = (split.count > 1 ? String(split[1]) : "")
            .replacingOccurrences(of: "~", with: " ")

        switch tag {
        case "R":
            return pdfRomanValue(text).map { "r \($0)" } ?? "r -"
        case "N":
            guard let numbering = pdfParseNumbering(text) else { return "n -" }
            var out = "n \(numbering.kind == .decimal ? "d" : "m") \(numbering.depth)"
            for part in numbering.parts { out += " \(part)" }
            return out
        case "V":
            // The raw rest, since `~` is meaningful inside the fields.
            let raw = split.count > 1 ? String(split[1]) : ""
            let fields = raw.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
            guard let semi = fields.firstIndex(of: ";"), let mode = fields.first
            else { return nil }
            let items: [PdfLayoutItem] = fields[(semi + 1)...].compactMap { field in
                let f = field.split(separator: ",", omittingEmptySubsequences: false)
                guard f.count >= 5, let size = Float(f[1]), let x = Float(f[3]) else { return nil }
                var item = PdfLayoutItem(
                    text: f[4].replacingOccurrences(of: "~", with: " "), x: x, y: 0, width: 10,
                    fontSize: size, fontName: String(f[0]))
                item.isBold = f[2] == "1"
                return item
            }
            let one = PdfTextLine(items: items, y: 0)
            let many = items.map { PdfTextLine(items: [$0], y: 0) }
            switch mode {
            case "0": return "v " + (pdfDominantFont(one) ?? "-")
            case "1":
                return "v " + (pdfDominantFontSize(one).map { twoPlaces($0) } ?? "-")
            case "2": return "v " + (pdfDocumentBodyFont(many) ?? "-")
            case "3": return "v " + (pdfDocumentBodyXBucket(many).map(String.init) ?? "-")
            default:
                guard let style = pdfVisualStyle(one) else { return "v -" }
                return "v \(style.font)/\(style.xBucket)/\(style.bold ? 1 : 0)"
            }
        case "T":
            let fields = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 3 else { return "t 0" }
            return "t \(pdfTitleLike(String(fields[2]), numbered: fields[0] == "1", bold: fields[1] == "1") ? 1 : 0)"
        case "S":
            return "s \(pdfCompleteSidebarLabel(text) ? 1 : 0)"
        case "A":
            return "a \(pdfHasAdditionalDecimalNumbering(text) ? 1 : 0)"
        case "H":
            let sides = text.split(separator: "|", omittingEmptySubsequences: false)
            func parse(_ side: Substring?) -> [UInt32] {
                (side ?? "").split(separator: ",").compactMap { UInt32($0.rustTrim()) }
            }
            let left = parse(sides.first)
            let right = parse(sides.count > 1 ? sides[1] : nil)
            return "h \(pdfNumberingFormsHierarchy(left, right) ? 1 : 0)"
        default:
            return nil
        }
    }

    private func twoPlaces(_ value: Float) -> String {
        let scaled = (Double(value) * 100).rounded(.toNearestOrAwayFromZero)
        let whole = Int(scaled / 100)
        let fraction = abs(Int(scaled) % 100)
        let sign = (scaled < 0 && whole == 0) ? "-" : ""
        return "\(sign)\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }
}
