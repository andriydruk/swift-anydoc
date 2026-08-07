/// Tri-state style deltas used during cascade resolution. A property is
/// either explicitly on, explicitly off, or unset (inherit); only after the
/// full cascade is a delta collapsed into the model's resolved `Style`.

struct StyleDelta: Equatable {
    var bold: Bool?
    var italic: Bool?
    var strike: Bool?
    var code: Bool?

    init(bold: Bool? = nil, italic: Bool? = nil, strike: Bool? = nil, code: Bool? = nil) {
        self.bold = bold
        self.italic = italic
        self.strike = strike
        self.code = code
    }

    /// Overlay `child` on `self`: an explicit child value (on **or** off)
    /// wins; unset inherits.
    func merge(_ child: StyleDelta) -> StyleDelta {
        StyleDelta(
            bold: child.bold ?? bold,
            italic: child.italic ?? italic,
            strike: child.strike ?? strike,
            code: child.code ?? code)
    }

    func apply(_ base: Style) -> Style {
        Style(
            bold: bold ?? base.bold,
            italic: italic ?? base.italic,
            strike: strike ?? base.strike,
            code: code ?? base.code)
    }

    func resolve() -> Style {
        apply(.plain)
    }
}

/// Drop from every run the emphasis `base` already carries. A heading style
/// defines its own typography, so its runs should carry only what they add
/// beyond it - otherwise the bold in `## **Heading**` is the style's, not the
/// author's.
func rebaseEmphasis(_ inlines: inout [Inline], base: Style) {
    if base == .plain {
        return
    }
    for i in inlines.indices {
        switch inlines[i] {
        case .text(let text, var style):
            style.bold = style.bold && !base.bold
            style.italic = style.italic && !base.italic
            style.strike = style.strike && !base.strike
            inlines[i] = .text(text, style: style)
        case .link(var content, let target):
            rebaseEmphasis(&content, base: base)
            inlines[i] = .link(content: content, target: target)
        default:
            break
        }
    }
}
