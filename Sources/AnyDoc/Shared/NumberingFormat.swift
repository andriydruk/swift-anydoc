/// Shared list-number pattern IR.
///
/// A level's number text is a sequence of literal pieces and level
/// references, rendered against the live counter values. Every frontend
/// resolves its native syntax onto this one form: WordprocessingML
/// `w:lvlText` (`%1.%2)`), the DOC `xst` placeholder string, RTF
/// `\leveltext`/`\levelnumbers`, and ODF prefix/suffix/display-levels.
/// Rendering returns `nil` when the pattern reproduces the default label
/// the renderer builds from marker + value alone, so native Markdown list
/// numbering is used whenever it is faithful.

/// One piece of a level's number text: literal characters, or the current
/// number of a (zero-based) level.
enum NumberText: Equatable {
    case literal(String)
    case level(UInt8)
}

/// A level's resolved number pattern.
struct NumberPattern: Equatable {
    /// Empty = no pattern known; the marker kind's default label applies.
    var text: [NumberText] = []
    /// Legal numbering (`w:isLgl`, LVLF `fLegal`): referenced levels render
    /// as decimal regardless of their own format.
    var legal: Bool = false

    init(text: [NumberText] = [], legal: Bool = false) {
        self.text = text
        self.legal = legal
    }
}

/// Parse WordprocessingML-style percent patterns (`%1`–`%9` level
/// references, everything else literal) into pattern tokens.
func parsePercentPattern(_ text: String) -> [NumberText] {
    var out: [NumberText] = []
    let scalars = Array(text.unicodeScalars)
    var i = 0
    while i < scalars.count {
        let c = scalars[i]
        i += 1
        if c == "%", i < scalars.count, scalars[i].isAsciiDigit {
            let d = scalars[i].value - Unicode.Scalar("0").value
            if (1...9).contains(d) {
                i += 1
                out.append(.level(UInt8(d - 1)))
                continue
            }
        }
        if case .literal(var s) = out.last {
            s.unicodeScalars.append(c)
            out[out.count - 1] = .literal(s)
        } else {
            out.append(.literal(String(c)))
        }
    }
    return out
}

/// Render a pattern against the current sequence values. `levelMarker` and
/// `levelValue` supply each referenced level's marker kind and current
/// ordinal (the level's start value when it has not begun counting).
/// `nil` when the result matches the default label produced from the own
/// level's marker and value.
func compositeLabel(
    _ pattern: NumberPattern,
    ownMarker: MarkerKind,
    ownValue: UInt64,
    levelMarker: (Int) -> MarkerKind,
    levelValue: (Int) -> UInt64
) -> String? {
    if pattern.text.isEmpty {
        return nil
    }
    var out = ""
    for piece in pattern.text {
        switch piece {
        case .literal(let s):
            out += s
        case .level(let l):
            let l = Int(l)
            let kind = pattern.legal ? MarkerKind.decimal : levelMarker(l)
            out += kind.ordinal(levelValue(l))
        }
    }
    return out == ownMarker.label(ownValue) ? nil : out
}
