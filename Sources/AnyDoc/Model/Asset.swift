/// Index into `Document.assets`.
public struct AssetId: Sendable, Hashable {
    public var rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
}

/// An embedded binary asset (image, object payload). Bytes are always
/// retained so the document stays self-contained; total retained bytes are
/// capped by the fixed `maxAssetTotalBytes` limit at parse time.
public struct Asset: Sendable {
    /// This asset's own index, so a detached `Asset` still identifies itself.
    public var id: AssetId
    /// MIME type, e.g. `image/png`.
    public var mediaType: String
    /// Package part or stream the asset came from, for provenance.
    public var originPart: String
    /// The payload, exactly as stored in the source.
    public var bytes: [UInt8]

    public init(id: AssetId, mediaType: String, originPart: String, bytes: [UInt8]) {
        self.id = id
        self.mediaType = mediaType
        self.originPart = originPart
        self.bytes = bytes
    }
}
