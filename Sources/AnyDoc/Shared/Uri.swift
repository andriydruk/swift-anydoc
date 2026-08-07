/// URI classification shared across frontends (EPUB hrefs, ODF hrefs and
/// image references, Word field targets).

/// True when `s` starts with an RFC 3986 scheme followed by `:`
/// (`scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`). One-character
/// schemes are valid.
func hasScheme(_ s: String) -> Bool {
    let scalars = Array(s.unicodeScalars)
    guard let colon = scalars.firstIndex(of: ":") else {
        return false
    }
    let prefix = scalars[..<colon]
    guard let first = prefix.first, first.isAsciiAlphabetic else { return false }
    return prefix.dropFirst().allSatisfy { c in
        c.isAsciiAlphanumeric || c == "+" || c == "-" || c == "."
    }
}

/// True for Windows drive-letter paths (`C:\...`, `C:/...`). They parse as
/// a one-letter scheme under RFC 3986, but in documents they are local file
/// paths (legacy Word HYPERLINK fields), never URIs.
func isDrivePath(_ s: String) -> Bool {
    let b = Array(s.utf8)
    guard b.count >= 3 else { return false }
    let alpha = (b[0] >= 0x41 && b[0] <= 0x5A) || (b[0] >= 0x61 && b[0] <= 0x7A)
    return alpha && b[1] == UInt8(ascii: ":") && (b[2] == UInt8(ascii: "\\") || b[2] == UInt8(ascii: "/"))
}

/// True when `s` should be treated as an absolute URI with a scheme rather
/// than a relative/package reference.
func isAbsoluteUri(_ s: String) -> Bool {
    hasScheme(s) && !isDrivePath(s)
}
