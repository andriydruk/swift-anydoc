import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the preprocess merge pair and comparison helpers
/// against `merge_heading_lines`, `merge_drop_caps`,
/// `effective_heading_level`, `normalize_for_comparison`,
/// `is_structural_line` and `is_decorative_separator`.
@Suite struct PdfPreprocessProbeTests {
    @Test func preprocessMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/preprocess2-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/preprocess2-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n").map(String.init)
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
        print("pdf preprocess probe: \(cases.count) cases compared — \(shape)")
        let report = mismatches.prefix(5).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) preprocess divergences:\n\(report)")
    }

    private func parseLines(_ specs: [String]) -> [PdfTextLine] {
        var out: [PdfTextLine] = []
        for spec in specs {
            let append = spec.hasPrefix("+")
            let f = spec.drop(while: { $0 == "+" }).split(
                separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 7 else { continue }
            var item = PdfLayoutItem(
                // Rejoined so a comma in the text survives the split.
                text: f[6...].joined(separator: ",").replacingOccurrences(of: "~", with: " "),
                x: Float(f[2]) ?? 0, y: Float(f[1]) ?? 0, width: 40,
                fontSize: Float(f[3]) ?? 12, fontName: "F1")
            item.isBold = f[4] == "1"
            item.mcid = f[5] == "-" ? nil : Int(f[5])
            if append, !out.isEmpty {
                out[out.count - 1].items.append(item)
            } else {
                out.append(PdfTextLine(items: [item], y: item.y, page: Int(f[0]) ?? 1))
            }
        }
        return out
    }

    private func parseRoles(_ spec: String) -> PdfStructRoleMap? {
        if spec == "!" { return nil }
        var map: PdfStructRoleMap = [:]
        if spec == "." { return map }
        for triple in spec.split(separator: ",") {
            let f = triple.split(separator: ":")
            guard f.count >= 3 else { continue }
            map[Int(f[0]) ?? 1, default: [:]][Int(f[1]) ?? 0] = PdfStructRole.fromName(String(f[2]))
        }
        return map
    }

    private func shape(_ tag: String, _ lines: [PdfTextLine]) -> String {
        var out = "\(tag) \(lines.count)"
        for line in lines {
            let text = pdfLineText(line).replacingOccurrences(of: " ", with: "~")
            out += " \(Int(line.y.rounded(.toNearestOrEven))):\(line.items.count):\(text)"
        }
        return out
    }

    private func answer(for line: String) -> String? {
        let space = line.firstIndex(of: " ")
        let tag = space.map { String(line[line.startIndex..<$0]) } ?? line
        let rest = space.map { String(line[line.index(after: $0)...]) } ?? ""
        let fields = rest.split(separator: " ").filter { !$0.isEmpty }.map(String.init)

        switch tag {
        case "H", "E":
            guard let semi = fields.firstIndex(of: ";"), fields.count > 1 else { return nil }
            let base = Float(fields[0]) ?? 10
            let roles = parseRoles(fields[1])
            let tiers = fields[2..<semi].compactMap { Float($0) }
            let built = parseLines(Array(fields[(semi + 1)...]))
            if tag == "H" {
                return shape(
                    "mh",
                    pdfMergeHeadingLines(
                        built, baseSize: base, tiers: tiers, structRoles: roles))
            }
            return "me"
                + built.map {
                    pdfEffectiveHeadingLevel(
                        $0, baseSize: base, tiers: tiers, structRoles: roles
                    ).map { " \($0)" } ?? " -"
                }.joined()
        case "D":
            guard let semi = fields.firstIndex(of: ";"), !fields.isEmpty else { return nil }
            let built = parseLines(Array(fields[(semi + 1)...]))
            return shape("md", pdfMergeDropCaps(built, baseSize: Float(fields[0]) ?? 10))
        case "R":
            guard let semi = fields.firstIndex(of: ";"), !fields.isEmpty else { return nil }
            var built: [PdfTextLine] = []
            for spec in fields[(semi + 1)...] {
                let f = spec.split(separator: ",", omittingEmptySubsequences: false)
                guard f.count >= 3, let page = Int(f[0]), let y = Float(f[1]) else { continue }
                let item = PdfLayoutItem(
                    text: f[2...].joined(separator: ",").replacingOccurrences(of: "~", with: " "),
                    x: 20, y: y, width: 40, fontSize: 10, fontName: "F1")
                built.append(PdfTextLine(items: [item], y: y, page: page))
            }
            let kept = pdfStripRepeatedLines(built, pageCount: Int(fields[0]) ?? 3)
            return "sr \(kept.count)"
                + kept.map {
                    " \($0.page):\(Int($0.y.rounded(.toNearestOrEven)))"
                        + ":\(pdfLineText($0).replacingOccurrences(of: " ", with: "~"))"
                }.joined()
        case "N":
            let text = rest.replacingOccurrences(of: "~", with: " ")
            return "mn "
                + pdfNormalizeForComparison(text).replacingOccurrences(of: " ", with: "~")
        case "S":
            return "ms \(pdfIsStructuralLine(rest.replacingOccurrences(of: "~", with: " ")) ? 1 : 0)"
        case "X":
            return
                "mx \(pdfIsDecorativeSeparator(rest.replacingOccurrences(of: "~", with: " ")) ? 1 : 0)"
        default:
            return nil
        }
    }
}
