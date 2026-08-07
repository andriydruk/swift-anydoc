/// One block-level piece of a document body.
public indirect enum Block: Sendable {
    /// A section heading. `level` is the outline depth as the source assigns
    /// it, 1-based; renderers clamp to what their target supports. `anchor`
    /// is the stable anchor id when the source targets this heading.
    case heading(level: Int, anchor: AnchorId?, content: [Inline])
    /// A run of body text.
    case paragraph([Inline])
    /// A list, with its numbering already resolved.
    case list(List)
    /// A table grid.
    case table(Table)
    /// Quoted content, which nests.
    case blockQuote([Block])
    /// Preformatted text: language hint when the source names one, and the
    /// literal text with newlines intact.
    case codeBlock(lang: String?, text: String)
    /// A horizontal rule.
    case rule

    /// A heading with no anchor, for the common case where nothing in the
    /// document links to it.
    public static func heading(_ level: Int, _ content: [Inline]) -> Block {
        .heading(level: level, anchor: nil, content: content)
    }
}
