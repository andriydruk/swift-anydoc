/// Why a conversion could not produce a useful result.
///
/// An error means meaningful conversion was impossible: the input was
/// unreadable or structurally unusable, encrypted, or crossed a fixed
/// safety/resource limit. Recoverable producer quirks never surface here —
/// they are recovered or skipped (and logged) while conversion continues.
public enum ConvertError: Error, Sendable {
    /// The format is unknown or cannot be converted at all.
    case unsupported(String)
    /// The document is structurally unusable — no meaningful content could be
    /// extracted. `part` names the package part or stream when known.
    case malformed(part: String?, detail: String)
    /// The document is encrypted or password-protected.
    case encrypted
    /// A fixed safety limit was exceeded (decompression, nesting depth, node
    /// count, repeat expansion, retained asset bytes). Hard errors in every
    /// case; see `Limits` for the documented defaults.
    case resourceLimit(limit: String, detail: String)
    /// A part required for any meaningful output is missing.
    case missingPart(part: String)
    /// The input could not be read.
    case io(IOError)

    /// Stable, machine-readable name for the case: what a caller branches on,
    /// where `message` carries the detail. Mirrors the Rust crate's
    /// `ConvertError::code`, which the Node/wasm bindings publish verbatim.
    public var code: String {
        switch self {
        case .unsupported: "unsupported"
        case .malformed: "malformed"
        case .encrypted: "encrypted"
        case .resourceLimit: "resourceLimit"
        case .missingPart: "missingPart"
        case .io: "io"
        }
    }

    /// Human-readable message, byte-compatible with the Rust `Display` impl
    /// (the snapshot corpus asserts these strings for error outcomes).
    public var message: String {
        switch self {
        case .unsupported(let what): "unsupported input: \(what)"
        case .malformed(let part?, let detail): "malformed document (\(part)): \(detail)"
        case .malformed(nil, let detail): "malformed document: \(detail)"
        case .encrypted: "document is encrypted"
        case .resourceLimit(let limit, let detail): "resource limit exceeded (\(limit)): \(detail)"
        case .missingPart(let part): "missing required part: \(part)"
        case .io(let e): "io error: \(e.message)"
        }
    }

    static func malformed(_ detail: String) -> ConvertError {
        .malformed(part: nil, detail: detail)
    }

    static func malformedPart(_ part: String, _ detail: String) -> ConvertError {
        .malformed(part: part, detail: detail)
    }

    /// True when recovery must not swallow this error: fixed safety limits
    /// hard-fail in every context, including optional parts.
    var isFatal: Bool {
        if case .resourceLimit = self { return true }
        return false
    }
}

extension ConvertError: CustomStringConvertible {
    public var description: String { message }
}

/// A file-system failure, formatted like Rust's `std::io::Error` so error
/// snapshots stay byte-compatible ("No such file or directory (os error 2)").
public struct IOError: Error, Sendable {
    /// The C `errno` value.
    public let errno: Int32
    /// `strerror`-style text for the errno.
    public let detail: String

    public init(errno: Int32, detail: String) {
        self.errno = errno
        self.detail = detail
    }

    public var message: String { "\(detail) (os error \(errno))" }
}
