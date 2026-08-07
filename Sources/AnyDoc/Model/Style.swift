/// Fully resolved character style. Tri-state deltas exist only during
/// frontend resolution; by the time content reaches the model every toggle
/// has a definite value.
public struct Style: Sendable, Equatable {
    /// Bold weight.
    public var bold: Bool
    /// Italic or oblique.
    public var italic: Bool
    /// Struck through.
    public var strike: Bool
    /// Monospace, from a code or teletype character style.
    public var code: Bool

    public init(bold: Bool = false, italic: Bool = false, strike: Bool = false, code: Bool = false) {
        self.bold = bold
        self.italic = italic
        self.strike = strike
        self.code = code
    }

    /// No toggle set.
    public static let plain = Style()
}
