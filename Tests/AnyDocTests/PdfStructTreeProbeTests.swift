import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the structure-tree walks against `collect_tables`,
/// `collect_rows`, `collect_mcids_recursive` and `flatten_recursive`.
@Suite struct PdfStructTreeProbeTests {
    /// The reference's own variant names, so the probe's `{:?}` output can be
    /// compared directly.
    private func debugName(_ role: PdfStructRole) -> String {
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

    @Test func structureTreeWalksMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(
                contentsOfFile: path + "/structtree-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/structtree-rust.txt", encoding: .utf8)
        else { return }

        let blocks = caseText.components(separatedBy: "\n===\n")
        let expected = expectedText.components(separatedBy: "\n===\n")
        #expect(blocks.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var tableCount = 0
        for (index, block) in blocks.enumerated() where index < expected.count {
            var flat: [(depth: Int, element: PdfStructElement)] = []
            var pageNumbers: [PdfObjectId: UInt32] = [:]
            for line in block.split(separator: "\n") {
                let p = line.split(separator: " ", omittingEmptySubsequences: false)
                guard p.count >= 2, let depth = Int(p[0]) else { continue }
                var element = PdfStructElement(role: PdfStructRole.fromName(String(p[1])))
                if p.count > 3 && p[3] != "-" { element.altText = String(p[3]) }
                if p.count > 2 && p[2] != "-" {
                    for entry in p[2].split(separator: ",") {
                        let bits = entry.split(separator: ":")
                        guard bits.count == 2, let mcid = Int(bits[0]),
                            let page = UInt32(bits[1])
                        else { continue }
                        if page > 0 {
                            let id = PdfObjectId(number: page, generation: 0)
                            pageNumbers[id] = page
                            element.contentRefs.append(
                                PdfMarkedContentRef(mcid: mcid, pageID: id))
                        } else {
                            element.contentRefs.append(
                                PdfMarkedContentRef(mcid: mcid, pageID: nil))
                        }
                    }
                }
                flat.append((depth, element))
            }

            var cursor = 0
            func build(_ depth: Int) -> [PdfStructElement] {
                var out: [PdfStructElement] = []
                while cursor < flat.count && flat[cursor].depth == depth {
                    var element = flat[cursor].element
                    cursor += 1
                    element.children = build(depth + 1)
                    out.append(element)
                }
                return out
            }
            let tree = build(0)

            let tables = pdfCollectStructTables(tree, pageNumbers: pageNumbers)
            tableCount += tables.count
            var ours = "tables \(tables.count)\n"
            for table in tables {
                ours += "t \(table.rows.count)\n"
                for row in table.rows {
                    ours += "r \(row.cells.count)"
                    for cell in row.cells {
                        ours += " \(cell.isHeader ? 1 : 0)"
                        for entry in cell.mcids { ours += ":\(entry.mcid)/\(entry.page)" }
                    }
                    ours += "\n"
                }
            }
            let flattened = pdfFlattenStructElements(tree)
            ours += "flat \(flattened.count)\n"
            for element in flattened {
                ours += "e \(element.depth) \(debugName(element.role)) \(element.childCount) "
                ours += (element.altText ?? "-") + "\n"
            }
            ours += "nonheading \(tree.filter(\.role.isNonHeadingContent).count)\n"

            if ours != expected[index] {
                let a = ours.split(separator: "\n", omittingEmptySubsequences: false)
                let b = expected[index].split(separator: "\n", omittingEmptySubsequences: false)
                var diff: [String] = []
                for line in 0..<max(a.count, b.count) {
                    let x = line < a.count ? String(a[line]) : "<none>"
                    let y = line < b.count ? String(b[line]) : "<none>"
                    if x != y { diff.append("    ours: \(x)\n    rust: \(y)") }
                }
                mismatches.append("case \(index)\n" + diff.prefix(3).joined(separator: "\n"))
            }
        }
        print("pdf struct-tree probe: \(blocks.count) cases compared, \(tableCount) tables")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) struct-tree divergences:\n\(report)")
    }
}
