/// Raw DEFLATE (RFC 1951) decompression. In-repo implementation — the
/// zero-dependency replacement for flate2/zip's inflater.
///
/// CONTRACT (Phase 2 wave 1 implements this; callers already code against it):
/// - Decompresses `input` as a raw deflate stream (no zlib/gzip wrapper).
/// - Never produces more than `maxOutput` bytes: when the budget is reached,
///   decompression stops and returns exactly `maxOutput` bytes with
///   `limitHit: true` (callers decide whether truncation is an error).
/// - Throws `ConvertError.malformed` on corrupt streams.
struct InflateResult {
    var bytes: [UInt8]
    /// True when output was truncated at `maxOutput` before the stream ended.
    var limitHit: Bool
}

func inflateRaw(_ input: ArraySlice<UInt8>, maxOutput: Int) throws -> InflateResult {
    // TODO(phase2-wave1): real RFC 1951 implementation.
    throw ConvertError.unsupported("inflate is not implemented yet")
}
