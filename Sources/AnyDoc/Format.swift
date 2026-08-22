/// Input format. Selects the parser; container variants that share a parser
/// (docm, xlsm, ...) map onto these via `Format.detect(from:)` or
/// `Format(extension:)`.
public enum Format: Sendable, Hashable, CaseIterable {
    /// Binary Word 97-2003 (`.doc`).
    case doc
    /// WordprocessingML (`.docx`, `.docm`), both Transitional and Strict.
    case docx
    /// OpenDocument Text (`.odt`).
    case odt
    /// PDF, converted directly to Markdown (no document-model form).
    case pdf
    /// Binary PowerPoint 97-2003 (`.ppt`, `.pps`, `.pot`).
    case ppt
    /// PresentationML (`.pptx`, `.pptm`, `.ppsx`, `.ppsm`).
    case pptx
    /// Rich Text Format (`.rtf`).
    case rtf
    /// EPUB 2 and 3 (`.epub`).
    case epub
    /// Excel workbooks: `.xlsx`, `.xlsm` and binary `.xls`.
    ///
    /// `.xlsb` maps here too, so the extension is recognised rather than
    /// unknown — but its record stream is unported and such a file fails as
    /// malformed. See the note in README.md for why.
    case excel
    /// OpenDocument Spreadsheet (`.ods`).
    case ods
    /// OpenDocument Presentation (`.odp`).
    case odp
    /// Delimiter-separated text (`.csv`). Carries no signature, so it has to
    /// be named rather than detected.
    case csv

    /// Detect the format from the content itself: the signature and identity
    /// each container specification designates (PDF header, RTF open group,
    /// OLE stream names, ZIP package mimetype/content types). Plain-text
    /// formats (CSV) carry no signature and return `nil`; so does anything
    /// unrecognized.
    public static func detect(from bytes: [UInt8]) -> Format? {
        detectFormat(from: bytes)
    }

    /// The format a bare extension names (no leading dot), matched
    /// case-insensitively. `nil` for anything unrecognized.
    public init?(extension ext: String) {
        switch ext.lowercased() {
        case "doc": self = .doc
        case "docx", "docm": self = .docx
        case "odt": self = .odt
        case "pdf": self = .pdf
        case "pptx", "pptm", "ppsx", "ppsm": self = .pptx
        case "ppt", "pps", "pot": self = .ppt
        case "rtf": self = .rtf
        case "epub": self = .epub
        case "xlsx", "xlsm", "xlsb", "xls": self = .excel
        case "ods": self = .ods
        case "odp": self = .odp
        case "csv": self = .csv
        default: return nil
        }
    }

    /// The format a path's extension names. `nil` when the path has no
    /// extension or names nothing recognized.
    public init?(path: String) {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = String(name[name.index(after: dot)...])
        guard !ext.isEmpty else { return nil }
        self.init(extension: ext)
    }
}
