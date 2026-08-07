/// Inline run normalization and rendering.

enum Norm {
    case text(String, Style)
    case link(content: [Inline], target: LinkTarget)
    case image(alt: String, source: ImageSource)
    case anchor(String)
    case noteRef(String)
    case lineBreak
}

/// Single-pass normalization: drops empty runs, strips styling from
/// whitespace-only runs, merges adjacent same-style runs, and re-joins styled
/// runs split only by whitespace (`**a** **b**` -> `**a b**`). Untargeted
/// anchors drop out here: they render as nothing, so leaving them in would
/// part runs that belong together.
func normalizeInlines(_ inlines: [Inline], _ rc: RenderContext) -> [Norm] {
    var out: [Norm] = []
    for inline in inlines {
        switch inline {
        case .text(let text, let style):
            if text.isEmpty {
                continue
            }
            let style = text.isBlank ? Style.plain : style
            if case .text(let prev, let prevStyle) = out.last, prevStyle == style {
                out[out.count - 1] = .text(prev + text, style)
                continue
            }
            // Bridge: [styled S][ws plain][incoming styled S] merges into one run.
            if style != .plain, !style.code, out.count >= 2,
                case .text(let ws, let wsStyle) = out[out.count - 1], wsStyle == .plain,
                ws.isBlank,
                case .text(let prev, let prevStyle) = out[out.count - 2], prevStyle == style
            {
                out.removeLast()
                out[out.count - 1] = .text(prev + ws + text, style)
                continue
            }
            out.append(.text(text, style))
        case .link(let content, let target):
            if target.isEmpty {
                // No usable destination: keep the content as plain inlines.
                if !inlinesAreEmpty(content) {
                    out.append(contentsOf: normalizeInlines(content, rc))
                }
                continue
            }
            out.append(.link(content: content, target: target))
        case .image(let alt, let source):
            out.append(.image(alt: alt, source: source))
        case .anchor(let id):
            if rc.anchors.htmlId(id) != nil {
                out.append(.anchor(id))
            }
        case .noteRef(let id):
            out.append(.noteRef(id))
        case .lineBreak:
            out.append(.lineBreak)
        }
    }
    return out
}

func renderInlines(_ inlines: [Inline], _ ctx: InlineContext, _ rc: RenderContext) -> String {
    renderInlinesMode(inlines, ctx, inLabel: false, rc)
}

private func renderInlinesMode(
    _ inlines: [Inline], _ ctx: InlineContext, inLabel: Bool, _ rc: RenderContext
) -> String {
    let runs = normalizeInlines(inlines, rc)
    var out = ""
    for (idx, run) in runs.enumerated() {
        switch run {
        case .text(let text, let style):
            var nextActive = false
            if idx + 1 < runs.count {
                switch runs[idx + 1] {
                case .link, .image, .noteRef: nextActive = true
                case .text(_, let nextStyle): nextActive = nextStyle != .plain
                default: nextActive = false
                }
            }
            renderTextRun(text, style, ctx, trailingActive: nextActive, inLabel: inLabel, into: &out)
        case .noteRef(let id):
            if let num = rc.nums[id] {
                out += "[^\(num)]"
            }
        case .link(let content, let target):
            renderLink(content, target, ctx, rc, into: &out)
        case .image(let alt, let source):
            renderImage(alt, source, ctx, inLabel: inLabel, into: &out)
        case .anchor(let id):
            if let htmlId = rc.anchors.htmlId(id) {
                out += "<a id=\"\(htmlId)\"></a>"
            }
        case .lineBreak:
            switch ctx {
            case .block: out += "\\\n"
            case .heading: out += " "
            case .tableCell: out += "\n"
            }
        }
    }
    return out
}

private func renderLink(
    _ content: [Inline], _ target: LinkTarget, _ ctx: InlineContext, _ rc: RenderContext,
    into out: inout String
) {
    let label = renderInlinesMode(content, ctx, inLabel: true, rc)
    let url: String
    switch target {
    case .external(let u), .relative(let u):
        url = u
    case .anchor(let id):
        guard let fragment = rc.anchors.fragment(id) else {
            // Target exists nowhere in the document: degrade to plain text.
            Log.debug("unresolved internal link target: \(id)")
            out += renderInlinesMode(content, ctx, inLabel: false, rc)
            return
        }
        url = "#\(fragment)"
    }
    // Emptiness is tested on the trimmed label, but the rendered label keeps
    // its source-significant edge spaces.
    if label.isBlank {
        if case .anchor = target {
            return
        }
        out += "[\(escapeUrlAsText(url, ctx))](\(formatUrl(url)))"
    } else {
        out += "[\(label)](\(formatUrl(url)))"
    }
}

private func renderImage(
    _ alt: String, _ source: ImageSource, _ ctx: InlineContext, inLabel: Bool,
    into out: inout String
) {
    switch source {
    case .external(let url):
        let alt = escapeText(alt.rustTrim(), ctx, EscapeOpts(inLabel: true))
        out += "![\(alt)](\(formatUrl(url)))"
    // Embedded assets render as their alt text: Markdown cannot embed bytes,
    // and the bytes stay available in `Document.assets`. A source-less image
    // has only its alt text to offer.
    case .asset, .unavailable:
        if !alt.isBlank {
            out += escapeText(alt.rustTrim(), ctx, EscapeOpts(inLabel: inLabel))
        }
    }
}

/// Emit a styled run, moving edge whitespace outside the delimiters.
private func renderTextRun(
    _ text: String, _ style: Style, _ ctx: InlineContext, trailingActive: Bool, inLabel: Bool,
    into out: inout String
) {
    if style == .plain {
        let atLineStart = out.isEmpty || out.hasSuffix("\n")
        out += escapeText(
            text, ctx,
            EscapeOpts(atLineStart: atLineStart, trailingActive: trailingActive, inLabel: inLabel))
        return
    }
    let lead = text[..<text.rustTrimStartSub().startIndex]
    let core = text.rustTrimStartSub().rustTrimEndSub()
    let trail = text[core.endIndex...]
    if !lead.isEmpty {
        out += lead
    }
    if !core.isEmpty {
        if style.code {
            pushCodeSpan(String(core), into: &out)
        } else {
            var open = ""
            if style.strike { open += "~~" }
            if style.bold { open += "**" }
            if style.italic { open += "*" }
            let close = String(open.reversed())
            out += open
            out += escapeText(String(core), ctx, EscapeOpts(styled: true, inLabel: inLabel))
            out += close
        }
    }
    if !trail.isEmpty {
        out += trail
    }
}

func pushCodeSpan(_ text: String, into out: inout String) {
    let text = text.replacing("\n", with: " ")
    let fence = backtickFence(text, min: 1)
    let pad = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
    out += "\(fence)\(pad)\(text)\(pad)\(fence)"
}
