/// Minimal MS-CFB (OLE2 Compound File Binary) reader: directory listing and
/// stream reads. Serves OLE detection, embedded-object metadata (docx), and
/// later the legacy doc/ppt/xls containers.
///
/// CONTRACT (Phase 2 wave 1 implements this; callers already code against it):
/// - `init` validates the CFB header (signature D0 CF 11 E0 A1 B1 1A E1,
///   sane sector shift) and throws `ConvertError.malformed` otherwise.
/// - Stream name matching follows the cfb crate: exact match on the stored
///   UTF-16 name, compared case-insensitively (CFB names are
///   case-insensitive per MS-CFB's upper-case comparison rule).
/// - Bounded: FAT/directory walks must guard against cycles and cap sector
///   visits so crafted files cannot loop or explode memory.
struct CompoundFile {
    init(bytes: [UInt8]) throws {
        // TODO(phase2-wave1): real MS-CFB implementation.
        throw ConvertError.unsupported("cfb is not implemented yet")
    }

    /// Names of the directory entries directly under the root storage, in
    /// directory order.
    var rootEntryNames: [String] { [] }

    /// True when a stream or storage with this name exists directly under
    /// root (case-insensitive per MS-CFB).
    func hasRootEntry(_ name: String) -> Bool { false }

    /// The full bytes of a stream at the given path from root, or `nil` when
    /// absent. Path components are storage/stream names.
    func readStream(_ path: [String]) -> [UInt8]? { nil }
}
