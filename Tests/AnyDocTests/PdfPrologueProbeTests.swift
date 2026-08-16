import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the analysis prologue.
///
/// The reference's prologue sits inside a six-hundred-line function and
/// cannot be called on its own, so the oracle transcribes it verbatim into a
/// probe — which compares the port against a copy of the reference's
/// ordering rather than against the reference itself.
///
/// `PdfWriterProbeTests` now covers the same ground properly, calling the
/// reference function whole. This one is kept because it isolates: when both
/// fail, the prologue is where to look; when only the writer probe fails,
/// the prologue is fine.
@Suite struct PdfPrologueProbeTests {
    @Test func theAnalysisPrologueMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/prologue-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/prologue-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n").map(String.init)
        let expected = expectedText.split(separator: "\n").filter { !$0.isEmpty }.map(String.init)
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        for (index, line) in cases.enumerated() where index < expected.count {
            guard let ours = answer(for: line) else { continue }
            if ours != expected[index] {
                mismatches.append("\(line)\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        print("pdf prologue probe: \(cases.count) cases compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) prologue divergences:\n\(report)")
    }

    private func parseLines(_ specs: [String]) -> [PdfTextLine] {
        var out: [PdfTextLine] = []
        for spec in specs {
            let append = spec.hasPrefix("+")
            let f = spec.drop(while: { $0 == "+" }).split(
                separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 7 else { continue }
            var item = PdfLayoutItem(
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

    private func parseChartRegions(_ spec: String) -> [Int: [PdfImageRegion]] {
        if spec == "-" { return [:] }
        var map: [Int: [PdfImageRegion]] = [:]
        for region in spec.split(separator: ";") {
            let f = region.split(separator: ":")
            guard f.count >= 5 else { continue }
            map[Int(f[0]) ?? 1, default: []].append(
                PdfImageRegion(
                    x0: Float(f[1]) ?? 0, y0: Float(f[2]) ?? 0, x1: Float(f[3]) ?? 0,
                    y1: Float(f[4]) ?? 0))
        }
        return map
    }

    private func answer(for line: String) -> String? {
        let space = line.firstIndex(of: " ")
        let tag = space.map { String(line[line.startIndex..<$0]) } ?? line
        guard tag == "P" else { return nil }
        let rest = space.map { String(line[line.index(after: $0)...]) } ?? ""
        let fields = rest.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
        guard let semi = fields.firstIndex(of: ";"), fields.count >= 3 else { return nil }

        var options = PdfMarkdownOptions()
        options.baseFontSize = fields[0] == "-" ? nil : Float(fields[0])
        let analysis = pdfAnalyseDocument(
            parseLines(Array(fields[(semi + 1)...])), options: options,
            pageChartRegions: parseChartRegions(fields[2]), structRoles: parseRoles(fields[1]))

        func sorted(_ set: Set<Int>) -> String {
            set.sorted().map(String.init).joined(separator: ",")
        }
        let tiers = analysis.headingTiers.map { twoPlaces($0) }.joined(separator: "/")
        let levels = analysis.sequenceHeadingLevels.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }.joined(separator: ",")
        let texts = analysis.lines.map {
            pdfLineText($0).replacingOccurrences(of: " ", with: "~")
        }.joined(separator: "|")
        return "pg b=\(twoPlaces(analysis.baseSize)) t=\(tiers) "
            + "p=\(threePlaces(analysis.paragraphThreshold)) n=\(analysis.lines.count) "
            + "iso=\(sorted(analysis.isolatedLines)) "
            + "wb=\(sorted(analysis.wrappedBoldParagraphLines)) "
            + "ex=\(sorted(analysis.sequenceExcludedLines)) seq=\(levels) "
            + "ov=\(sorted(analysis.overusedHeadingLevels)) tx=\(texts)"
    }

    private func twoPlaces(_ value: Float) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        let scaled = (Double(value) * 100).rounded(.toNearestOrAwayFromZero)
        let whole = Int(scaled / 100)
        let fraction = abs(Int(scaled) % 100)
        let sign = (scaled < 0 && whole == 0) ? "-" : ""
        return "\(sign)\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    private func threePlaces(_ value: Float) -> String {
        if value.isNaN { return "NaN" }
        let scaled = (Double(value) * 1000).rounded(.toNearestOrAwayFromZero)
        let whole = Int(scaled / 1000)
        let fraction = abs(Int(scaled) % 1000)
        let sign = (scaled < 0 && whole == 0) ? "-" : ""
        var digits = "\(fraction)"
        while digits.count < 3 { digits = "0" + digits }
        return "\(sign)\(whole).\(digits)"
    }
}
