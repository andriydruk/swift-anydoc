/// RTF prelude tables parsed into typed definitions: the font table (with
/// per-font charsets), the style sheet, and the list/list-override tables.
///
/// These are read up front, before the body, because everything in the body
/// depends on them: which bytes decode with which code page, which
/// paragraphs are headings, and what number each list item carries.

let rtfListLevels = 9

struct ListLevelDef {
    var marker: MarkerKind? = .bullet
    var start: UInt64 = 1
    /// `\leveltext` with `\levelnumbers` placeholders and `\levellegal`.
    var pattern = NumberPattern()
}

struct ListDef {
    var levels: [ListLevelDef] = Array(repeating: ListLevelDef(), count: rtfListLevels)
}

struct StyleDef {
    var outline: UInt8?
    var delta = StyleDelta()
    /// The block container the style's name designates.
    var block: BlockStyle?
}

struct RtfPrelude {
    /// Font number -> encoding, from `\fcharsetN`.
    var fonts: [Int32: LegacyEncoding] = [:]
    /// Paragraph style id (`\sN`) -> definition.
    var styles: [Int32: StyleDef] = [:]
    /// `\lsN` -> resolved list definition (through the override table).
    var lists: [Int32: ListDef] = [:]
}

func parseRtfPrelude(_ bytes: [UInt8], _ defaultEncoding: LegacyEncoding) -> RtfPrelude {
    var prelude = RtfPrelude()
    for group in rtfDestinationGroups(bytes, "fonttbl") {
        parseFontTable(group, &prelude.fonts, defaultEncoding)
    }
    for group in rtfDestinationGroups(bytes, "stylesheet") {
        parseStylesheet(group, &prelude.styles, defaultEncoding)
    }
    var byListId: [Int32: ListDef] = [:]
    for group in rtfDestinationGroups(bytes, "listtable") {
        parseListTable(group, &byListId, defaultEncoding)
    }
    for group in rtfDestinationGroups(bytes, "listoverridetable") {
        parseListOverrides(group, byListId, &prelude.lists, defaultEncoding)
    }
    return prelude
}

/// Build a number pattern from a `\leveltext` payload (first byte = length,
/// then the characters) and the 1-based placeholder positions listed in
/// `\levelnumbers` (each placeholder byte is a zero-based level index).
private func buildPattern(
    _ text: [UInt8], _ positions: [UInt8], _ encoding: LegacyEncoding
) -> [NumberText] {
    guard let count = text.first else { return [] }
    let rest = Array(text.dropFirst())
    let chars = rest.prefix(min(rest.count, Int(count)))
    var out: [NumberText] = []
    var literal: [UInt8] = []
    func flush() {
        if !literal.isEmpty {
            out.append(.literal(encoding.decode(literal)))
            literal = []
        }
    }
    for (i, b) in chars.enumerated() {
        if b <= 8, positions.contains(UInt8(truncatingIfNeeded: i + 1)) {
            flush()
            out.append(.level(b))
        } else {
            literal.append(b)
        }
    }
    flush()
    return out
}

/// Collector for the byte payloads of `\leveltext` / `\levelnumbers`
/// destinations inside one level group.
private struct LevelTextCollector {
    /// Which destination is currently receiving bytes.
    enum Active { case text, numbers }
    var active: Active?
    var text: [UInt8] = []
    var numbers: [UInt8] = []
    var legal = false

    mutating func byte(_ b: UInt8) {
        switch active {
        case .text: text.append(b)
        case .numbers: numbers.append(b)
        case nil: break
        }
    }

    /// The finished pattern for an ordered level; bullets carry glyph text,
    /// not a pattern.
    mutating func finish(_ marker: MarkerKind?, _ encoding: LegacyEncoding) -> NumberPattern {
        let pattern: NumberPattern
        if let marker, marker.ordered {
            pattern = NumberPattern(text: buildPattern(text, numbers, encoding), legal: legal)
        } else {
            pattern = NumberPattern()
        }
        self = LevelTextCollector()
        return pattern
    }
}

private func parseFontTable(
    _ group: [UInt8], _ fonts: inout [Int32: LegacyEncoding], _ defaultEncoding: LegacyEncoding
) {
    var lexer = RtfLexer(group)
    var current: Int32?
    while let token = lexer.next() {
        guard case .word(let name, let param) = token else { continue }
        switch name {
        case "f": current = param
        case "fcharset":
            if let f = current, let cs = param {
                fonts[f] = charsetEncoding(cs, default: defaultEncoding)
            }
        default: break
        }
    }
}

/// The null style id: `\sbasedon222` means "based on nothing".
private let nullStyleId: Int32 = 222

private func parseStylesheet(
    _ group: [UInt8], _ styles: inout [Int32: StyleDef], _ encoding: LegacyEncoding
) {
    var lexer = RtfLexer(group)
    var depth = 0
    var current: (id: Int32, def: StyleDef, base: Int32?)?
    var raw: [Int32: (def: StyleDef, base: Int32?)] = [:]
    // A style's name is the text at the end of its group, before the `;`.
    var name: [UInt8] = []
    while let token = lexer.next() {
        switch token {
        case .open:
            depth += 1
        case .close:
            if depth == 1, var entry = current {
                current = nil
                let text = encoding.decode(name)
                entry.def.block = blockStyleFromName(trimTrailingSemicolons(text))
                raw[entry.id] = (def: entry.def, base: entry.base)
            }
            name = []
            depth = max(0, depth - 1)
        case .hex(let b), .byte(let b):
            if depth == 1, current != nil {
                name.append(b)
            }
        case .word(let word, let param):
            switch word {
            case "s":
                current = (id: param ?? 0, def: StyleDef(), base: nil)
                name = []
            case "sbasedon":
                if current != nil {
                    current!.base = param.flatMap { $0 != nullStyleId ? $0 : nil }
                }
            case "outlinelevel":
                if current != nil, let n = param, (0..<9).contains(n) {
                    current!.def.outline = UInt8(n + 1)
                }
            case "b":
                if current != nil { current!.def.delta.bold = param != 0 }
            case "i":
                if current != nil { current!.def.delta.italic = param != 0 }
            default: break
            }
        default: break
        }
    }
    // Resolve every \sbasedon chain root-to-leaf: the child's own settings
    // win over inherited ones. A cycle is bounded by the visited set and
    // resolves from the acyclic prefix.
    for id in raw.keys {
        var chain: [StyleDef] = []
        var seen: Set<Int32> = []
        var cursor: Int32? = id
        while let cur = cursor {
            if !seen.insert(cur).inserted {
                Log.warn("style inheritance cycle at rtf style \(cur)")
                break
            }
            guard let entry = raw[cur] else { break }
            chain.append(entry.def)
            cursor = entry.base
        }
        var resolved = StyleDef()
        for def in chain.reversed() {
            resolved.delta = resolved.delta.merge(def.delta)
            resolved.outline = def.outline ?? resolved.outline
            resolved.block = def.block ?? resolved.block
        }
        styles[id] = resolved
    }
}

/// Rust `str::trim_end_matches(';')`: strip every trailing semicolon.
private func trimTrailingSemicolons(_ s: String) -> String {
    var view = Substring(s)
    while view.last == ";" { view = view.dropLast() }
    return String(view)
}

private func parseListTable(
    _ group: [UInt8], _ byListId: inout [Int32: ListDef], _ encoding: LegacyEncoding
) {
    var lexer = RtfLexer(group)
    var depth = 0
    var listDepth: Int?
    var levels = Array(repeating: ListLevelDef(), count: rtfListLevels)
    var levelIndex = 0
    var inLevel = false
    var listId: Int32?
    var collector = LevelTextCollector()
    while let token = lexer.next() {
        switch token {
        case .open:
            depth += 1
        case .close:
            // A leveltext/levelnumbers destination ends at its group.
            collector.active = nil
            if inLevel, let d = listDepth, depth == d + 1 {
                inLevel = false
                if levelIndex < rtfListLevels {
                    levels[levelIndex].pattern = collector.finish(levels[levelIndex].marker, encoding)
                }
                levelIndex += 1
            }
            if listDepth == depth {
                if let id = listId {
                    listId = nil
                    byListId[id] = ListDef(levels: levels)
                }
                levels = Array(repeating: ListLevelDef(), count: rtfListLevels)
                levelIndex = 0
                listDepth = nil
            }
            depth = max(0, depth - 1)
        case .word(let name, let param):
            switch name {
            case "list":
                listDepth = depth
                listId = nil
                levels = Array(repeating: ListLevelDef(), count: rtfListLevels)
                levelIndex = 0
            case "listid":
                if listDepth != nil { listId = param }
            case "listlevel":
                inLevel = true
                collector = LevelTextCollector()
            case "levelnfc", "levelnfcn":
                if inLevel, levelIndex < rtfListLevels {
                    levels[levelIndex].marker = markerForNfc(param ?? 0)
                }
            case "levelstartat":
                if inLevel, levelIndex < rtfListLevels, let n = param {
                    levels[levelIndex].start = UInt64(max(n, 0))
                }
            case "leveltext":
                if inLevel { collector.active = .text }
            case "levelnumbers":
                if inLevel { collector.active = .numbers }
            case "levellegal":
                if inLevel { collector.legal = param != 0 }
            default: break
            }
        case .hex(let b), .byte(let b):
            collector.byte(b)
        default: break
        }
    }
}

/// Raw override number text for one level.
private struct RawLevelText {
    var text: [UInt8]
    var numbers: [UInt8]
    var legal: Bool
}

private func parseListOverrides(
    _ group: [UInt8], _ byListId: [Int32: ListDef], _ lists: inout [Int32: ListDef],
    _ encoding: LegacyEncoding
) {
    var lexer = RtfLexer(group)
    var depth = 0
    var overDepth: Int?
    var lfoDepth: Int?
    var listId: Int32?
    var ls: Int32?
    // Per-level override records (`\lfolevel` groups in level order): an
    // overridden start and/or an overriding format (embedded `\listlevel`
    // with its own number text).
    var levelIndex = 0
    var starts = [UInt64?](repeating: nil, count: rtfListLevels)
    var markers = [MarkerKind??](repeating: nil, count: rtfListLevels)
    var texts = [RawLevelText?](repeating: nil, count: rtfListLevels)
    var collector = LevelTextCollector()

    func flush() {
        // Both fields are consumed whether or not the pair was complete: a
        // half-filled override must not leak its id into the next one.
        let lsTaken = ls
        let idTaken = listId
        ls = nil
        listId = nil
        if let lsValue = lsTaken, let id = idTaken {
            var def = byListId[id] ?? ListDef()
            for level in 0..<rtfListLevels {
                if let marker = markers[level] {
                    def.levels[level].marker = marker
                }
                if let start = starts[level] {
                    def.levels[level].start = start
                }
                if let raw = texts[level], def.levels[level].marker?.ordered == true {
                    def.levels[level].pattern = NumberPattern(
                        text: buildPattern(raw.text, raw.numbers, encoding), legal: raw.legal)
                }
            }
            lists[lsValue] = def
        }
        starts = [UInt64?](repeating: nil, count: rtfListLevels)
        markers = [MarkerKind??](repeating: nil, count: rtfListLevels)
        texts = [RawLevelText?](repeating: nil, count: rtfListLevels)
    }

    while let token = lexer.next() {
        switch token {
        case .open:
            depth += 1
        case .close:
            collector.active = nil
            if lfoDepth == depth {
                lfoDepth = nil
                if levelIndex < rtfListLevels, !collector.text.isEmpty {
                    texts[levelIndex] = RawLevelText(
                        text: collector.text, numbers: collector.numbers, legal: collector.legal)
                }
                collector = LevelTextCollector()
                levelIndex += 1
            }
            if overDepth == depth {
                flush()
                levelIndex = 0
                overDepth = nil
            }
            depth = max(0, depth - 1)
        case .word(let name, let param):
            switch name {
            case "listoverride":
                // A previous override group left unclosed still counts.
                flush()
                overDepth = depth
                levelIndex = 0
            case "listid" where overDepth != nil:
                listId = param
            case "ls" where overDepth != nil:
                ls = param
            case "lfolevel":
                lfoDepth = depth
                collector = LevelTextCollector()
            case "levelstartat" where lfoDepth != nil:
                if levelIndex < rtfListLevels, let n = param {
                    starts[levelIndex] = UInt64(max(n, 0))
                }
            case "levelnfc", "levelnfcn":
                if lfoDepth != nil, levelIndex < rtfListLevels {
                    markers[levelIndex] = .some(markerForNfc(param ?? 0))
                }
            case "leveltext" where lfoDepth != nil:
                collector.active = .text
            case "levelnumbers" where lfoDepth != nil:
                collector.active = .numbers
            case "levellegal" where lfoDepth != nil:
                collector.legal = param != 0
            default: break
            }
        case .hex(let b), .byte(let b):
            collector.byte(b)
        default: break
        }
    }
    flush()
}

/// MS-OSHARED numbering formats -> marker kinds. `nil` = no number.
private func markerForNfc(_ nfc: Int32) -> MarkerKind? {
    switch nfc {
    case 0: return .decimal
    case 1: return .upperRoman
    case 2: return .lowerRoman
    case 3: return .upperAlpha
    case 4: return .lowerAlpha
    case 23: return .bullet
    case 255: return nil
    default: return .decimal
    }
}
