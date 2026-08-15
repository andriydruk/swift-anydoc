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
        case "CH":
            let raw = split.count > 1 ? String(split[1]) : ""
            let fields = raw.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
            guard let bar = fields.firstIndex(of: "|"), let semi = fields.firstIndex(of: ";"),
                fields.count > 1
            else { return nil }
            let excluded: Set<Int> =
                fields[1] == "-"
                ? [] : Set(fields[1].split(separator: ",").compactMap { Int($0) })
            let tiers = fields[(bar + 1)..<semi].compactMap { Float($0) }
            var built: [PdfTextLine] = []
            for spec in fields[(semi + 1)...] {
                let append = spec.hasPrefix("+")
                let f = (append ? String(spec.dropFirst()) : spec)
                    .split(separator: ",", omittingEmptySubsequences: false)
                guard f.count >= 7, let page = Int(f[0]), let y = Float(f[1]),
                    let x = Float(f[2]), let size = Float(f[3])
                else { continue }
                var item = PdfLayoutItem(
                    text: f[6].replacingOccurrences(of: "~", with: " "), x: x, y: y,
                    width: 40, fontSize: size, fontName: String(f[5]))
                item.isBold = f[4] == "1"
                if append, !built.isEmpty {
                    built[built.count - 1].items.append(item)
                } else {
                    built.append(PdfTextLine(items: [item], y: y, page: page))
                }
            }
            let decisions = pdfClassifyHeadingSequences(
                built, bodySize: Float(fields[0]) ?? 10, tiers: tiers, excludedLines: excluded)
            var out = "ch \(decisions.count)"
            for key in decisions.keys.sorted() { out += " \(key):\(decisions[key] ?? 0)" }
            return out
        case "D":
            let raw = split.count > 1 ? String(split[1]) : ""
            let fields = raw.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
            guard let semi = fields.firstIndex(of: ";"), let target = Int(fields[0])
            else { return nil }
            var built: [PdfTextLine] = []
            for spec in fields[(semi + 1)...] {
                let append = spec.hasPrefix("+")
                let f = (append ? String(spec.dropFirst()) : spec)
                    .split(separator: ",", omittingEmptySubsequences: false)
                guard f.count >= 5, let page = Int(f[0]), let y = Float(f[1]),
                    let x = Float(f[2]), let width = Float(f[3])
                else { continue }
                let item = PdfLayoutItem(
                    text: f[4].replacingOccurrences(of: "~", with: " "), x: x, y: y,
                    width: width, fontSize: 12, fontName: "F1")
                if append, !built.isEmpty {
                    built[built.count - 1].items.append(item)
                } else {
                    built.append(PdfTextLine(items: [item], y: y, page: page))
                }
            }
            let peer = target < built.count && pdfHasDisplacedBaselinePeer(built, target)
            return "d \(peer ? 1 : 0)"
        case "SL":
            let raw = split.count > 1 ? String(split[1]) : ""
            let fields = raw.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
            let bar = fields.firstIndex(of: "|") ?? fields.count
            guard fields.count >= 4 else { return nil }
            let depth = Int(fields[3]) ?? 0
            let tiers = fields[min(bar, fields.count)...].compactMap { Float($0) }
            let candidate = PdfHeadingCandidate(
                lineIndex: 0, fontSize: Float(fields[0]) ?? 12,
                style: PdfVisualStyle(font: "F1", xBucket: 0, bold: fields[2] == "1"),
                numbering: depth > 0
                    ? PdfNumbering(
                        kind: .decimal, depth: depth,
                        parts: [UInt32](repeating: 1, count: depth))
                    : nil)
            return "sl \(pdfSequenceLevel(candidate, bodySize: Float(fields[1]) ?? 10, tiers: tiers))"
        case "SS":
            let raw = split.count > 1 ? String(split[1]) : ""
            let fields = raw.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
            guard let semi = fields.firstIndex(of: ";"), fields.count > 1,
                let leftIndex = Int(fields[0]), let rightIndex = Int(fields[1])
            else { return nil }
            let pages = fields[(semi + 1)...].compactMap { Int($0) }
            let built = pages.map { PdfTextLine(items: [], y: 0, page: $0) }
            func candidate(_ index: Int) -> PdfHeadingCandidate {
                PdfHeadingCandidate(
                    lineIndex: index, fontSize: 12,
                    style: PdfVisualStyle(font: "F1", xBucket: 0, bold: false), numbering: nil)
            }
            let separated =
                leftIndex < built.count && rightIndex < built.count
                && pdfNumberingHasSectionSeparation(
                    candidate(leftIndex), candidate(rightIndex), built)
            return "ss \(separated ? 1 : 0)"
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
