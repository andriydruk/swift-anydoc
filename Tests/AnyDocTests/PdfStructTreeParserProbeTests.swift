import Foundation
import Testing

@testable import AnyDoc

/// Differential check of structure-tree parsing against `StructTree::from_doc`
/// and the parsing helpers beneath it, over the generated tagged corpus.
@Suite struct PdfStructTreeParserProbeTests {
    /// The reference's own variant names, for comparing its `{:?}` output.
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

    @Test func structureTreeParsingMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_STRUCT_CORPUS"],
            !path.isEmpty
        else { return }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let names = files.filter { $0.hasSuffix(".pdf") }.map {
            String($0.dropLast(4))
        }.sorted()
        guard !names.isEmpty else { return }

        var mismatches: [String] = []
        var compared = 0
        for name in names {
            guard let data = FileManager.default.contents(atPath: path + "/\(name).pdf"),
                let expected = try? String(
                    contentsOfFile: path + "/\(name).expected", encoding: .utf8)
            else { continue }
            compared += 1

            guard var document = try? PdfDocument(bytes: [UInt8](data)) else { continue }
            var ours: String
            if let tree = pdfParseStructTree(&document) {
                let flat = pdfFlattenStructElements(tree)
                ours = "#TREE \(flat.count)\n"
                for element in flat {
                    ours += "e \(element.depth) \(debugName(element.role)) "
                    ours += "\(element.childCount) \(element.altText ?? "-")"
                    for reference in element.contentRefs {
                        let page = reference.pageID.map { String($0.number) } ?? "-"
                        ours += " \(reference.mcid):\(page)"
                    }
                    ours += "\n"
                }
            } else {
                ours = "#NONE\n"
            }

            if ours != expected {
                let a = ours.split(separator: "\n", omittingEmptySubsequences: false)
                let b = expected.split(separator: "\n", omittingEmptySubsequences: false)
                var diff: [String] = []
                for line in 0..<max(a.count, b.count) {
                    let x = line < a.count ? String(a[line]) : "<none>"
                    let y = line < b.count ? String(b[line]) : "<none>"
                    if x != y { diff.append("    ours: \(x)\n    rust: \(y)") }
                }
                mismatches.append("\(name)\n" + diff.prefix(3).joined(separator: "\n"))
            }
        }
        print("pdf struct-parse probe: \(compared) documents compared")
        let report = mismatches.prefix(3).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) struct-parse divergences:\n\(report)")
    }
}
