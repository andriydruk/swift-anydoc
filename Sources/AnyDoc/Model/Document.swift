/// Information-preserving document model.
///
/// Only fully resolved content lives here: format frontends resolve style
/// cascades, numbering, and references before constructing these types.
/// A `Document` is self-contained — embedded assets carry their bytes, so it
/// stays usable after the source archive is gone.

/// A parsed document: its body, its notes, and the bytes of everything it
/// embedded.
public struct Document: Sendable {
    /// Body content in reading order.
    public var blocks: [Block]
    /// Note bodies, in the order the document defines them. Text refers to
    /// them by id through `Inline.noteRef`.
    public var notes: [Note]
    /// Every embedded asset, indexed by `AssetId`.
    public var assets: [Asset]

    public init(blocks: [Block] = [], notes: [Note] = [], assets: [Asset] = []) {
        self.blocks = blocks
        self.notes = notes
        self.assets = assets
    }
}

/// Footnote or endnote body, referenced from text by `Inline.noteRef`.
public struct Note: Sendable {
    /// Document-scoped id the referencing `Inline.noteRef` carries.
    public var id: String
    /// Whether the source placed this note on the page or at the end.
    public var kind: NoteKind
    /// The note's own content.
    public var blocks: [Block]

    public init(id: String, kind: NoteKind, blocks: [Block]) {
        self.id = id
        self.kind = kind
        self.blocks = blocks
    }
}

/// Where the source document places a note.
public enum NoteKind: Sendable, Equatable {
    /// Placed at the foot of the page that references it.
    case footnote
    /// Collected at the end of the document or section.
    case endnote
}
