/// The marker family a list level uses in the source document.
public enum MarkerKind: Sendable, Equatable {
    /// Unordered.
    case bullet
    /// `1`, `2`, `3`.
    case decimal
    /// `a`, `b`, `c`.
    case lowerAlpha
    /// `A`, `B`, `C`.
    case upperAlpha
    /// `i`, `ii`, `iii`.
    case lowerRoman
    /// `I`, `II`, `III`.
    case upperRoman

    /// True for every kind but `bullet`.
    public var ordered: Bool { self != .bullet }

    /// The marker text for ordinal `n` (1-based), without trailing space:
    /// `3.`, `c.`, `iv.`; bullets have no ordinal text.
    public func label(_ n: UInt64) -> String {
        switch self {
        case .bullet: "-"
        default: "\(ordinal(n))."
        }
    }

    /// The bare ordinal text for `n` without punctuation: `3`, `c`, `iv`.
    public func ordinal(_ n: UInt64) -> String {
        switch self {
        case .bullet: "-"
        case .decimal: String(n)
        case .lowerAlpha: alpha(n)
        case .upperAlpha: alpha(n).uppercased()
        case .lowerRoman: roman(n)
        case .upperRoman: roman(n).uppercased()
        }
    }
}

/// 1 -> `a`, 26 -> `z`, 27 -> `aa` (bijective base 26).
private func alpha(_ n: UInt64) -> String {
    if n == 0 { return "0" }
    var n = n
    var out: [UInt8] = []
    while n > 0 {
        n -= 1
        out.append(UInt8(ascii: "a") + UInt8(n % 26))
        n /= 26
    }
    return String(decoding: out.reversed(), as: UTF8.self)
}

private func roman(_ n: UInt64) -> String {
    if n == 0 || n > 3999 { return String(n) }
    let numerals: [(UInt64, String)] = [
        (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
        (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
    ]
    var n = n
    var out = ""
    for (value, numeral) in numerals {
        while n >= value {
            out += numeral
            n -= value
        }
    }
    return out
}

/// A fully resolved list: numbering identity and marker resolution happen in
/// the frontends, which split runs whenever the list instance or marker kind
/// changes.
public struct List: Sendable {
    /// The marker family every item in this run uses.
    public var marker: MarkerKind
    /// Ordinal of the first item, from the source's own numbering.
    public var start: UInt64
    /// The items, in order.
    public var items: [ListItem]

    public init(marker: MarkerKind, start: UInt64, items: [ListItem]) {
        self.marker = marker
        self.start = start
        self.items = items
    }

    /// True when this list's marker is a numbered one.
    public var ordered: Bool { marker.ordered }
}

/// One item of a `List`, which may hold nested blocks including further lists.
public struct ListItem: Sendable {
    /// The item's content.
    public var blocks: [Block]
    /// Checkbox state for a task list item; `nil` when the item carries no
    /// checkbox.
    public var checked: Bool?
    /// Literal marker text that overrides the level marker when the source
    /// number text cannot be reproduced from `marker` + position alone
    /// (composite number text such as `1-a)`).
    public var markerLabel: String?

    public init(blocks: [Block] = [], checked: Bool? = nil, markerLabel: String? = nil) {
        self.blocks = blocks
        self.checked = checked
        self.markerLabel = markerLabel
    }
}
