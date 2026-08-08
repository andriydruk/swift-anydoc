/// ODF style resolution: text/paragraph style chains as tri-state deltas
/// (so `font-weight: normal` can clear inherited bold), plus list styles
/// with per-level marker kinds and start values.
///
/// Chains are keyed by `family\0name` strings because definitions come
/// from two separately parsed trees (`styles.xml` and `content.xml`).

let odfListLevels = 10

struct OdfListLevel {
    var marker: MarkerKind
    var start: UInt64
    /// `style:num-prefix` literal text before the number.
    var prefix: String
    /// `style:num-suffix` literal text after the number; absent means the
    /// bare number is displayed.
    var suffix: String?
    /// `text:display-levels`: how many levels (ending at this one) display,
    /// joined by `.`.
    var displayLevels: Int

    init(
        marker: MarkerKind = .bullet,
        start: UInt64 = 1,
        prefix: String = "",
        suffix: String? = nil,
        displayLevels: Int = 1
    ) {
        self.marker = marker
        self.start = start
        self.prefix = prefix
        self.suffix = suffix
        self.displayLevels = displayLevels
    }

    /// The level's number text as the shared pattern IR, referencing the
    /// trailing `display_levels` levels.
    func pattern(_ depth: Int) -> NumberPattern {
        var text: [NumberText] = []
        if !prefix.isEmpty {
            text.append(.literal(prefix))
        }
        let shown = min(max(displayLevels, 1), depth + 1)
        for i in 0..<shown {
            let level = depth + 1 - shown + i
            if i > 0 {
                text.append(.literal("."))
            }
            // Rust writes `level as u8`, a truncating cast; callers clamp
            // `depth` to the level-array bound so it never actually wraps.
            text.append(.level(UInt8(truncatingIfNeeded: level)))
        }
        if let suffix, !suffix.isEmpty {
            text.append(.literal(suffix))
        }
        return NumberPattern(text: text, legal: false)
    }
}

private func odfStyleKey(_ family: String, _ name: String) -> String {
    "\(family)\u{0}\(name)"
}

final class OdfStyles {
    private var raw: [String: (def: XmlElement, parent: String?)] = [:]
    private var memo: [String: StyleDelta] = [:]
    private var listStyles: [String: [OdfListLevel]] = [:]
    /// `text:outline-style`: heading numbering per outline level.
    private var outline: [OdfListLevel]? = nil
    /// `style:default-style` per family: the base beneath every named chain
    /// (and the delta for unstyled content of that family).
    private var defaults: [String: StyleDelta] = [:]

    init() {}

    /// Collect styles from one document tree (`styles.xml` or `content.xml`).
    /// Call for styles.xml first so content.xml definitions chain onto it.
    func collect(_ tree: XmlElement) {
        for root in tree.childElements {
            for section in root.childElements {
                if !(section.named(Ns.office, "automatic-styles")
                    || section.named(Ns.office, "styles"))
                {
                    continue
                }
                for style in section.childElements {
                    if style.named(Ns.style, "default-style"),
                        let family = style.attr(Ns.style, "family")
                    {
                        defaults[family] = textPropertiesDelta(style)
                    }
                    if style.named(Ns.style, "style"),
                        let name = style.attr(Ns.style, "name")
                    {
                        let family = style.attr(Ns.style, "family") ?? ""
                        let parent = style.attr(Ns.style, "parent-style-name")
                            .map { odfStyleKey(family, $0) }
                        raw[odfStyleKey(family, name)] = (style, parent)
                    }
                    if style.named(Ns.text, "list-style"),
                        let name = style.attr(Ns.style, "name")
                    {
                        listStyles[name] = parseListStyle(style)
                    }
                    if style.named(Ns.text, "outline-style") {
                        outline = parseListStyle(style)
                    }
                }
            }
        }
    }

    /// Cumulative delta of a style through its `parent-style-name` chain,
    /// over the family's `style:default-style` base.
    func delta(_ family: String, _ name: String) throws -> StyleDelta {
        let id = odfStyleKey(family, name)
        if let hit = memo[id] {
            return hit
        }
        var chain: [String] = []
        var visited: Set<String> = []
        var cursor: String? = raw[id] != nil ? id : nil
        while let current = cursor {
            if !visited.insert(current).inserted {
                throw ConvertError.malformed(
                    "style inheritance cycle at \(rustDebugString(current))")
            }
            chain.append(current)
            cursor = nil
            if let parent = raw[current]?.parent, raw[parent] != nil {
                cursor = parent
            }
        }
        var delta = defaults[family] ?? StyleDelta()
        for current in chain.reversed() {
            guard let (def, _) = raw[current] else { continue }
            delta = delta.merge(textPropertiesDelta(def))
            memo[current] = delta
        }
        return delta
    }

    /// The block container a paragraph style names, walking
    /// `parent-style-name`: an automatic style carries the name on the
    /// named style it derives from.
    func blockStyle(_ name: String) -> BlockStyle? {
        var id = odfStyleKey("paragraph", name)
        var visited: Set<String> = []
        while visited.insert(id).inserted {
            guard let (def, parent) = raw[id] else { return nil }
            if let hit = def.attr(Ns.style, "name").flatMap(blockStyleFromName) {
                return hit
            }
            guard let parent else { return nil }
            id = parent
        }
        return nil
    }

    func listLevel(_ styleName: String, _ depth: Int) -> OdfListLevel {
        guard let levels = listStyles[styleName], depth >= 0, depth < levels.count else {
            return OdfListLevel()
        }
        return levels[depth]
    }

    /// The full level array of a list style, for composite-label rendering.
    func listLevels(_ styleName: String) -> [OdfListLevel]? {
        listStyles[styleName]
    }

    /// The document's heading numbering (`text:outline-style`) levels.
    func outlineLevels() -> [OdfListLevel]? {
        outline
    }
}

/// Clamp an untrusted start value so counters can never overflow.
func odfParseStart(_ v: String) -> UInt64? {
    UInt64(v).map { min($0, UInt64(UInt32.max)) }
}

/// Levels of a `text:list-style` or `text:outline-style` (the level
/// elements differ in name, not in shape).
private func parseListStyle(_ style: XmlElement) -> [OdfListLevel] {
    var levels = [OdfListLevel](repeating: OdfListLevel(), count: odfListLevels)
    for lvl in style.childElements {
        guard let n = lvl.attr(Ns.text, "level").flatMap({ UInt64($0) }) else {
            continue
        }
        if !(n >= 1 && n <= UInt64(odfListLevels)) {
            continue
        }
        let slot = Int(n) - 1
        if lvl.named(Ns.text, "list-level-style-number")
            || lvl.named(Ns.text, "outline-level-style")
        {
            switch lvl.attr(Ns.style, "num-format") {
            case "a": levels[slot].marker = .lowerAlpha
            case "A": levels[slot].marker = .upperAlpha
            case "i": levels[slot].marker = .lowerRoman
            case "I": levels[slot].marker = .upperRoman
            case "": levels[slot].marker = .bullet
            default: levels[slot].marker = .decimal
            }
            levels[slot].start = lvl.attr(Ns.text, "start-value").flatMap(odfParseStart) ?? 1
            levels[slot].prefix = lvl.attr(Ns.style, "num-prefix") ?? ""
            levels[slot].suffix = lvl.attr(Ns.style, "num-suffix")
            // Rust parses a usize (u64-wide here); values past `Int.max`
            // clamp, and every use clamps far below that anyway.
            levels[slot].displayLevels = lvl.attr(Ns.text, "display-levels")
                .flatMap { UInt64($0) }
                .map { Int(min($0, UInt64(Int.max))) } ?? 1
        }
    }
    return levels
}

/// Delta carried by a style's `style:text-properties`.
func textPropertiesDelta(_ elem: XmlElement) -> StyleDelta {
    guard let props = elem.find(Ns.style, "text-properties") else {
        return StyleDelta()
    }
    return StyleDelta(
        bold: props.attr(Ns.fo, "font-weight")
            .map { w in w == "bold" || (UInt32(w).map { $0 >= 600 } ?? false) },
        italic: props.attr(Ns.fo, "font-style").map { $0 == "italic" || $0 == "oblique" },
        strike: props.attr(Ns.style, "text-line-through-style").map { $0 != "none" },
        code: nil)
}
