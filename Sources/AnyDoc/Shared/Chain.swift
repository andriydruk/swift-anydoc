/// Style-chain traversal: walk a parent (`basedOn`) chain child-to-root.
/// A cycle is a resource-safety bound and hard-fails - recovery never
/// weakens resource safety.

/// Style id -> (definition, parent style id).
struct StyleChains<D> {
    private var raw: [String: (def: D, parent: String?)] = [:]

    init() {}

    mutating func insert(_ id: String, _ def: D, parent: String?) {
        raw[id] = (def, parent)
    }

    func definition(_ id: String) -> D? {
        raw[id]?.def
    }

    /// Walk a chain child-to-root, visiting each definition until `visit`
    /// returns non-nil. Unknown ids end the walk (a dangling reference is
    /// producer sloppiness, not fatal); a cycle hard-fails.
    func walk<T>(_ id: String, _ visit: (D) -> T?) throws -> T? {
        var visited: Set<String> = []
        var cursor: String? = raw[id] != nil ? id : nil
        while let current = cursor {
            if !visited.insert(current).inserted {
                throw ConvertError.malformed("style inheritance cycle at \(rustDebugString(current))")
            }
            guard let (def, parent) = raw[current] else { break }
            if let hit = visit(def) {
                return hit
            }
            cursor = parent.flatMap { raw[$0] != nil ? $0 : nil }
        }
        return nil
    }
}
