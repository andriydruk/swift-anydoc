import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the isolation cluster against
/// `resolve_line_struct_role`, `detect_overused_struct_heading_levels` and
/// `find_isolated_lines`.
@Suite struct PdfIsolatedProbeTests {
    @Test func isolationMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/isolated-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/isolated-rust.txt", encoding: .utf8)
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
        print("pdf isolation probe: \(cases.count) cases compared — \(shape)")
        let report = mismatches.prefix(5).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) isolation divergences:\n\(report)")
    }

    private func answer(for line: String) -> String? {
        let space = line.firstIndex(of: " ")
        let tag = space.map { String(line[line.startIndex..<$0]) } ?? line
        let rest = space.map { String(line[line.index(after: $0)...]) } ?? ""
        let fields = rest.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
        guard let semi = fields.firstIndex(of: ";") else { return nil }
        let lines = parseLines(Array(fields[(semi + 1)...]))

        switch tag {
        case "S":
            guard let roles = parseRoles(fields[0]) else { return "sr" }
            var out = "sr"
            for line in lines {
                out += pdfResolveLineStructRole(line, roles).map { " \(rustName($0))" } ?? " -"
            }
            return out
        case "O":
            let found = pdfDetectOverusedStructHeadingLevels(lines, parseRoles(fields[0]))
            return "ov \(found.count)" + found.sorted().map { " \($0)" }.joined()
        case "I":
            let found = pdfFindIsolatedLines(
                lines, baseSize: Float(fields[0]) ?? 10, paraThreshold: Float(fields[1]) ?? 20)
            return "il \(found.count)" + found.sorted().map { " \($0)" }.joined()
        default:
            return nil
        }
    }

    private func parseLines(_ specs: [String]) -> [PdfTextLine] {
        var out: [PdfTextLine] = []
        for spec in specs {
            let append = spec.hasPrefix("+")
            let f = spec.drop(while: { $0 == "+" }).split(
                separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 6 else { continue }
            // Rejoined, so a comma in the text survives this split — see the
            // matching note in the oracle.
            var item = PdfLayoutItem(
                text: f[5...].joined(separator: ",").replacingOccurrences(of: "~", with: " "),
                x: Float(f[2]) ?? 0, y: Float(f[1]) ?? 0, width: 40,
                fontSize: Float(f[3]) ?? 12, fontName: "F1")
            item.height = 12
            item.mcid = f[4] == "-" ? nil : Int(f[4])
            if append, !out.isEmpty {
                out[out.count - 1].items.append(item)
            } else {
                out.append(
                    PdfTextLine(items: [item], y: item.y, page: Int(f[0]) ?? 1))
            }
        }
        return out
    }

    /// `!` is an absent map, `.` an empty one — a distinction the overuse
    /// scan turns on.
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

    /// The reference's `Debug` spelling of a role, which is what the probe
    /// prints.
    private func rustName(_ role: PdfStructRole) -> String {
        switch role {
        case .document: return "Document"
        case .part: return "Part"
        case .art: return "Art"
        case .sect: return "Sect"
        case .div: return "Div"
        case .blockQuote: return "BlockQuote"
        case .caption: return "Caption"
        case .toc: return "TOC"
        case .tocItem: return "TOCI"
        case .index: return "Index"
        case .nonStruct: return "NonStruct"
        case .private: return "Private"
        case .h: return "H"
        case .h1: return "H1"
        case .h2: return "H2"
        case .h3: return "H3"
        case .h4: return "H4"
        case .h5: return "H5"
        case .h6: return "H6"
        case .p: return "P"
        case .list: return "L"
        case .listItem: return "LI"
        case .label: return "Lbl"
        case .listBody: return "LBody"
        case .table: return "Table"
        case .tableRow: return "TR"
        case .tableHeaderCell: return "TH"
        case .tableDataCell: return "TD"
        case .tableHead: return "THead"
        case .tableBody: return "TBody"
        case .tableFoot: return "TFoot"
        case .span: return "Span"
        case .quote: return "Quote"
        case .note: return "Note"
        case .reference: return "Reference"
        case .bibEntry: return "BibEntry"
        case .code: return "Code"
        case .link: return "Link"
        case .annot: return "Annot"
        case .figure: return "Figure"
        case .formula: return "Formula"
        case .form: return "Form"
        case .ruby: return "Ruby"
        case .rubyBase: return "RB"
        case .rubyText: return "RT"
        case .rubyPunctuation: return "RP"
        case .warichu: return "Warichu"
        case .warichuText: return "WT"
        case .warichuPunctuation: return "WP"
        case .other(let name): return "Other(\"\(name)\")"
        }
    }
}
