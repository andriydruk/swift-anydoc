/// Conversion options, ported from `MarkdownOptions` in `markdown/mod.rs`.
///
/// Every flag defaults to the reference's default, including the ones whose
/// defaults are surprising — see `includeImages`.

/// Whether to keep the source's characters or spend fewer tokens.
enum PdfMarkdownProfile {
    /// Preserve source text fidelity. The default.
    case fidelity
    /// Prefer token-efficient output, including collapsing long dot leaders.
    case compact
}

/// Options for Markdown conversion.
struct PdfMarkdownOptions {
    var profile: PdfMarkdownProfile = .fidelity
    /// Detect headings by font size.
    var detectHeaders = true
    var detectLists = true
    var detectCode = true
    /// Overrides the measured body size when set. Note the reference applies
    /// it without validation, so a zero here makes every size ratio infinite
    /// — which is reproduced.
    var baseFontSize: Float?
    var removePageNumbers = true
    var formatUrls = true
    var fixHyphenation = true
    var detectBold = true
    var detectItalic = true
    /// Emit `<u>` runs for geometrically-detected underlines.
    var detectUnderline = true
    /// **Off by default, deliberately.** The content-stream walker emits an
    /// image item for every Image XObject it meets, so rendering them would
    /// insert placeholders throughout the output of every existing caller.
    /// The reference chose compatibility; the bounding boxes remain
    /// available to callers that want to crop and caption figures
    /// themselves.
    var includeImages = false
    var includeLinks = true
    /// Insert `<!-- Page N -->` markers between pages.
    var includePageNumbers = false
    var stripHeadersFooters = true

    init() {}
}
