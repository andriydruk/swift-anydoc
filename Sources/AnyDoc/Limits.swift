/// Fixed safety limits, applied identically to every conversion.
///
/// Hard caps against attack/abuse input shapes (decompression bombs,
/// pathological nesting, runaway expansion) — crossing one returns
/// `ConvertError.resourceLimit`, always. Deliberately not configurable:
/// real-world documents sit orders of magnitude below every value here.
/// Values mirror the Rust crate's `package::limits` exactly.
enum Limits {
    /// Maximum decompressed size of a single archive entry: 128 MiB.
    static let maxEntryBytes: UInt64 = 128 * 1024 * 1024

    /// Maximum total decompressed bytes read from one archive: 512 MiB.
    static let maxTotalBytes: UInt64 = 512 * 1024 * 1024

    /// Maximum number of entries in one archive.
    static let maxEntryCount: Int = 100_000

    /// Maximum XML element nesting depth.
    static let maxXmlDepth: Int = 256

    /// Maximum number of XML nodes (elements + text runs) in one part.
    static let maxXmlNodes: Int = 2_000_000

    /// Maximum content-bearing cells a repeat expansion may produce per table.
    static let maxExpansion: UInt64 = 4_000_000

    /// Maximum total text bytes duplicated by repeat expansion per document:
    /// 64 MiB.
    static let maxExpansionTextBytes: UInt64 = 64 * 1024 * 1024

    /// Maximum total bytes of embedded assets retained in a `Document`: 128 MiB.
    static let maxAssetTotalBytes: Int = 128 * 1024 * 1024

    /// Maximum nesting depth of binary record containers (legacy PPT stream).
    static let maxRecordDepth: Int = 64

    /// Maximum total binary records visited in one legacy record stream.
    static let maxRecords: UInt64 = 16_000_000
}
