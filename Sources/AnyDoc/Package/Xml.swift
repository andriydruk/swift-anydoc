/// Namespace-aware DOM built on an in-repo streaming parser (port of
/// anydoc's `package/xml.rs`, which wraps quick-xml; this file replicates the
/// quick-xml behaviors that wrapper relies on).
///
/// Parses from bytes so BOMs and encoding declarations are honored. Element
/// and attribute names carry their resolved namespace URI. Depth and node
/// caps are enforced during parsing; recoverable malformations (unclosed or
/// mismatched tags) are repaired deliberately and logged, never silently.

/// Well-known namespace URIs.
enum Ns {
    static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
    static let wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    static let mc = "http://schemas.openxmlformats.org/markup-compatibility/2006"
    static let chart = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    static let dgm = "http://schemas.openxmlformats.org/drawingml/2006/diagram"
    static let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let pkgRels = "http://schemas.openxmlformats.org/package/2006/relationships"

    static let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    static let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    static let table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    static let draw = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
    static let style = "urn:oasis:names:tc:opendocument:xmlns:style:1.0"
    static let fo = "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
    static let presentation = "urn:oasis:names:tc:opendocument:xmlns:presentation:1.0"
    static let manifest = "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"
    static let xlink = "http://www.w3.org/1999/xlink"
    static let xml = "http://www.w3.org/XML/1998/namespace"
    static let svgCompat = "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"

    static let vml = "urn:schemas-microsoft-com:vml"
    static let oVml = "urn:schemas-microsoft-com:office:office"
    static let wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
    static let wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
}

enum XmlNode {
    case elem(XmlElement)
    case text(String)
}

struct XmlElement {
    /// Resolved namespace URI; `nil` for unqualified names.
    var ns: String?
    var local: String
    var attrs: [XmlAttr]
    var children: [XmlNode]
}

struct XmlAttr {
    var ns: String?
    var local: String
    var value: String
}

extension XmlElement {
    func named(_ ns: String, _ local: String) -> Bool {
        self.local == local && self.ns == ns
    }

    /// Same-vocabulary attribute lookup: the qualified attribute wins, and an
    /// explicitly unqualified one with the same local name is accepted as a
    /// deliberate leniency — schemas often leave their own attributes
    /// unqualified and producers vary. Lookups in a *different* vocabulary
    /// than the element's (`r:id`, `xml:id`) must use `attrQualified`, where
    /// that fallback would misattribute.
    func attr(_ ns: String, _ local: String) -> String? {
        attrQualified(ns, local) ?? attrUnqualified(local)
    }

    /// Strictly namespace-qualified attribute lookup, no fallback.
    func attrQualified(_ ns: String, _ local: String) -> String? {
        attrs.first(where: { $0.local == local && $0.ns == ns })?.value
    }

    /// Explicitly unqualified attribute lookup (no namespace), no fallback.
    func attrUnqualified(_ local: String) -> String? {
        attrs.first(where: { $0.local == local && $0.ns == nil })?.value
    }

    /// Attribute by local name regardless of namespace. For elements whose
    /// vocabulary is unambiguous in context (relationships, container files).
    func attrAny(_ local: String) -> String? {
        attrs.first(where: { $0.local == local })?.value
    }

    var childElements: [XmlElement] {
        children.compactMap { node in
            if case .elem(let e) = node { return e }
            return nil
        }
    }

    func find(_ ns: String, _ local: String) -> XmlElement? {
        childElements.first(where: { $0.named(ns, local) })
    }

    func findAll(_ ns: String, _ local: String) -> [XmlElement] {
        childElements.filter { $0.named(ns, local) }
    }

    /// Visit all descendant nodes (elements and text), depth-first in
    /// document order, iteratively (deep DOMs must not overflow the call
    /// stack). Return `false` from the visitor to stop early.
    func visitDescendantNodes(_ visit: (XmlNode) -> Bool) {
        var stack: [XmlNode] = children.reversed()
        while let node = stack.popLast() {
            if !visit(node) {
                return
            }
            if case .elem(let e) = node {
                stack.append(contentsOf: e.children.reversed())
            }
        }
    }

    /// All descendant elements, depth-first in document order.
    var descendantElements: [XmlElement] {
        var out: [XmlElement] = []
        visitDescendantNodes { node in
            if case .elem(let e) = node { out.append(e) }
            return true
        }
        return out
    }

    /// First descendant with the given name, depth-first.
    func firstDescendant(_ ns: String, _ local: String) -> XmlElement? {
        var found: XmlElement? = nil
        visitDescendantNodes { node in
            if case .elem(let e) = node, e.named(ns, local) {
                found = e
                return false
            }
            return true
        }
        return found
    }

    /// All descendants with the given name, in document order.
    func descendants(_ ns: String, _ local: String) -> [XmlElement] {
        descendantElements.filter { $0.named(ns, local) }
    }

    /// All descendants matching a local name regardless of namespace, in
    /// document order. For vocabularies where the namespace varies across
    /// producers (EPUB container/OPF metadata).
    func descendantsAny(_ local: String) -> [XmlElement] {
        descendantElements.filter { $0.local == local }
    }

    /// Concatenated text of all descendant text nodes.
    func text() -> String {
        var out = ""
        visitDescendantNodes { node in
            if case .text(let t) = node { out += t }
            return true
        }
        return out
    }
}

/// ISO/IEC 29500 *Strict* namespace and relationship-type URIs are the
/// Transitional ones re-rooted under `http://purl.oclc.org/ooxml/` with the
/// `2006` version segment dropped. Normalizing to the Transitional family at
/// parse time lets the rest of the library match a single set of constants.
func normalizeOoxmlUri(_ uri: String) -> String? {
    guard uri.hasPrefix("http://purl.oclc.org/ooxml/") else { return nil }
    let rest = uri.dropFirst("http://purl.oclc.org/ooxml/".count)
    guard let slash = rest.firstIndex(of: "/") else { return nil }
    let family = rest[..<slash]
    let tail = rest[rest.index(after: slash)...]
    return "http://schemas.openxmlformats.org/\(family)/2006/\(tail)"
}

/// Parse an XML part into a synthetic root element containing the top-level
/// nodes. Encoding comes from the BOM or XML declaration; the part is
/// transcoded to UTF-8 before parsing so namespace resolution sees one
/// consistent encoding.
func parseXml(_ bytes: [UInt8]) throws -> XmlElement {
    var parser = XmlParser(bytes: xmlToUtf8(bytes))
    return try parser.parse()
}

/// Transcode an XML part to UTF-8 based on its BOM or encoding declaration.
private func xmlToUtf8(_ bytes: [UInt8]) -> [UInt8] {
    if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
        return Array(decodeUtf16(bytes[...], littleEndian: true).utf8)
    }
    if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
        return Array(decodeUtf16(bytes[...], littleEndian: false).utf8)
    }
    if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
        return Array(bytes[3...])
    }
    // Sniff a non-UTF-8 encoding declaration in the XML prolog.
    let head = bytes[..<min(bytes.count, 200)]
    if let label = declaredEncoding(head) {
        switch encodingForLabel(label) {
        case .utf8, .none:
            break
        case .utf16le:
            return Array(decodeUtf16(bytes[...], littleEndian: true).utf8)
        case .utf16be:
            return Array(decodeUtf16(bytes[...], littleEndian: false).utf8)
        case .windows1252:
            return Array(decodeWindows1252(bytes[...]).utf8)
        }
    }
    return bytes
}

private enum SniffedEncoding {
    case utf8, utf16le, utf16be, windows1252
}

/// The WHATWG label subset the corpus exercises. Labels outside this set are
/// left undecoded (a divergence from encoding_rs's full table, logged).
private func encodingForLabel(_ label: String) -> SniffedEncoding? {
    switch label.rustTrim().lowercased() {
    case "utf-8", "utf8", "unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "x-unicode20utf8":
        return .utf8
    case "utf-16", "utf-16le", "unicodefeff", "csunicode", "iso-10646-ucs-2", "ucs-2", "unicode":
        return .utf16le
    case "utf-16be", "unicodefffe":
        return .utf16be
    case "windows-1252", "cp1252", "x-cp1252", "ansi_x3.4-1968", "ascii", "us-ascii",
        "cp819", "csisolatin1", "ibm819", "iso-8859-1", "iso-ir-100", "iso8859-1",
        "iso88591", "iso_8859-1", "iso_8859-1:1987", "l1", "latin1":
        return .windows1252
    default:
        Log.warn("undecodable xml encoding label: \(label)")
        return nil
    }
}

private func declaredEncoding(_ head: ArraySlice<UInt8>) -> String? {
    guard let text = validateUtf8(head) else { return nil }
    guard let range = text.firstRange(of: "encoding") else { return nil }
    var rest = Substring(text[range.upperBound...]).rustTrimStartSub()
    guard rest.first == "=" else { return nil }
    rest = rest.dropFirst().rustTrimStartSub()
    guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
    rest = rest.dropFirst()
    guard let end = rest.firstIndex(of: quote) else { return nil }
    return String(rest[..<end])
}

/// Streaming XML parser mirroring the quick-xml behaviors anydoc relies on:
/// end-tag names unchecked (mismatches repaired and logged), entities
/// surfaced as reference events (`resolveEntity`), attribute values
/// normalized per XML 1.0 with raw fallback on unresolvable entities, and
/// namespace declarations consumed by scope-aware resolution.
private struct XmlParser {
    let bytes: [UInt8]
    var pos = 0
    var nodes = 0
    var recovered = false
    /// Namespace scopes: each frame holds the prefixes (re)bound by one open
    /// element; `""` is the default namespace, a `nil` URI unbinds.
    var scopes: [[(prefix: String, uri: String?)]] = []
    var stack: [XmlElement] = []
    var root = XmlElement(ns: nil, local: "", attrs: [], children: [])

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parse() throws -> XmlElement {
        while pos < bytes.count {
            if bytes[pos] == UInt8(ascii: "<") {
                try parseMarkup()
            } else {
                try parseTextRun()
            }
        }
        if !stack.isEmpty {
            recovered = true
            while let elem = stack.popLast() {
                attach(.elem(elem))
            }
        }
        if recovered {
            Log.warn("recovered malformed xml (unclosed or mismatched elements)")
        }
        return root
    }

    private mutating func attach(_ node: XmlNode) {
        if stack.isEmpty {
            root.children.append(node)
        } else {
            stack[stack.count - 1].children.append(node)
        }
    }

    private mutating func pushText(_ text: String) {
        let target: Int? = stack.isEmpty ? nil : stack.count - 1
        if let t = target {
            if case .text(let prev) = stack[t].children.last {
                stack[t].children[stack[t].children.count - 1] = .text(prev + text)
                return
            }
            stack[t].children.append(.text(text))
        } else {
            if case .text(let prev) = root.children.last {
                root.children[root.children.count - 1] = .text(prev + text)
                return
            }
            root.children.append(.text(text))
        }
    }

    private mutating func bumpNodes() throws {
        nodes += 1
        if nodes > Limits.maxXmlNodes {
            throw ConvertError.resourceLimit(
                limit: "max_xml_nodes",
                detail: "part exceeds \(Limits.maxXmlNodes) xml nodes")
        }
    }

    // MARK: text and references

    private mutating func parseTextRun() throws {
        let start = pos
        while pos < bytes.count, bytes[pos] != UInt8(ascii: "<"), bytes[pos] != UInt8(ascii: "&") {
            pos += 1
        }
        if pos > start {
            let text = String(decoding: bytes[start..<pos], as: UTF8.self)
            if !text.isEmpty {
                try bumpNodes()
                pushText(text)
            }
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "&") {
            try parseReference()
        }
    }

    private mutating func parseReference() throws {
        let start = pos + 1
        var i = start
        while i < bytes.count, bytes[i] != UInt8(ascii: ";"), bytes[i] != UInt8(ascii: "<") {
            i += 1
        }
        guard i < bytes.count, bytes[i] == UInt8(ascii: ";") else {
            throw ConvertError.malformed("unparseable xml: unclosed entity reference")
        }
        let name = String(decoding: bytes[start..<i], as: UTF8.self)
        pos = i + 1
        let resolved = resolveEntity(name) ?? "&\(name);"
        try bumpNodes()
        pushText(resolved)
    }

    // MARK: markup dispatch

    private mutating func parseMarkup() throws {
        // pos is at '<'.
        guard pos + 1 < bytes.count else {
            throw ConvertError.malformed("unparseable xml: unexpected eof after '<'")
        }
        switch bytes[pos + 1] {
        case UInt8(ascii: "?"):
            try skipProcessingInstruction()
        case UInt8(ascii: "!"):
            try parseDeclaration()
        case UInt8(ascii: "/"):
            parseEndTag()
        default:
            try parseStartTag()
        }
    }

    private mutating func skipProcessingInstruction() throws {
        var i = pos + 2
        while i + 1 < bytes.count {
            if bytes[i] == UInt8(ascii: "?"), bytes[i + 1] == UInt8(ascii: ">") {
                pos = i + 2
                return
            }
            i += 1
        }
        throw ConvertError.malformed("unparseable xml: unterminated processing instruction")
    }

    private mutating func parseDeclaration() throws {
        if matchesAt(pos, "<!--") {
            var i = pos + 4
            while i + 2 < bytes.count {
                if bytes[i] == UInt8(ascii: "-"), bytes[i + 1] == UInt8(ascii: "-"),
                    bytes[i + 2] == UInt8(ascii: ">")
                {
                    pos = i + 3
                    return
                }
                i += 1
            }
            throw ConvertError.malformed("unparseable xml: unterminated comment")
        }
        if matchesAt(pos, "<![CDATA[") {
            var i = pos + 9
            while i + 2 < bytes.count {
                if bytes[i] == UInt8(ascii: "]"), bytes[i + 1] == UInt8(ascii: "]"),
                    bytes[i + 2] == UInt8(ascii: ">")
                {
                    let text = String(decoding: bytes[(pos + 9)..<i], as: UTF8.self)
                    pos = i + 3
                    try bumpNodes()
                    pushText(text)
                    return
                }
                i += 1
            }
            throw ConvertError.malformed("unparseable xml: unterminated cdata section")
        }
        // DOCTYPE or another `<!` directive: skip, tracking the internal
        // subset's brackets.
        var depth = 0
        var i = pos + 2
        while i < bytes.count {
            switch bytes[i] {
            case UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "]"): depth = max(0, depth - 1)
            case UInt8(ascii: ">") where depth == 0:
                pos = i + 1
                return
            default: break
            }
            i += 1
        }
        throw ConvertError.malformed("unparseable xml: unterminated markup declaration")
    }

    private func matchesAt(_ at: Int, _ literal: String) -> Bool {
        let lit = Array(literal.utf8)
        guard at + lit.count <= bytes.count else { return false }
        for (i, b) in lit.enumerated() where bytes[at + i] != b {
            return false
        }
        return true
    }

    // MARK: tags

    private mutating func parseEndTag() {
        var i = pos + 2
        let nameStart = i
        while i < bytes.count, bytes[i] != UInt8(ascii: ">") {
            i += 1
        }
        // The end tag's qualified name runs to the first whitespace; only
        // the local part is compared (quick-xml's `local_name`).
        var nameEnd = nameStart
        while nameEnd < i, !isXmlWhitespaceByte(bytes[nameEnd]) {
            nameEnd += 1
        }
        let qname = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
        let local = splitQName(qname).local
        pos = min(i + 1, bytes.count)
        if let elem = stack.popLast() {
            scopes.removeLast()
            if elem.local != local {
                recovered = true
            }
            attach(.elem(elem))
        } else {
            recovered = true
        }
    }

    /// One raw, not-yet-resolved attribute as scanned from the tag.
    private struct RawAttr {
        var qname: String
        var value: [UInt8]
    }

    private mutating func parseStartTag() throws {
        // Scan the whole tag to its closing '>' first (quotes respected), the
        // way quick-xml frames the event before parsing attributes within it.
        var i = pos + 1
        var quote: UInt8? = nil
        while i < bytes.count {
            let b = bytes[i]
            if let q = quote {
                if b == q { quote = nil }
            } else if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
                quote = b
            } else if b == UInt8(ascii: ">") {
                break
            }
            i += 1
        }
        guard i < bytes.count else {
            throw ConvertError.malformed("unparseable xml: unterminated tag")
        }
        var span = bytes[(pos + 1)..<i]
        pos = i + 1
        var selfClosing = false
        if span.last == UInt8(ascii: "/") {
            selfClosing = true
            span = span.dropLast()
        }

        // Tag name.
        var j = span.startIndex
        while j < span.endIndex, !isXmlWhitespaceByte(span[j]) {
            j += 1
        }
        let rawName = String(decoding: span[span.startIndex..<j], as: UTF8.self)

        // Raw attributes; a malformed one drops it and the rest, visibly.
        var rawAttrs: [RawAttr] = []
        var k = j
        var seenQnames: Set<String> = []
        scan: while true {
            while k < span.endIndex, isXmlWhitespaceByte(span[k]) {
                k += 1
            }
            if k >= span.endIndex {
                break
            }
            let nameStart = k
            while k < span.endIndex, span[k] != UInt8(ascii: "="), !isXmlWhitespaceByte(span[k]) {
                k += 1
            }
            let qname = String(decoding: span[nameStart..<k], as: UTF8.self)
            while k < span.endIndex, isXmlWhitespaceByte(span[k]) {
                k += 1
            }
            guard k < span.endIndex, span[k] == UInt8(ascii: "=") else {
                Log.debug("dropping undecodable attribute: missing '='")
                break scan
            }
            k += 1
            while k < span.endIndex, isXmlWhitespaceByte(span[k]) {
                k += 1
            }
            guard k < span.endIndex,
                span[k] == UInt8(ascii: "\"") || span[k] == UInt8(ascii: "'")
            else {
                Log.debug("dropping undecodable attribute: unquoted value")
                break scan
            }
            let q = span[k]
            k += 1
            let valueStart = k
            while k < span.endIndex, span[k] != q {
                k += 1
            }
            guard k < span.endIndex else {
                Log.debug("dropping undecodable attribute: unterminated value")
                break scan
            }
            let value = Array(span[valueStart..<k])
            k += 1
            if qname.isEmpty {
                Log.debug("dropping undecodable attribute: empty name")
                break scan
            }
            // Duplicates are a syntax error in quick-xml's checked iterator:
            // the duplicate and everything after it drop.
            if !seenQnames.insert(qname).inserted {
                Log.debug("dropping undecodable attribute: duplicate \(qname)")
                break scan
            }
            rawAttrs.append(RawAttr(qname: qname, value: value))
        }

        // Namespace declarations on this element open its scope frame before
        // any name on it resolves.
        var frame: [(prefix: String, uri: String?)] = []
        for attr in rawAttrs {
            if attr.qname == "xmlns" {
                let uri = String(decoding: attr.value, as: UTF8.self)
                frame.append((prefix: "", uri: uri.isEmpty ? nil : uri))
            } else if attr.qname.hasPrefix("xmlns:") {
                let prefix = String(attr.qname.dropFirst("xmlns:".count))
                let uri = String(decoding: attr.value, as: UTF8.self)
                frame.append((prefix: prefix, uri: uri.isEmpty ? nil : uri))
            }
        }
        scopes.append(frame)

        let elem = makeElement(rawName: rawName, rawAttrs: rawAttrs)
        if selfClosing {
            scopes.removeLast()
            try bumpNodes()
            attach(.elem(elem))
        } else {
            if stack.count >= Limits.maxXmlDepth {
                scopes.removeLast()
                throw ConvertError.resourceLimit(
                    limit: "max_xml_depth",
                    detail: "element nesting exceeds \(Limits.maxXmlDepth)")
            }
            try bumpNodes()
            stack.append(elem)
        }
    }

    /// `rawName` survives on the element until its end tag is matched, then
    /// drops; stored out-of-band in `attrs` would leak, so keep a parallel
    /// field via the `rawNames` table below.
    private mutating func makeElement(rawName: String, rawAttrs: [RawAttr]) -> XmlElement {
        let (prefix, local) = splitQName(rawName)
        let ns = resolveElementNs(prefix: prefix)
        var attrs: [XmlAttr] = []
        for raw in rawAttrs {
            if raw.qname == "xmlns" || raw.qname.hasPrefix("xmlns:") {
                continue
            }
            let (aprefix, alocal) = splitQName(raw.qname)
            // Default namespace applies to elements, not attributes.
            let ans: String? = aprefix.isEmpty ? nil : resolvePrefix(aprefix)
            attrs.append(XmlAttr(ns: ans, local: alocal, value: normalizeAttrValue(raw.value)))
        }
        var elem = XmlElement(ns: ns, local: local, attrs: attrs, children: [])
        // `mc:Choice/@Requires` holds namespace *prefixes* evaluated in the
        // element's lexical scope (prefixes may be rebound locally). Resolve
        // them to URIs here, where the scope is known. Unresolvable prefixes
        // stay literal and match no requirement.
        if local == "Choice", ns == Ns.mc,
            let idx = elem.attrs.firstIndex(where: { $0.local == "Requires" })
        {
            let resolved = elem.attrs[idx].value
                .split(whereSeparator: { $0.unicodeScalars.allSatisfy(\.isRustWhitespace) })
                .map { prefix -> String in
                    if let uri = resolvePrefix(String(prefix)) {
                        return uri
                    }
                    return String(prefix)
                }
                .joined(separator: " ")
            elem.attrs[idx].value = resolved
        }
        return elem
    }

    private func splitQName(_ qname: String) -> (prefix: String, local: String) {
        guard let colon = qname.firstIndex(of: ":") else { return ("", qname) }
        return (String(qname[..<colon]), String(qname[qname.index(after: colon)...]))
    }

    private func resolveElementNs(prefix: String) -> String? {
        if prefix.isEmpty {
            // Default namespace, when one is in scope.
            return lookupScope("")
        }
        return resolvePrefix(prefix)
    }

    private func resolvePrefix(_ prefix: String) -> String? {
        if prefix == "xml" {
            return Ns.xml
        }
        if prefix == "xmlns" {
            return nil
        }
        return lookupScope(prefix)
    }

    private func lookupScope(_ prefix: String) -> String? {
        for frame in scopes.reversed() {
            // The last (re)binding in one frame wins, matching document order.
            for binding in frame.reversed() where binding.prefix == prefix {
                guard let uri = binding.uri else { return nil }
                return normalizeOoxmlUri(uri) ?? uri
            }
        }
        return nil
    }

    /// XML 1.0 attribute-value normalization with quick-xml's fallback: tabs
    /// and line breaks become spaces and character/predefined-entity
    /// references expand; any unresolvable reference degrades the whole
    /// value to its raw form.
    private func normalizeAttrValue(_ raw: [UInt8]) -> String {
        var out = String.UnicodeScalarView()
        var i = 0
        while i < raw.count {
            let b = raw[i]
            switch b {
            case 0x09, 0x0A:
                out.append(" ")
                i += 1
            case 0x0D:
                if i + 1 < raw.count, raw[i + 1] == 0x0A {
                    i += 1
                }
                out.append(" ")
                i += 1
            case UInt8(ascii: "&"):
                var j = i + 1
                while j < raw.count, raw[j] != UInt8(ascii: ";") {
                    j += 1
                }
                guard j < raw.count,
                    let resolved = resolvePredefinedOrNumeric(
                        String(decoding: raw[(i + 1)..<j], as: UTF8.self))
                else {
                    return String(decoding: raw, as: UTF8.self)
                }
                out.append(contentsOf: resolved.unicodeScalars)
                i = j + 1
            default:
                // Multi-byte UTF-8 passes through unchanged.
                let start = i
                var end = i + 1
                while end < raw.count, raw[end] & 0xC0 == 0x80 {
                    end += 1
                }
                out.append(contentsOf: String(decoding: raw[start..<end], as: UTF8.self).unicodeScalars)
                i = end
            }
        }
        return String(out)
    }

    /// The references quick-xml expands inside attribute values: the five
    /// predefined entities and numeric character references only.
    private func resolvePredefinedOrNumeric(_ name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "apos": return "'"
        case "quot": return "\""
        default:
            guard name.hasPrefix("#") else { return nil }
            return numericReference(name.dropFirst())
        }
    }
}

private func isXmlWhitespaceByte(_ b: UInt8) -> Bool {
    b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
}

private func numericReference(_ num: Substring) -> String? {
    let code: UInt32?
    if num.hasPrefix("x") || num.hasPrefix("X") {
        code = UInt32(num.dropFirst(), radix: 16)
    } else {
        code = UInt32(num, radix: 10)
    }
    guard let code, let scalar = Unicode.Scalar(code) else { return nil }
    return String(scalar)
}

/// Resolve entity references found in character data (the general-reference
/// path). Mirrors anydoc's `resolve_entity` table.
func resolveEntity(_ name: String) -> String? {
    if name.hasPrefix("#") {
        return numericReference(name.dropFirst())
    }
    let scalar: String
    switch name {
    case "amp": scalar = "&"
    case "lt": scalar = "<"
    case "gt": scalar = ">"
    case "apos": scalar = "'"
    case "quot": scalar = "\""
    case "nbsp": scalar = "\u{a0}"
    case "shy": scalar = "\u{ad}"
    case "mdash": scalar = "\u{2014}"
    case "ndash": scalar = "\u{2013}"
    case "lsquo": scalar = "\u{2018}"
    case "rsquo": scalar = "\u{2019}"
    case "ldquo": scalar = "\u{201c}"
    case "rdquo": scalar = "\u{201d}"
    case "hellip": scalar = "\u{2026}"
    case "copy": scalar = "\u{a9}"
    case "reg": scalar = "\u{ae}"
    case "trade": scalar = "\u{2122}"
    case "deg": scalar = "\u{b0}"
    case "middot": scalar = "\u{b7}"
    case "bull": scalar = "\u{2022}"
    case "sect": scalar = "\u{a7}"
    case "para": scalar = "\u{b6}"
    case "laquo": scalar = "\u{ab}"
    case "raquo": scalar = "\u{bb}"
    case "times": scalar = "\u{d7}"
    case "divide": scalar = "\u{f7}"
    case "plusmn": scalar = "\u{b1}"
    case "frac12": scalar = "\u{bd}"
    case "frac14": scalar = "\u{bc}"
    case "eacute": scalar = "\u{e9}"
    case "egrave": scalar = "\u{e8}"
    case "agrave": scalar = "\u{e0}"
    case "ccedil": scalar = "\u{e7}"
    case "uuml": scalar = "\u{fc}"
    case "ouml": scalar = "\u{f6}"
    case "auml": scalar = "\u{e4}"
    case "szlig": scalar = "\u{df}"
    case "aring": scalar = "\u{e5}"
    case "oslash": scalar = "\u{f8}"
    case "aelig": scalar = "\u{e6}"
    case "euro": scalar = "\u{20ac}"
    case "pound": scalar = "\u{a3}"
    case "yen": scalar = "\u{a5}"
    case "cent": scalar = "\u{a2}"
    default: return nil
    }
    return scalar
}
