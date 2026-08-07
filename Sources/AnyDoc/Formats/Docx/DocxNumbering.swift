/// WordprocessingML numbering: `numId -> w:num` (with level overrides) `->
/// abstractNum` (with `numStyleLink` indirection) `-> level`, plus the
/// document-order counters that produce each paragraph's effective number.

let docxNumberingLevels = 9

struct LevelDef {
    /// `nil` = suppressed numbering (`numFmt` of `none`).
    var marker: MarkerKind? = .bullet
    var start: UInt64 = 1
    /// `w:lvlRestart`: `nil` = restart when any shallower level appears,
    /// `0` = never restart, `n` = restart when a level with `ilvl < n`
    /// appears.
    var restart: UInt32? = nil
    /// `w:lvlText` (with `w:isLgl`) as the shared pattern IR.
    var pattern = NumberPattern()
}

private struct AbstractNum {
    var levels: [LevelDef]
    /// Paragraph style each level binds to via `w:lvl > w:pStyle`.
    var pstyles: [String?]
    var numStyleLink: String?
}

struct NumberingInstance {
    var levels: [LevelDef]
    var pstyles: [String?]

    /// The level bound to a paragraph style through the abstract levels'
    /// `w:pStyle` references.
    func styleLevel(_ styleId: String) -> Int? {
        pstyles.firstIndex(where: { $0 == styleId })
    }
}

struct DocxNumbering {
    var instances: [UInt64: NumberingInstance] = [:]

    init() {}

    func instance(_ numId: UInt64) -> NumberingInstance? {
        instances[numId]
    }
}

/// `styleNumId` maps a numbering style id to the `numId` its own `numPr`
/// references (the `numStyleLink`/`styleLink` indirection contract).
func parseNumbering(
    _ root: XmlElement,
    styleNumId: (String) -> UInt64?
) throws -> DocxNumbering {
    var abstracts: [String: AbstractNum] = [:]
    for abs in root.findAll(Ns.w, "abstractNum") {
        guard let id = abs.attr(Ns.w, "abstractNumId") else {
            continue
        }
        var levels = [LevelDef](repeating: LevelDef(), count: docxNumberingLevels)
        var pstyles = [String?](repeating: nil, count: docxNumberingLevels)
        for lvl in abs.findAll(Ns.w, "lvl") {
            let ilvl = lvl.attr(Ns.w, "ilvl").flatMap { UInt64($0) } ?? 0
            if ilvl < UInt64(docxNumberingLevels) {
                levels[Int(ilvl)] = parseLevel(lvl)
                pstyles[Int(ilvl)] = levelPstyle(lvl)
            }
        }
        let numStyleLink = abs.find(Ns.w, "numStyleLink")?.attr(Ns.w, "val")
        abstracts[id] = AbstractNum(levels: levels, pstyles: pstyles, numStyleLink: numStyleLink)
    }

    // First pass: direct abstract references per numId.
    var direct: [UInt64: (absId: String, num: XmlElement)] = [:]
    for num in root.findAll(Ns.w, "num") {
        guard let numId = num.attr(Ns.w, "numId").flatMap({ UInt64($0) }),
            let absId = num.find(Ns.w, "abstractNumId")?.attr(Ns.w, "val")
        else {
            continue
        }
        direct[numId] = (absId: absId, num: num)
    }

    var numbering = DocxNumbering()
    for (numId, entry) in direct.sorted(by: { $0.key < $1.key }) {
        let (absId, numElem) = entry
        guard let abs = try resolveAbstract(absId, abstracts, direct, styleNumId) else {
            Log.warn("numbering instance \(numId) references unknown abstract \(rustDebugString(absId))")
            continue
        }
        var levels = abs.levels
        var pstyles = abs.pstyles
        for over in numElem.findAll(Ns.w, "lvlOverride") {
            let ilvlRaw = over.attr(Ns.w, "ilvl").flatMap { UInt64($0) } ?? 0
            if ilvlRaw >= UInt64(docxNumberingLevels) {
                continue
            }
            let ilvl = Int(ilvlRaw)
            // A nested w:lvl replaces the level wholesale; startOverride is
            // applied last so it survives the replacement.
            if let lvl = over.find(Ns.w, "lvl") {
                levels[ilvl] = parseLevel(lvl)
                pstyles[ilvl] = levelPstyle(lvl)
            }
            if let start = over.find(Ns.w, "startOverride")?
                .attr(Ns.w, "val")
                .flatMap(parseStart)
            {
                levels[ilvl].start = start
            }
        }
        numbering.instances[numId] = NumberingInstance(levels: levels, pstyles: pstyles)
    }
    return numbering
}

/// Resolve an abstract definition, following `numStyleLink` indirection:
/// abstract -> numbering style -> that style's `numId` -> its abstract.
private func resolveAbstract(
    _ absId: String,
    _ abstracts: [String: AbstractNum],
    _ direct: [UInt64: (absId: String, num: XmlElement)],
    _ styleNumId: (String) -> UInt64?
) throws -> AbstractNum? {
    var seen: [String] = []
    var current = absId
    while true {
        if seen.contains(current) {
            throw ConvertError.malformed(
                "numbering indirection cycle at abstract \(rustDebugString(current))")
        }
        seen.append(current)
        guard let abs = abstracts[current] else {
            return nil
        }
        guard let styleId = abs.numStyleLink else {
            return abs
        }
        let linked = styleNumId(styleId).flatMap { direct[$0]?.absId }
        guard let next = linked else {
            return abs
        }
        current = next
    }
}

/// The paragraph style a `w:lvl` binds to (`w:pStyle`).
private func levelPstyle(_ lvl: XmlElement) -> String? {
    lvl.find(Ns.w, "pStyle")?.attr(Ns.w, "val")
}

/// `ST_DecimalNumber` is `xsd:int`; values are clamped to the non-negative
/// range so untrusted starting values can never overflow counters.
private func parseStart(_ v: String) -> UInt64? {
    guard let n = Int64(v) else { return nil }
    return UInt64(min(max(n, 0), Int64(Int32.max)))
}

private func parseLevel(_ lvl: XmlElement) -> LevelDef {
    let fmt = lvl.find(Ns.w, "numFmt")?.attr(Ns.w, "val") ?? "bullet"
    let marker: MarkerKind?
    switch fmt {
    case "none": marker = nil
    case "bullet": marker = .bullet
    case "lowerLetter": marker = .lowerAlpha
    case "upperLetter": marker = .upperAlpha
    case "lowerRoman": marker = .lowerRoman
    case "upperRoman": marker = .upperRoman
    default: marker = .decimal
    }
    let start = lvl.find(Ns.w, "start")?
        .attr(Ns.w, "val")
        .flatMap(parseStart) ?? 1
    let restart = lvl.find(Ns.w, "lvlRestart")?
        .attr(Ns.w, "val")
        .flatMap { UInt32($0) }
    // The number text pattern applies to ordered levels; bullet lvlText is
    // the glyph itself, not a pattern.
    let text: [NumberText]
    if let m = marker, m.ordered {
        text = lvl.find(Ns.w, "lvlText")?
            .attr(Ns.w, "val")
            .map(parsePercentPattern) ?? []
    } else {
        text = []
    }
    let legal = onOff(lvl, "isLgl") == true
    return LevelDef(
        marker: marker, start: start, restart: restart,
        pattern: NumberPattern(text: text, legal: legal))
}

/// Document-order numbering state: one counter array per instance, shared
/// across interruptions so continuation works, with `lvlRestart` semantics.
struct DocxCounters {
    private var state: [UInt64: InstanceState] = [:]

    init() {}

    private struct InstanceState {
        var value = [UInt64](repeating: 0, count: docxNumberingLevels)
        var initialized = [Bool](repeating: false, count: docxNumberingLevels)
        var restartPending = [Bool](repeating: false, count: docxNumberingLevels)
    }

    /// Advance the counter for a paragraph at (`numId`, `ilvl`) and return
    /// its effective number plus, when the level's number text is not
    /// reproducible from the marker kind alone, the composite label.
    mutating func next(
        numId: UInt64, ilvl: Int, instance: NumberingInstance
    ) -> (UInt64, String?) {
        let ilvl = min(ilvl, docxNumberingLevels - 1)
        var st = state[numId] ?? InstanceState()
        let def = instance.levels[ilvl]
        if !st.initialized[ilvl] || st.restartPending[ilvl] {
            st.value[ilvl] = def.start
            st.initialized[ilvl] = true
            st.restartPending[ilvl] = false
        } else {
            st.value[ilvl] = st.value[ilvl].saturatingAdding(1)
        }
        // Using level `ilvl` schedules restarts for deeper levels according
        // to their lvlRestart settings.
        for deeper in (ilvl + 1)..<docxNumberingLevels {
            let triggered: Bool
            switch instance.levels[deeper].restart {
            case nil: triggered = true
            case .some(0): triggered = false
            case .some(let n): triggered = UInt32(ilvl) < n
            }
            if triggered {
                st.restartPending[deeper] = true
            }
        }
        let value = st.value[ilvl]
        var label: String? = nil
        if let marker = def.marker {
            label = compositeLabel(
                def.pattern,
                ownMarker: marker,
                ownValue: value,
                levelMarker: { l in
                    instance.levels[min(l, docxNumberingLevels - 1)].marker ?? .decimal
                },
                levelValue: { l in
                    let l = min(l, docxNumberingLevels - 1)
                    if st.initialized[l] && !st.restartPending[l] {
                        return st.value[l]
                    }
                    return instance.levels[l].start
                })
        }
        state[numId] = st
        return (value, label)
    }
}
