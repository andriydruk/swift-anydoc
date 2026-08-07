/// Shared package layer for ZIP-based formats (DOCX, PPTX, ODF, EPUB):
/// limited archive access (`Package` in Archive.swift over the raw reader in
/// Zip.swift), namespace-aware XML (Xml.swift), typed relationships
/// (Relationships.swift), and OPC/EPUB target resolution (PackagePath.swift).

/// Rust `str::eq_ignore_ascii_case`: byte-wise comparison folding ASCII
/// letters only. OPC part names, content types, and OLE stream names all
/// compare this way.
func eqIgnoreAsciiCase(_ a: some StringProtocol, _ b: some StringProtocol) -> Bool {
    var ai = a.utf8.makeIterator()
    var bi = b.utf8.makeIterator()
    while true {
        switch (ai.next(), bi.next()) {
        case (nil, nil):
            return true
        case (let x?, let y?):
            if asciiLower(x) != asciiLower(y) {
                return false
            }
        default:
            return false
        }
    }
}

func asciiLower(_ byte: UInt8) -> UInt8 {
    byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte &+ 32 : byte
}
