/// SpreadsheetML (`.xlsx`, `.xlsm`) cell extraction.
///
/// anydoc delegates all spreadsheet parsing to the `calamine` crate and uses
/// a narrow slice of it: sheet names, cell values, and merged regions. This
/// is a port of that slice (calamine 0.36.1, MIT) — the shared-string table,
/// the number-format table that decides which numbers are dates, the cell
/// grid, and `mergeCells`. Everything calamine offers beyond that (formulas,
/// defined names, tables, pictures, VBA) is deliberately absent: anydoc never
/// asks for it.

/// A cell value: calamine's `Data`, narrowed to the cases SpreadsheetML can
/// produce.
enum SheetValue {
    case empty
    case string(String)
    case float(Double)
    case bool(Bool)
    /// The reference prints the error's variant name, not its display form.
    case error(String)
    case dateTime(ExcelDateTime)
    case dateTimeIso(String)

    var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }
}

/// A value at a sheet position, both indices zero-based.
struct SheetCell {
    var row: UInt32
    var col: UInt32
    var value: SheetValue
}

/// An inclusive rectangular region, both corners zero-based.
struct SheetRegion {
    var startRow: UInt32
    var startCol: UInt32
    var endRow: UInt32
    var endCol: UInt32
}

/// A workbook opened far enough to know its sheets, strings, and formats.
struct XlsxWorkbook {
    private let package: Package
    /// Folder holding `workbook.xml`, usually `xl/`.
    private let xlPath: String
    private let strings: [String]
    /// Cell formats indexed by a cell's `s` attribute (the `cellXfs` order).
    private let formats: [CellFormat]
    private let is1904: Bool
    /// Entry names indexed by their lowercased, slash-normalized form: the
    /// reference matches part paths case-insensitively, so a producer writing
    /// `xl/SharedStrings.xml` is still read.
    private let entryIndex: [String: String]
    /// Sheet names in workbook order, with their part paths.
    let sheets: [(name: String, path: String)]

    /// Open a workbook. Throws `ConvertError` when the package is not a
    /// readable SpreadsheetML workbook.
    ///
    /// A corrupt string or style table fails the *open*, as it does in the
    /// reference: those tables decide what every cell in the workbook says,
    /// so carrying on without them would silently render the wrong document.
    /// Absent ones are fine — both parts are optional.
    init(bytes: [UInt8]) throws {
        let package = try Package.open(bytes)
        self.package = package
        var entryIndex: [String: String] = [:]
        for name in package.entryNames {
            entryIndex[name.replacingBackslashes().lowercasedAscii()] = name
        }
        self.entryIndex = entryIndex

        // The office-document relationship names the workbook part; every
        // other part path is resolved against its folder.
        guard let rels = try readXmlPart(package, entryIndex, "_rels/.rels") else {
            throw ConvertError.malformed("unreadable workbook: relationship not found")
        }
        var documentTarget: String?
        for rel in (rootElement(rels)?.childElements ?? []) where rel.local == "Relationship" {
            guard let type = rel.attrUnqualified("Type"),
                type.hasSuffix("/relationships/officeDocument")
            else { continue }
            if let target = rel.attrUnqualified("Target") {
                documentTarget = target
            }
        }
        guard let documentTarget else {
            throw ConvertError.malformed("unreadable workbook: relationship not found")
        }
        self.xlPath = folderOf(documentTarget)

        self.strings = try XlsxWorkbook.readSharedStrings(package, entryIndex, xlPath)
        self.formats = try XlsxWorkbook.readStyles(package, entryIndex, xlPath)

        // Sheet part paths come from the workbook's own relationship part; an
        // absolute target escapes the workbook folder, a relative one does not.
        guard let workbookRels = try readXmlPart(
            package, entryIndex, "\(xlPath)_rels/workbook.xml.rels")
        else {
            throw ConvertError.malformed(
                "unreadable workbook: \(xlPath)_rels/workbook.xml.rels not found")
        }
        var relationships: [String: (target: String, type: String)] = [:]
        for rel in (rootElement(workbookRels)?.childElements ?? []) where rel.local == "Relationship" {
            guard let id = rel.attrUnqualified("Id") else { continue }
            relationships[id] = (
                target: rel.attrUnqualified("Target") ?? "",
                type: rel.attrUnqualified("Type") ?? ""
            )
        }

        guard let workbook = try readXmlPart(package, entryIndex, "\(xlPath)workbook.xml") else {
            throw ConvertError.malformed("unreadable workbook: \(xlPath)workbook.xml not found")
        }
        var sheets: [(name: String, path: String)] = []
        var is1904 = false
        for element in workbook.descendantsAny("sheet") {
            let name = element.attrUnqualified("name") ?? ""
            let relId = element.attrAny("id") ?? ""
            guard let relationship = relationships[relId] else {
                throw ConvertError.malformed("unreadable workbook: relationship not found")
            }
            let path = relationship.target.hasPrefix("/")
                ? String(relationship.target.dropFirst())
                : xlPath + relationship.target
            // Chart and dialog sheets are legal here; they simply hold no cells.
            let kind = relationship.type.split(separator: "/").last.map(String.init) ?? ""
            guard kind == "worksheet" || kind == "chartsheet" || kind == "dialogsheet" else {
                throw ConvertError.malformed("unreadable workbook: Unrecognized sheet:type: \(path)")
            }
            sheets.append((name: name, path: path))
        }
        if let pr = workbook.descendantsAny("workbookPr").first,
            let date1904 = pr.attrUnqualified("date1904")
        {
            is1904 = date1904 == "1" || date1904 == "true"
        }
        self.sheets = sheets
        self.is1904 = is1904
    }

    private static func readSharedStrings(
        _ package: Package, _ entryIndex: [String: String], _ xlPath: String
    ) throws -> [String] {
        guard let sst = try readXmlPart(package, entryIndex, "\(xlPath)sharedStrings.xml") else {
            return []
        }
        return (rootElement(sst)?.childElements ?? []).filter { $0.local == "si" }.map(readSharedString)
    }

    private static func readStyles(
        _ package: Package, _ entryIndex: [String: String], _ xlPath: String
    ) throws -> [CellFormat] {
        guard let styles = try readXmlPart(package, entryIndex, "\(xlPath)styles.xml") else {
            return []
        }
        var numberFormats: [String: String] = [:]
        let styleSheet = rootElement(styles)?.childElements ?? []
        for numFmts in styleSheet where numFmts.local == "numFmts" {
            for numFmt in numFmts.childElements where numFmt.local == "numFmt" {
                if let id = numFmt.attrUnqualified("numFmtId"),
                    let code = numFmt.attrUnqualified("formatCode")
                {
                    numberFormats[id] = code
                }
            }
        }
        var formats: [CellFormat] = []
        for cellXfs in styleSheet where cellXfs.local == "cellXfs" {
            for xf in cellXfs.childElements where xf.local == "xf" {
                guard let id = xf.attrUnqualified("numFmtId") else {
                    formats.append(.other)
                    continue
                }
                // A custom code overrides a reserved id of the same number.
                formats.append(
                    numberFormats[id].map(detectCustomNumberFormat) ?? builtinFormatById(id))
            }
        }
        return formats
    }

    /// Every non-empty cell of a sheet, in document order. Throws when the
    /// part cannot be read; returns an empty array for a part that holds no
    /// `sheetData` at all (a chart sheet), which the reference reports as
    /// "not a worksheet" and treats as an empty range rather than a failure.
    func cells(ofSheetAt path: String) throws -> [SheetCell] {
        guard let sheet = try readXmlPart(package, entryIndex, path) else {
            throw ConvertError.malformedPart(path, "worksheet part not found")
        }
        guard let sheetData = rootElement(sheet)?.childElements.first(where: { $0.local == "sheetData" })
        else {
            return []
        }
        var cells: [SheetCell] = []
        var rowIndex: UInt32 = 0
        for row in sheetData.childElements {
            guard row.local == "row" else { continue }
            if let r = row.attrUnqualified("r") {
                guard let parsed = parseRowReference(r) else {
                    throw ConvertError.malformedPart(path, "row reference without a row component")
                }
                rowIndex = parsed
            }
            var colIndex: UInt32 = 0
            for c in row.childElements {
                guard c.local == "c" else { continue }
                var position = (row: rowIndex, col: colIndex)
                if let r = c.attrUnqualified("r") {
                    guard let parsed = parseCellReference(r) else {
                        throw ConvertError.malformedPart(
                            path, "cell reference \(rustDebugString(r)) is not a position")
                    }
                    position = parsed
                    colIndex = parsed.col
                }
                let value = try readCellValue(c, path: path)
                if !value.isEmpty {
                    cells.append(SheetCell(row: position.row, col: position.col, value: value))
                }
                colIndex &+= 1
            }
            rowIndex &+= 1
        }
        return cells
    }

    /// A cell's value. The `t` attribute names the type; `s` selects the
    /// number format that decides whether a number is really a date.
    private func readCellValue(_ c: XmlElement, path: String) throws -> SheetValue {
        let type = c.attrUnqualified("t")
        var value = SheetValue.empty
        for child in c.childElements {
            switch child.local {
            case "is":
                value = .string(XlsxWorkbook.readSharedString(child))
            case "v":
                // An inline-string cell's <v> is a redundant cache of the <is>.
                if type == "inlineStr" || type == "is" { continue }
                value = try readTypedValue(child.text(), style: c.attrUnqualified("s"), type: type,
                    path: path)
            case "f":
                continue
            default:
                throw ConvertError.malformedPart(
                    path, "unexpected node in a cell: expected v, f, or is")
            }
        }
        return value
    }

    private func readTypedValue(
        _ text: String, style: String?, type: String?, path: String
    ) throws -> SheetValue {
        // No style attribute means the general format, which is never a date.
        // An unparseable index — negative, overflowing, not a number — falls
        // back to the first format rather than to no format.
        let format: CellFormat
        if let style {
            format = formats[safe: UInt(style).flatMap { Int(exactly: $0) } ?? 0] ?? .other
        } else {
            format = .other
        }
        switch type {
        case "s":
            if text.isEmpty { return .empty }
            let index = Int(text) ?? 0
            guard let string = strings[safe: index] else {
                throw ConvertError.malformedPart(
                    path, "cell string index not found in shared strings table")
            }
            return .string(string)
        case "b":
            return .bool(text != "0")
        case "d":
            return .dateTimeIso(text)
        case "e":
            guard let name = cellErrorVariantName(text) else {
                throw ConvertError.malformedPart(
                    path, "unsupported cell error value '\(text)'")
            }
            return .error(name)
        case "str":
            return .string(text)
        case "n", nil:
            if text.isEmpty { return .empty }
            guard parsesAsRustF64(text), let number = Double(text) else {
                // An untyped cell that is not a number is text; a cell that
                // claims to be numeric and is not is malformed.
                if type == nil { return .string(text) }
                throw ConvertError.malformedPart(
                    path, "cell value \(rustDebugString(text)) is not a number")
            }
            switch format {
            case .dateTime:
                return .dateTime(ExcelDateTime(value: number, isDuration: false, is1904: is1904))
            case .timeDelta:
                return .dateTime(ExcelDateTime(value: number, isDuration: true, is1904: is1904))
            case .other:
                return .float(number)
            }
        case .some(let t):
            throw ConvertError.malformedPart(path, "unsupported cell type '\(t)'")
        }
    }

    /// The merged regions a sheet declares. Absent or unreadable regions are
    /// not an error: the sheet still renders, just without spans.
    func mergedRegions(ofSheetAt path: String) throws -> [SheetRegion] {
        guard let sheet = try readXmlPart(package, entryIndex, path) else { return [] }
        guard let mergeCells = rootElement(sheet)?.childElements.first(where: { $0.local == "mergeCells" })
        else { return [] }
        var regions: [SheetRegion] = []
        for mergeCell in mergeCells.childElements where mergeCell.local == "mergeCell" {
            guard let reference = mergeCell.attrUnqualified("ref") else { continue }
            guard let region = parseRegionReference(reference) else {
                throw ConvertError.malformedPart(
                    path, "merged region \(rustDebugString(reference)) is not a range")
            }
            regions.append(region)
        }
        return regions
    }

    /// A shared string or an inline string: plain `<t>`, or the concatenated
    /// `<t>` runs of a rich-text string. Phonetic guide text (`<rPh>`) is
    /// pronunciation help, not content, and is dropped.
    private static func readSharedString(_ element: XmlElement) -> String {
        var out = ""
        func walk(_ node: XmlElement, inPhonetic: Bool) {
            for child in node.childElements {
                switch child.local {
                case "rPh":
                    walk(child, inPhonetic: true)
                case "t" where !inPhonetic:
                    let preserved = child.attrQualified(Ns.xml, "space") == "preserve"
                    let raw = child.text()
                    // Unmarked edges lose XML whitespace only: a no-break
                    // space is content.
                    out += decodeOoxmlEscapes(preserved ? raw : String(trimXmlSpace(raw)))
                default:
                    walk(child, inPhonetic: inPhonetic)
                }
            }
        }
        walk(element, inPhonetic: false)
        return out
    }
}

/// The reference prints a cell error as its variant name, not its Excel
/// spelling, so `#REF!` renders as `#Ref`.
private func cellErrorVariantName(_ text: String) -> String? {
    switch text {
    case "#DIV/0!": return "Div0"
    case "#N/A": return "NA"
    case "#NAME?": return "Name"
    case "#NULL!": return "Null"
    case "#NUM!": return "Num"
    case "#REF!": return "Ref"
    case "#VALUE!": return "Value"
    default: return nil
    }
}

/// Excel escapes characters XML cannot carry as `_x00HH_`, and escapes that
/// literal in turn as `_x005F_x00HH_`.
func decodeOoxmlEscapes(_ text: String) -> String {
    guard text.contains("_x00") else { return text }
    let bytes = Array(text.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        if i + 7 <= bytes.count, bytes[i] == UInt8(ascii: "_"),
            bytes[i + 1] == UInt8(ascii: "x"), bytes[i + 2] == UInt8(ascii: "0"),
            bytes[i + 3] == UInt8(ascii: "0"), bytes[i + 6] == UInt8(ascii: "_"),
            let high = hexDigitValue(bytes[i + 4]), let low = hexDigitValue(bytes[i + 5])
        {
            // The escape names a code point, so it re-encodes as UTF-8.
            out.append(contentsOf: Array(String(Unicode.Scalar(high * 16 + low)).utf8))
            i += 7
            continue
        }
        out.append(bytes[i])
        i += 1
    }
    return String(decoding: out, as: UTF8.self)
}

private func hexDigitValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
    default: return nil
    }
}

/// Read and parse an optional part, resolving its name case-insensitively.
/// `nil` means the part is absent; a part that exists but does not parse
/// throws, because the reference treats it as a failed workbook open.
private func readXmlPart(
    _ package: Package, _ entryIndex: [String: String], _ path: String
) throws -> XmlElement? {
    let resolved = entryIndex[path.replacingBackslashes().lowercasedAscii()] ?? path
    guard let bytes = try package.part(resolved) else { return nil }
    return try parseXml(bytes)
}

extension String {
    /// ASCII-only case folding, matching the reference's `to_ascii_lowercase`.
    func lowercasedAscii() -> String {
        String(decoding: utf8.map(asciiLower), as: UTF8.self)
    }

    /// ZIP entry names may use the DOS separator; part paths never do.
    func replacingBackslashes() -> String {
        String(decoding: utf8.map { $0 == UInt8(ascii: "\\") ? UInt8(ascii: "/") : $0 },
            as: UTF8.self)
    }
}

/// `parseXml` hands back a synthetic document node holding the prolog and
/// the root element; parts addressed by their top-level children start here.
private func rootElement(_ document: XmlElement) -> XmlElement? {
    document.childElements.first
}

/// The folder part of a package path, with any leading slash dropped:
/// `xl/workbook.xml` -> `xl/`, `workbook.xml` -> ``.
private func folderOf(_ target: String) -> String {
    guard let slash = target.lastIndex(of: "/") else { return "" }
    let folder = target[...slash]
    return folder.hasPrefix("/") ? String(folder.dropFirst()) : String(folder)
}

/// Parse an `A1`-style reference into a zero-based `(row, column)`. Letters
/// are base-26 with no zero digit; a missing row or column is a failure.
func parseCellReference(_ reference: String) -> (row: UInt32, col: UInt32)? {
    guard let (row, col) = parseReferenceParts(reference), let col else { return nil }
    return (row, col)
}

/// Parse the row of a reference, ignoring any column component (`<row r="11">`).
func parseRowReference(_ reference: String) -> UInt32? {
    parseReferenceParts(reference)?.row
}

/// Parse a `A1:B2` region. A single reference denotes a one-cell region.
func parseRegionReference(_ reference: String) -> SheetRegion? {
    let parts = reference.split(separator: ":", omittingEmptySubsequences: false)
    let corners = parts.map { parseCellReference(String($0)) }
    guard !corners.contains(where: { $0 == nil }) else { return nil }
    switch corners.count {
    case 1:
        let only = corners[0]!
        return SheetRegion(
            startRow: only.row, startCol: only.col, endRow: only.row, endCol: only.col)
    case 2:
        let (start, end) = (corners[0]!, corners[1]!)
        // The reference subtracts the corners, which traps on an inverted
        // range; reject it here rather than materializing a negative extent.
        guard end.row >= start.row, end.col >= start.col else { return nil }
        return SheetRegion(
            startRow: start.row, startCol: start.col, endRow: end.row, endCol: end.col)
    default:
        return nil
    }
}

private func parseReferenceParts(_ reference: String) -> (row: UInt32, col: UInt32?)? {
    var col: UInt32 = 0
    var row: UInt32 = 0
    let bytes = Array(reference.utf8)
    var i = 0
    // Letters first: base-26 with no zero digit (A=1, ..., Z=26, AA=27).
    // Arithmetic wraps rather than traps, as it does in the reference's
    // release build — a wrapped column is nonsense but never a crash.
    while i < bytes.count {
        let byte = bytes[i]
        if (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
        {
            col = col &* 26 &+ UInt32(asciiLower(byte) - UInt8(ascii: "a")) &+ 1
        } else if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
            row = UInt32(byte - UInt8(ascii: "0"))
            i += 1
            break
        } else {
            return nil
        }
        i += 1
    }
    // Then digits: anything but a digit from here on is malformed, so a
    // column letter cannot follow the row.
    while i < bytes.count {
        let byte = bytes[i]
        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
        row = row &* 10 &+ UInt32(byte - UInt8(ascii: "0"))
        i += 1
    }
    // Both components are one-based in the file and zero-based here; a
    // reference without a row component is not a position.
    guard row >= 1 else { return nil }
    return (row - 1, col == 0 ? nil : col - 1)
}

extension Array {
    /// Rust's `slice::get`: `nil` rather than a trap for an out-of-range index.
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
