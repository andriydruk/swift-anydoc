/// The PDF structure tree and the pure operations over it, ported from
/// `structure_tree.rs` in pdf-inspector.
///
/// A *tagged* PDF carries a parallel tree describing what its content means —
/// this is a heading, that is a table cell — alongside the drawing operators
/// that put ink on the page. Where it exists it is far better evidence than
/// any geometric heuristic, because it is what the author declared rather than
/// what the layout suggests.
///
/// This wave ports the tree's shape and the operations that walk it. Building
/// one from a document is a separate concern and comes later.

/// A structure element's semantic role.
enum PdfStructRole: Equatable {
    case document, part, art, sect, div, blockQuote, caption, toc, tocItem, index
    case nonStruct, `private`
    case h, h1, h2, h3, h4, h5, h6, p
    case list, listItem, label, listBody
    case table, tableRow, tableHeaderCell, tableDataCell, tableHead, tableBody, tableFoot
    case span, quote, note, reference, bibEntry, code, link, annot
    case figure, formula, form
    case ruby, rubyBase, rubyText, rubyPunctuation, warichu, warichuText, warichuPunctuation
    case other(String)

    /// The standard structure type names, in the reference's own spelling.
    static func fromName(_ name: String) -> PdfStructRole {
        switch name {
        case "Document": return .document
        case "Part": return .part
        case "Art": return .art
        case "Sect": return .sect
        case "Div": return .div
        case "BlockQuote": return .blockQuote
        case "Caption": return .caption
        case "TOC": return .toc
        case "TOCI": return .tocItem
        case "Index": return .index
        case "NonStruct": return .nonStruct
        case "Private": return .private
        case "H": return .h
        case "H1": return .h1
        case "H2": return .h2
        case "H3": return .h3
        case "H4": return .h4
        case "H5": return .h5
        case "H6": return .h6
        case "P": return .p
        case "L": return .list
        case "LI": return .listItem
        case "Lbl": return .label
        case "LBody": return .listBody
        case "Table": return .table
        case "TR": return .tableRow
        case "TH": return .tableHeaderCell
        case "TD": return .tableDataCell
        case "THead": return .tableHead
        case "TBody": return .tableBody
        case "TFoot": return .tableFoot
        case "Span": return .span
        case "Quote": return .quote
        case "Note": return .note
        case "Reference": return .reference
        case "BibEntry": return .bibEntry
        case "Code": return .code
        case "Link": return .link
        case "Annot": return .annot
        case "Figure": return .figure
        case "Formula": return .formula
        case "Form": return .form
        case "Ruby": return .ruby
        case "RB": return .rubyBase
        case "RT": return .rubyText
        case "RP": return .rubyPunctuation
        case "Warichu": return .warichu
        case "WT": return .warichuText
        case "WP": return .warichuPunctuation
        default: return .other(name)
        }
    }

    /// Roles whose text must never be promoted to a heading by the visual
    /// heuristic.
    ///
    /// These carry an explicit non-heading meaning — lists, quotes, notes,
    /// captions, table cells — yet their text is often short and visually
    /// isolated, which is exactly what the heuristic keys on. Headings and
    /// generic containers are excluded so it can still fire there.
    ///
    /// **`figure` is deliberately absent.** Cover pages routinely tag the
    /// document title inside a Figure, next to a seal or logo, and that title
    /// is a real heading. `formula` and `form` stay: a line explicitly tagged
    /// as an equation or a form field never is.
    var isNonHeadingContent: Bool {
        switch self {
        case .list, .listItem, .label, .listBody, .blockQuote, .quote, .caption, .toc,
            .tocItem, .index, .note, .reference, .bibEntry, .code, .formula, .form,
            .table, .tableRow, .tableHeaderCell, .tableDataCell, .tableHead, .tableBody,
            .tableFoot:
            return true
        default:
            return false
        }
    }
}

/// A reference from a structure element to marked content in a page stream.
struct PdfMarkedContentRef: Equatable {
    /// The id used by the `BDC`/`BMC` operators in the content stream.
    var mcid: Int
    /// The page the content sits on, when the element declared one.
    var pageID: PdfObjectId?
}

/// A node in the structure tree.
struct PdfStructElement {
    var role: PdfStructRole
    /// Alternative text, for figures and illustrations.
    var altText: String?
    /// A text override, used for things like ligatures.
    var actualText: String?
    var language: String?
    /// Marked content belonging directly to this element.
    var contentRefs: [PdfMarkedContentRef] = []
    var children: [PdfStructElement] = []
}

/// A table cell recovered from the structure tree.
struct PdfStructTableCell: Equatable {
    var isHeader: Bool
    /// Marked-content ids with the page numbers they resolved to.
    var mcids: [(mcid: Int, page: UInt32)]

    static func == (a: PdfStructTableCell, b: PdfStructTableCell) -> Bool {
        a.isHeader == b.isHeader && a.mcids.count == b.mcids.count
            && zip(a.mcids, b.mcids).allSatisfy { $0 == $1 }
    }
}

struct PdfStructTableRow: Equatable {
    var cells: [PdfStructTableCell]
}

struct PdfStructTable: Equatable {
    var rows: [PdfStructTableRow]
}

/// Every table the structure tree declares.
///
/// A `Table` element stops the descent — nested tables inside one are not
/// collected separately, because the outer table owns their cells. Two rows
/// are required, and at least one row must hold cells: a `Table` with a single
/// row is a layout device often enough that it is not worth the false
/// positives.
func pdfCollectStructTables(
    _ elements: [PdfStructElement], pageNumbers: [PdfObjectId: UInt32]
) -> [PdfStructTable] {
    var tables: [PdfStructTable] = []
    func walk(_ elements: [PdfStructElement]) {
        for element in elements {
            if element.role == .table {
                let rows = pdfCollectStructRows(element.children, pageNumbers: pageNumbers)
                if rows.count >= 2 && rows.contains(where: { !$0.cells.isEmpty }) {
                    tables.append(PdfStructTable(rows: rows))
                }
            } else {
                walk(element.children)
            }
        }
    }
    walk(elements)
    return tables
}

/// Rows from a table's children, descending transparently through the
/// `THead`/`TBody`/`TFoot` grouping elements — which carry no rows of their
/// own but are where real documents put them.
func pdfCollectStructRows(
    _ elements: [PdfStructElement], pageNumbers: [PdfObjectId: UInt32]
) -> [PdfStructTableRow] {
    var rows: [PdfStructTableRow] = []
    for element in elements {
        switch element.role {
        case .tableRow:
            var cells: [PdfStructTableCell] = []
            for child in element.children
            where child.role == .tableDataCell || child.role == .tableHeaderCell {
                cells.append(
                    PdfStructTableCell(
                        isHeader: child.role == .tableHeaderCell,
                        mcids: pdfCollectStructMcids(child, pageNumbers: pageNumbers)))
            }
            // Appended even when empty, so an empty row still counts toward
            // the two-row minimum above.
            rows.append(PdfStructTableRow(cells: cells))
        case .tableHead, .tableBody, .tableFoot:
            rows.append(
                contentsOf: pdfCollectStructRows(element.children, pageNumbers: pageNumbers))
        default:
            break
        }
    }
    return rows
}

/// Every marked-content id under an element, depth first.
///
/// A reference whose page cannot be resolved is dropped rather than kept with
/// a guessed page — the id alone is meaningless without knowing which stream
/// it indexes.
func pdfCollectStructMcids(
    _ element: PdfStructElement, pageNumbers: [PdfObjectId: UInt32]
) -> [(mcid: Int, page: UInt32)] {
    var mcids: [(mcid: Int, page: UInt32)] = []
    func walk(_ element: PdfStructElement) {
        for reference in element.contentRefs {
            if let pageID = reference.pageID, let page = pageNumbers[pageID] {
                mcids.append((reference.mcid, page))
            }
        }
        for child in element.children { walk(child) }
    }
    walk(element)
    return mcids
}

/// A structure element seen linearly rather than as a tree.
struct PdfFlatStructElement {
    var role: PdfStructRole
    /// Nesting depth, zero at the top level.
    var depth: Int
    var altText: String?
    var contentRefs: [PdfMarkedContentRef]
    /// How many children the element had in the tree, which the flat view
    /// otherwise loses.
    var childCount: Int
}

/// Flatten the tree in document order, each element followed by its subtree.
func pdfFlattenStructElements(_ elements: [PdfStructElement]) -> [PdfFlatStructElement] {
    var out: [PdfFlatStructElement] = []
    func walk(_ elements: [PdfStructElement], depth: Int) {
        for element in elements {
            out.append(
                PdfFlatStructElement(
                    role: element.role, depth: depth, altText: element.altText,
                    contentRefs: element.contentRefs, childCount: element.children.count))
            walk(element.children, depth: depth + 1)
        }
    }
    walk(elements, depth: 0)
    return out
}
