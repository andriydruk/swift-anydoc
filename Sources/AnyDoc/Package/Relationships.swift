/// OPC relationship parts, typed.

/// Well-known OPC relationship types (Transitional form; Strict types are
/// normalized onto these when the rels part is read).
enum RelType {
    static let officeDocument =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    static let styles =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
    static let numbering =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering"
    static let footnotes =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes"
    static let endnotes =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes"
}

enum TargetMode: Equatable {
    case internalMode
    case external
}

struct Relationship {
    var target: String
    var relType: String
    var mode: TargetMode
}

struct Relationships {
    private var map: [String: Relationship] = [:]

    init() {}

    init(_ map: [String: Relationship]) {
        self.map = map
    }

    func get(_ id: String) -> Relationship? {
        map[id]
    }

    /// Internal-mode target for an id, the common case for parts.
    func internalTarget(_ id: String) -> String? {
        guard let rel = map[id], rel.mode == .internalMode else { return nil }
        return rel.target
    }

    /// All relationships, ordered by id (byte-wise, for determinism where
    /// the Rust HashMap iteration order was incidental).
    var all: [(id: String, rel: Relationship)] {
        map.sorted { byteWiseLess($0.key, $1.key) }.map { (id: $0.key, rel: $0.value) }
    }

    /// The internal-mode relationship of a given type, lowest id first so
    /// the pick is deterministic when a producer emits duplicates.
    func firstOfType(_ relType: String) -> Relationship? {
        map.filter { $0.value.relType == relType && $0.value.mode == .internalMode }
            .min { byteWiseLess($0.key, $1.key) }
            .map { $0.value }
    }
}

/// Rust `String` ordering: lexicographic over UTF-8 bytes.
private func byteWiseLess(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

/// Read a relationships part. An absent, unreadable, or corrupt part yields
/// an empty map (absent is valid - many parts simply have no relationships;
/// the rest degrade per the unified policy with a log). Resource-limit
/// errors always propagate.
func readRels(_ pkg: Package, _ part: String) throws -> Relationships {
    guard let root = try pkg.optionalXmlPart(part) else {
        return Relationships()
    }
    var map: [String: Relationship] = [:]
    for rel in root.descendants(Ns.pkgRels, "Relationship") {
        guard let id = rel.attrAny("Id"), let target = rel.attrAny("Target") else {
            continue
        }
        let mode: TargetMode
        if let m = rel.attrAny("TargetMode"), eqIgnoreAsciiCase(m, "external") {
            mode = .external
        } else {
            mode = .internalMode
        }
        let rawType = rel.attrAny("Type") ?? ""
        let relType = normalizeOoxmlUri(rawType) ?? rawType
        map[id] = Relationship(target: target, relType: relType, mode: mode)
    }
    return Relationships(map)
}

/// A loaded internal relationship target: its resolved part path and bytes.
typealias RelTarget = (path: String, bytes: [UInt8])

/// Load an internal relationship target's bytes, resolved against the part
/// the relationship appears in. Unknown ids, external targets, and
/// unresolvable or unreadable targets degrade (log + `nil`) per the unified
/// policy; fatal resource-limit errors always propagate.
func relTargetBytes(
    _ pkg: Package, _ rels: Relationships, basePart: String, relId: String
) throws -> RelTarget? {
    guard let rel = rels.get(relId) else {
        return nil
    }
    if rel.mode != .internalMode {
        return nil
    }
    let target: PackageTarget
    do {
        target = try resolvePackageReference(basePart: basePart, reference: rel.target)
    } catch let e as ConvertError {
        Log.warn("skipping unresolvable relationship target \(rustDebugQuoted(rel.target)): \(e.message)")
        return nil
    }
    guard let bytes = try pkg.optionalPart(target.path) else {
        Log.warn("relationship target \(target.path) is missing")
        return nil
    }
    return (path: target.path, bytes: bytes)
}

/// Conventional rels part name for a part (`word/document.xml` ->
/// `word/_rels/document.xml.rels`).
func relsPartFor(_ part: String) -> String {
    if let slash = part.lastIndex(of: "/") {
        let dir = part[..<slash]
        let file = part[part.index(after: slash)...]
        return "\(dir)/_rels/\(file).rels"
    }
    return "_rels/\(part).rels"
}
