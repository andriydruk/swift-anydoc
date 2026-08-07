/// One span of inline content.
public indirect enum Inline: Sendable {
    /// Styled text. Runs are split wherever the style changes.
    case text(String, style: Style)
    /// A hyperlink wrapping its own inline content.
    case link(content: [Inline], target: LinkTarget)
    /// An image: alt text (what Markdown renders for embedded bytes) and
    /// where the bytes are.
    case image(alt: String, source: ImageSource)
    /// Zero-width anchor marking an internal link target at this position.
    case anchor(AnchorId)
    /// A reference to the `Note` with this id.
    case noteRef(String)
    /// A line break inside a block, not a new block.
    case lineBreak

    /// Unstyled text.
    public static func plain(_ text: String) -> Inline {
        .text(text, style: .plain)
    }
}

/// Flatten inlines to their text, dropping styling and links but keeping link
/// text and image alt text. Line breaks become newlines; anchors and note
/// references contribute nothing.
public func inlinesToPlainText(_ inlines: [Inline]) -> String {
    var out = ""
    collectPlainText(inlines, into: &out)
    return out
}

private func collectPlainText(_ inlines: [Inline], into out: inout String) {
    for inline in inlines {
        switch inline {
        case .text(let text, _): out += text
        case .link(let content, _): collectPlainText(content, into: &out)
        case .image(let alt, _): out += alt
        case .anchor, .noteRef: break
        case .lineBreak: out += "\n"
        }
    }
}

/// True when nothing here would render as visible content: only whitespace,
/// empty-target links, anchors, and line breaks. An image or a note reference
/// always counts as content.
public func inlinesAreEmpty(_ inlines: [Inline]) -> Bool {
    inlines.allSatisfy { inline in
        switch inline {
        case .text(let text, _): text.isBlank
        case .link(let content, let target): target.isEmpty && inlinesAreEmpty(content)
        case .image, .noteRef: false
        case .anchor, .lineBreak: true
        }
    }
}
