/// PresentationML text-property cascade: run properties resolve through
/// paragraph `pPr` -> shape `lstStyle` -> layout placeholder -> master
/// placeholder / `txStyles` -> presentation `defaultTextStyle`, with
/// explicit-off states honored at every layer.

enum PptxCascade {
    static let levels = 9

    enum Bullet: Equatable {
        /// Not specified at this layer; inherit from the next one.
        case inherit
        /// Explicitly no bullet (`a:buNone`).
        case none
        /// Character bullet (`a:buChar`).
        case char
        /// Auto-numbered (`a:buAutoNum`).
        case autoNum(marker: MarkerKind, start: UInt64, wrap: NumWrap)
    }

    /// The punctuation an `ST_TextAutoNumberScheme` wraps around the ordinal.
    enum NumWrap: Equatable {
        /// `1.` — matches the renderer's default label.
        case period
        /// `1)`
        case parenR
        /// `(1)`
        case parenBoth
        /// Bare `1`.
        case plain

        /// The literal marker label for ordinal `n`; `nil` when the default
        /// label (`n.`) is already faithful.
        func label(_ marker: MarkerKind, _ n: UInt64) -> String? {
            switch self {
            case .period: nil
            case .parenR: "\(marker.ordinal(n)))"
            case .parenBoth: "(\(marker.ordinal(n)))"
            case .plain: marker.ordinal(n)
            }
        }
    }

    struct TextProps {
        var delta: StyleDelta
        var bullet: Bullet

        init(delta: StyleDelta = StyleDelta(), bullet: Bullet = .inherit) {
            self.delta = delta
            self.bullet = bullet
        }

        /// Overlay `over` on `self`: explicit values win, `inherit` falls
        /// through.
        func merge(_ over: TextProps) -> TextProps {
            TextProps(
                delta: delta.merge(over.delta),
                bullet: over.bullet == .inherit ? bullet : over.bullet)
        }
    }

    /// Per-level text properties from a `lstStyle`-shaped element
    /// (`a:lvl1pPr`..`a:lvl9pPr` children).
    struct LevelStyle {
        var levels: [TextProps]

        init() {
            levels = Array(repeating: TextProps(), count: PptxCascade.levels)
        }

        func level(_ lvl: Int) -> TextProps {
            levels[min(lvl, PptxCascade.levels - 1)]
        }
    }

    static func parseLevelStyles(_ elem: XmlElement?) -> LevelStyle {
        var out = LevelStyle()
        guard let elem else {
            return out
        }
        for i in 0..<levels {
            let name = "lvl\(i + 1)pPr"
            if let ppr = elem.childElements.first(where: { $0.named(Ns.a, name) }) {
                out.levels[i] = paragraphProps(ppr)
            }
        }
        return out
    }

    /// Properties carried by one `pPr`-shaped element (direct paragraph
    /// properties or one `lvlNpPr` level).
    static func paragraphProps(_ ppr: XmlElement) -> TextProps {
        let bullet: Bullet
        if ppr.find(Ns.a, "buNone") != nil {
            bullet = .none
        } else if let auto = ppr.find(Ns.a, "buAutoNum") {
            let scheme = auto.attr(Ns.a, "type") ?? ""
            let marker: MarkerKind
            if scheme.hasPrefix("alphaLc") {
                marker = .lowerAlpha
            } else if scheme.hasPrefix("alphaUc") {
                marker = .upperAlpha
            } else if scheme.hasPrefix("romanLc") {
                marker = .lowerRoman
            } else if scheme.hasPrefix("romanUc") {
                marker = .upperRoman
            } else {
                marker = .decimal
            }
            let wrap: NumWrap
            if scheme.hasSuffix("ParenBoth") {
                wrap = .parenBoth
            } else if scheme.hasSuffix("ParenR") {
                wrap = .parenR
            } else if scheme.hasSuffix("Plain") {
                wrap = .plain
            } else {
                wrap = .period
            }
            // ST_TextBulletStartAtNum: 1..=32767; untrusted values are clamped
            // so counters can never overflow.
            let start = auto.attr(Ns.a, "startAt")
                .flatMap { Int64($0) }
                .map { UInt64(min(max($0, 1), 32767)) } ?? 1
            bullet = .autoNum(marker: marker, start: start, wrap: wrap)
        } else if ppr.find(Ns.a, "buChar") != nil {
            bullet = .char
        } else {
            bullet = .inherit
        }
        let delta = ppr.find(Ns.a, "defRPr").map(rprDelta) ?? StyleDelta()
        return TextProps(delta: delta, bullet: bullet)
    }

    /// Delta from an `a:rPr`/`a:defRPr` element's attributes.
    static func rprDelta(_ rpr: XmlElement) -> StyleDelta {
        func onOff(_ name: String) -> Bool? {
            rpr.attr(Ns.a, name).map { $0 == "1" || $0 == "true" || $0 == "on" }
        }
        return StyleDelta(
            bold: onOff("b"),
            italic: onOff("i"),
            strike: rpr.attr(Ns.a, "strike").map { $0 == "sngStrike" || $0 == "dblStrike" },
            code: nil)
    }

    /// A placeholder shape's identity and level styles inside a layout/master.
    struct Placeholder {
        var phType: String
        var idx: String?
        var styles: LevelStyle
    }

    static func collectPlaceholders(_ spTree: XmlElement) -> [Placeholder] {
        var out: [Placeholder] = []
        for sp in spTree.descendants(Ns.p, "sp") {
            guard let ph = sp.firstDescendant(Ns.p, "ph") else {
                continue
            }
            let styles = parseLevelStyles(sp.find(Ns.p, "txBody")?.find(Ns.a, "lstStyle"))
            out.append(
                Placeholder(
                    phType: ph.attr(Ns.p, "type") ?? "body",
                    idx: ph.attr(Ns.p, "idx"),
                    styles: styles))
        }
        return out
    }

    /// Find the placeholder a shape inherits from: match by `idx` first, then
    /// by type (title variants unify).
    static func matchPlaceholder(
        _ placeholders: [Placeholder], _ phType: String, _ idx: String?
    ) -> Placeholder? {
        if let idx, let hit = placeholders.first(where: { $0.idx == idx }) {
            return hit
        }
        let cls = titleClass(phType)
        return placeholders.first(where: {
            titleClass($0.phType) == cls && (cls == .title || $0.phType == phType)
        }) ?? placeholders.first(where: { titleClass($0.phType) == cls })
    }

    enum TitleClass: Equatable {
        case title
        case body
    }

    static func titleClass(_ phType: String) -> TitleClass {
        switch phType {
        case "title", "ctrTitle": .title
        default: .body
        }
    }
}
