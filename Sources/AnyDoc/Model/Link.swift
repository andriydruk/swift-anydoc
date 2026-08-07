/// Normalized, document-scoped anchor id. Frontends that concatenate multiple
/// source parts (EPUB chapters) scope ids during normalization so they stay
/// unique across the whole document.
public typealias AnchorId = String

/// Where a link points.
public enum LinkTarget: Sendable, Equatable {
    /// Absolute URL with a scheme.
    case external(String)
    /// Scheme-less relative reference, preserved as written.
    case relative(String)
    /// Internal target: a heading anchor or an `Inline.anchor` node.
    case anchor(AnchorId)

    /// True when the target string is empty, whichever kind it is.
    public var isEmpty: Bool {
        switch self {
        case .external(let s), .relative(let s), .anchor(let s): s.isEmpty
        }
    }
}

/// Where an image's bytes live.
public enum ImageSource: Sendable, Equatable {
    /// Absolute URL with a scheme.
    case external(String)
    /// Embedded image stored in `Document.assets`.
    case asset(AssetId)
    /// No usable source: the image's part is missing or unreadable and it
    /// has no URL. Only the alt text remains.
    case unavailable
}
