/// OOXML markup-compatibility (`mc:AlternateContent`) branch selection.

enum Mc {
    /// Pick the branch of an `mc:AlternateContent` to process: the first
    /// `mc:Choice` whose `Requires` namespaces are all supported, else the
    /// `mc:Fallback`.
    static func alternateBranch(_ alt: XmlElement, supported: [String]) -> XmlElement? {
        alt.findAll(Ns.mc, "Choice").first(where: { choiceSupported($0, supported) })
            ?? alt.find(Ns.mc, "Fallback")
    }

    private static func choiceSupported(_ choice: XmlElement, _ supported: [String]) -> Bool {
        guard let requires = choice.attr(Ns.mc, "Requires") else {
            return true
        }
        // Requires prefixes were resolved to namespace URIs at parse time, in
        // the element's own lexical scope; an unresolved prefix stays literal
        // and matches nothing.
        return requires.unicodeScalars.split(whereSeparator: \.isRustWhitespace)
            .allSatisfy { supported.contains(String($0)) }
    }
}
