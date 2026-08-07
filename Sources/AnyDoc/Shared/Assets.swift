/// Embedded-asset accumulation with the fixed retained-bytes cap.

struct AssetSink {
    var assets: [Asset] = []
    /// Origin part -> retained asset, so repeated references to the same
    /// part share one asset instead of duplicating its bytes (and falsely
    /// accumulating against the cap).
    private var byPart: [String: AssetId] = [:]
    var total: Int = 0

    init() {}

    /// Retain an asset's bytes (copied only when the part is not already
    /// retained). Crossing the retained-bytes cap is a hard error.
    mutating func add(mediaType: String, originPart: String, bytes: [UInt8]) throws -> AssetId {
        if let id = byPart[originPart] {
            return id
        }
        total += bytes.count
        if total > Limits.maxAssetTotalBytes {
            throw ConvertError.resourceLimit(
                limit: "max_asset_total_bytes",
                detail: "embedded assets exceed the retained-bytes cap")
        }
        let id = AssetId(assets.count)
        byPart[originPart] = id
        assets.append(Asset(id: id, mediaType: mediaType, originPart: originPart, bytes: bytes))
        return id
    }
}

/// Resolve an image relationship to its source. External-mode relationships
/// carry the image's URL directly; internal-mode targets load from the
/// package and are retained as assets. Failures degrade to `nil` per the
/// unified policy; fatal errors propagate.
func relImageSource(
    _ pkg: Package,
    _ rels: Relationships,
    basePart: String,
    assets: MutBox<AssetSink>,
    relId: String
) throws -> ImageSource? {
    guard let rel = rels.get(relId) else {
        return nil
    }
    if rel.mode == .external {
        return rel.target.isEmpty ? nil : .external(rel.target)
    }
    guard let (part, bytes) = try relTargetBytes(pkg, rels, basePart: basePart, relId: relId)
    else {
        return nil
    }
    let media = mediaTypeFor(part)
    let id = try assets.value.add(mediaType: media, originPart: part, bytes: bytes)
    return .asset(id)
}

/// MIME type from a part path's extension.
func mediaTypeFor(_ part: String) -> String {
    var ext = ""
    if let dot = part.unicodeScalars.lastIndex(of: ".") {
        ext = String(part.unicodeScalars[part.unicodeScalars.index(after: dot)...]).asciiLowercased()
    }
    switch ext {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "bmp": return "image/bmp"
    case "tif", "tiff": return "image/tiff"
    case "svg": return "image/svg+xml"
    case "emf": return "image/emf"
    case "wmf": return "image/wmf"
    case "webp": return "image/webp"
    default: return "application/octet-stream"
    }
}

extension String {
    /// Rust `str::to_ascii_lowercase`: ASCII letters only, all else verbatim.
    func asciiLowercased() -> String {
        var out = String.UnicodeScalarView()
        for c in unicodeScalars {
            if c >= "A" && c <= "Z" {
                out.append(Unicode.Scalar(c.value + 0x20) ?? c)
            } else {
                out.append(c)
            }
        }
        return String(out)
    }
}
