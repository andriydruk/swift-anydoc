/// WordprocessingML style table.
///
/// Bold/italic/strike are *toggle properties* (ECMA-376 §17.7.3): within the
/// style hierarchy a `true` specification toggles the inherited value and a
/// `false` specification leaves it unchanged, so the style layers contribute
/// a true-count *parity* XORed over the `docDefaults` base. Direct run
/// formatting is absolute on/off.

/// Per-property parity of `true` toggle specifications in a style chain.
struct Toggles: Equatable {
    var bold = false
    var italic = false
    var strike = false

    init(bold: Bool = false, italic: Bool = false, strike: Bool = false) {
        self.bold = bold
        self.italic = italic
        self.strike = strike
    }

    func xor(_ other: Toggles) -> Toggles {
        Toggles(
            bold: bold != other.bold,
            italic: italic != other.italic,
            strike: strike != other.strike)
    }

    func applyOver(_ base: Style) -> Style {
        Style(
            bold: base.bold != bold,
            italic: base.italic != italic,
            strike: base.strike != strike,
            code: base.code)
    }
}

struct DocxStyles {
    private var chains = StyleChains<XmlElement>()
    /// docDefaults as absolute values (the base the toggles flip over).
    var docDefaults: Style = .plain

    init() {}

    static func parseOpt(_ root: XmlElement?) -> DocxStyles {
        switch root {
        case .some(let root): parse(root)
        case nil: DocxStyles()
        }
    }

    static func parse(_ root: XmlElement) -> DocxStyles {
        var styles = DocxStyles()
        for style in root.findAll(Ns.w, "style") {
            if let id = style.attr(Ns.w, "styleId") {
                let parent = style.find(Ns.w, "basedOn")?.attr(Ns.w, "val")
                styles.chains.insert(id, style, parent: parent)
            }
        }
        styles.docDefaults = root.find(Ns.w, "docDefaults")
            .flatMap { $0.find(Ns.w, "rPrDefault") }
            .flatMap { $0.find(Ns.w, "rPr") }
            .map { rprDelta($0).resolve() } ?? .plain
        return styles
    }

    /// The parity of `true` toggle specifications along a style's `basedOn`
    /// chain. A `false` in a style leaves the inherited value unchanged.
    func runToggles(_ id: String) throws -> Toggles {
        var parity = Toggles()
        _ = try chains.walk(id) { style -> Void? in
            if let rpr = style.find(Ns.w, "rPr") {
                parity = parity.xor(
                    Toggles(
                        bold: onOff(rpr, "b") == true,
                        italic: onOff(rpr, "i") == true,
                        strike: onOff(rpr, "strike") == true || onOff(rpr, "dstrike") == true))
            }
            return nil
        }
        return parity
    }

    /// Heading level a paragraph style resolves to, from its name
    /// (`heading N`, `Title`) or an `outlineLvl`, inherited through
    /// `basedOn`. Tri-state: `.some(nil)` when the nearest specification is
    /// the explicit off value (`outlineLvl` 9), which stops inheritance.
    func headingLevel(_ id: String) throws -> UInt8?? {
        try chains.walk(id) { style -> UInt8?? in
            let name = (style.find(Ns.w, "name")?.attr(Ns.w, "val") ?? "").asciiLowercased()
            if name.hasPrefix("heading "),
                let level = UInt8(name.dropFirst("heading ".count).rustTrim())
            {
                return .some(.some(level))
            }
            if name == "title" {
                return .some(.some(1))
            }
            guard
                let level = style.find(Ns.w, "pPr")?
                    .find(Ns.w, "outlineLvl")?
                    .attr(Ns.w, "val")
                    .flatMap({ UInt8($0) })
            else {
                return .none
            }
            return level < 9 ? .some(.some(level + 1)) : .some(.none)
        }
    }

    /// The block container a paragraph style names, inherited through
    /// `basedOn` (Word's `Quote`, Pandoc's `Source Code`, ...).
    func blockStyle(_ id: String) throws -> BlockStyle? {
        try chains.walk(id) { style -> BlockStyle? in
            guard let name = style.find(Ns.w, "name")?.attr(Ns.w, "val") else { return nil }
            return blockStyleFromName(name)
        }
    }

    /// The `numId` a paragraph style contributes, inherited through
    /// `basedOn`. An `ilvl` inside a style's `numPr` is ignored per ECMA-376
    /// §17.3.1.19 - the effective level comes from the abstract levels'
    /// `w:pStyle` bindings (`styleNumberingLevel`).
    func styleNumPr(_ id: String) throws -> UInt64? {
        try chains.walk(id) { style -> UInt64? in
            style.find(Ns.w, "pPr")?
                .find(Ns.w, "numPr")?
                .find(Ns.w, "numId")?
                .attr(Ns.w, "val")
                .flatMap { UInt64($0) }
        }
    }

    /// The numbering level a paragraph style binds to: the first style along
    /// the `basedOn` chain (child first) that one of the instance's abstract
    /// levels references via `w:pStyle`.
    func styleNumberingLevel(_ id: String, _ instance: NumberingInstance) throws -> Int? {
        try chains.walk(id) { style -> Int? in
            guard let styleId = style.attr(Ns.w, "styleId") else { return nil }
            return instance.styleLevel(styleId)
        }
    }

    /// The `numId` referenced by a numbering style's own `numPr`
    /// (`numStyleLink` contract), without inheritance.
    func directNumId(_ id: String) -> UInt64? {
        chains.definition(id)?
            .find(Ns.w, "pPr")?
            .find(Ns.w, "numPr")?
            .find(Ns.w, "numId")?
            .attr(Ns.w, "val")
            .flatMap { UInt64($0) }
    }
}

/// A `w:rPr` element as a tri-state delta - used only for *direct* run
/// formatting, where specifications are absolute on/off.
func rprDelta(_ rpr: XmlElement) -> StyleDelta {
    let s = onOff(rpr, "strike")
    let d = onOff(rpr, "dstrike")
    let strike: Bool?
    if s != nil || d != nil {
        strike = (s ?? false) || (d ?? false)
    } else {
        strike = nil
    }
    return StyleDelta(bold: onOff(rpr, "b"), italic: onOff(rpr, "i"), strike: strike, code: nil)
}

/// ST_OnOff: `1`/`true`/`on` (or no value) are true; `0`/`false`/`off` are
/// false; an absent element is unspecified.
func onOff(_ parent: XmlElement, _ name: String) -> Bool? {
    guard let elem = parent.find(Ns.w, name) else { return nil }
    switch elem.attr(Ns.w, "val") {
    case "0", "false", "off", "none": return false
    default: return true
    }
}
