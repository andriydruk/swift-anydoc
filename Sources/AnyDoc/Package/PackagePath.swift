/// Package target resolution per OPC/EPUB URI semantics, applied before any
/// archive lookup.
///
/// The reference is treated as a URI: fragment and query split off first,
/// then each path segment is percent-decoded *after* segmentation. A segment
/// whose decoded form would introduce structure (`/`, `\`, `.`, `..`) is
/// rejected — encoded traversal never becomes path structure.

struct PackageTarget: Equatable {
    /// Normalized archive path (no leading slash).
    var path: String
    var fragment: String?
}

/// Resolve a relative or package-absolute reference against the part it
/// appears in.
func resolvePackageReference(basePart: String, reference: String) throws -> PackageTarget {
    var reference = Substring(reference)
    var fragment: String? = nil
    if let hash = reference.firstIndex(of: "#") {
        fragment = decodeComponent(reference[reference.index(after: hash)...])
        reference = reference[..<hash]
    }
    if let query = reference.firstIndex(of: "?") {
        reference = reference[..<query]
    }
    if reference.isEmpty {
        // Fragment-only reference: the target is the base part itself.
        return PackageTarget(path: basePart, fragment: fragment)
    }

    var segments: [String] = []
    if reference.first != "/" {
        // Start from the base part's directory.
        if let slash = basePart.lastIndex(of: "/") {
            segments = basePart[..<slash].split(separator: "/").map(String.init)
        }
    }
    for raw in reference.split(separator: "/", omittingEmptySubsequences: false) {
        switch raw {
        case "", ".":
            break
        case "..":
            // Dot segments resolve against the base, clamped at the
            // package root (a traversal above root is producer sloppiness
            // in the wild; clamping preserves OPC behavior).
            if !segments.isEmpty {
                segments.removeLast()
            }
        default:
            let decoded = decodeComponent(raw)
            if decoded.contains("/") || decoded.contains("\\") {
                throw ConvertError.malformed(
                    "percent-encoded separator in package reference segment \(rustDebugQuoted(raw))")
            }
            if decoded == "." || decoded == ".." {
                throw ConvertError.malformed(
                    "percent-encoded traversal in package reference segment \(rustDebugQuoted(raw))")
            }
            segments.append(decoded)
        }
    }
    return PackageTarget(path: segments.joined(separator: "/"), fragment: fragment)
}

/// Percent-decode one URI component. Infallible by design: a `%` not
/// followed by two hex digits passes through literally (producers emit such
/// names), and non-UTF-8 decoded bytes degrade lossily - the result is only
/// ever matched against archive entry names, where a near-miss simply fails
/// the lookup.
private func decodeComponent(_ component: some StringProtocol) -> String {
    let bytes = Array(component.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count,
            isAsciiHexDigit(bytes[i + 1]), isAsciiHexDigit(bytes[i + 2])
        {
            out.append(hexValue(bytes[i + 1]) << 4 | hexValue(bytes[i + 2]))
            i += 3
            continue
        }
        out.append(bytes[i])
        i += 1
    }
    return String(decoding: out, as: UTF8.self)
}

func decodeFragment(_ fragment: String) -> String {
    decodeComponent(fragment)
}

private func isAsciiHexDigit(_ b: UInt8) -> Bool {
    (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
        || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "f"))
        || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "F"))
}

private func hexValue(_ b: UInt8) -> UInt8 {
    if b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") {
        return b - UInt8(ascii: "0")
    }
    return (asciiLower(b) - UInt8(ascii: "a")) + 10
}

/// Rust `{:?}` formatting of a `str`: double-quoted, with backslash, quote,
/// and control characters escaped the way `char::escape_debug` renders them.
func rustDebugQuoted(_ text: some StringProtocol) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\0": out += "\\0"
        default:
            if scalar.isRustControl || scalar.properties.generalCategory == .format
                || scalar.properties.generalCategory == .unassigned
            {
                out += "\\u{\(String(scalar.value, radix: 16))}"
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
    return out
}
