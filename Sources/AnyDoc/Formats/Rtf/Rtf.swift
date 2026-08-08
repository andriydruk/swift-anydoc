/// RTF frontend: a position-explicit lexer feeding a state machine, with the
/// font/style/list tables parsed into typed definitions up front. Numbering
/// comes from the list tables — never guessed from label text. Page
/// headers/footers are excluded (fixed policy).

func parseRtf(_ bytes: [UInt8]) throws -> Document {
    guard bytes.starts(with: Array("{\\rtf".utf8)) else {
        throw ConvertError.malformed("not an RTF file")
    }
    // The code page must be known before the font table decodes; scan the
    // header for \ansicpg first.
    let defaultEncoding = scanCodepage(bytes)
    let prelude = parseRtfPrelude(bytes, defaultEncoding)
    var parser = RtfParser(bytes: bytes, prelude: prelude, defaultEncoding: defaultEncoding)
    try parser.run()
    return try parser.finish()
}

private func scanCodepage(_ bytes: [UInt8]) -> LegacyEncoding {
    // \ansicpg sits in the header, but generator comments and extra header
    // words can push it past any fixed prefix; the lexer scan is linear and
    // stops at the first match.
    var lexer = RtfLexer(bytes)
    while let token = lexer.next() {
        if case .word("ansicpg", let param) = token, let cp = param {
            return codepageEncoding(UInt32(max(cp, 0)))
        }
    }
    return .windows1252
}

/// Where captured text goes instead of the inline stream.
private enum Capture: Equatable {
    case none
    case listText
    case fieldInstr
    case bookmark
    /// Inside a `\pict` destination: bytes route to the picture collector.
    case pict
}

/// The state a group saves and restores: everything `{` … `}` scopes.
private struct CharState {
    var style = Style.plain
    var font: Int32?
    var ucSkip: UInt32 = 1
    var inTable = false
    var itap = 1
    var ilvl = 0
    var ls: Int32?
    var legacyList: MarkerKind?
    var outline: UInt8?
    /// The block container this paragraph's style names.
    var block: BlockStyle?
    /// Emphasis the paragraph style itself carries, subtracted from headings.
    var styleBase = Style.plain
    var suppress = false
    var capture = Capture.none
    var note: NoteKind?
}

private struct RtfFieldFrame {
    var depth: Int
    var instr: String
    var start: Int
}

private struct RtfNoteFrame {
    var depth: Int
    var start: Int
    var kind: NoteKind
}

/// Per-instance numbering counters with restart-on-shallower semantics.
private struct Counters {
    private var values: [Int32: [UInt64]] = [:]
    private var started: [Int32: [Bool]] = [:]

    mutating func next(_ ls: Int32, _ level: Int, start: UInt64) -> UInt64 {
        let level = min(level, rtfListLevels - 1)
        var vals = values[ls] ?? Array(repeating: 0, count: rtfListLevels)
        var seen = started[ls] ?? Array(repeating: false, count: rtfListLevels)
        let value = seen[level] ? vals[level].saturatingAdding(1) : start
        vals[level] = value
        seen[level] = true
        // A deeper level restarts the next time it is used.
        for i in (level + 1)..<rtfListLevels {
            seen[i] = false
        }
        values[ls] = vals
        started[ls] = seen
        return value
    }

    /// Advance a table-defined list level and render its composite label
    /// against the live counter values.
    mutating func nextLabeled(
        _ ls: Int32, _ level: Int, _ levels: [ListLevelDef]
    ) -> (number: UInt64, label: String?) {
        let level = min(level, rtfListLevels - 1)
        let def = levels[level]
        let value = next(ls, level, start: def.start)
        let vals = values[ls] ?? Array(repeating: 0, count: rtfListLevels)
        let seen = started[ls] ?? Array(repeating: false, count: rtfListLevels)
        guard let marker = def.marker else { return (value, nil) }
        let label = compositeLabel(
            def.pattern,
            ownMarker: marker,
            ownValue: value,
            levelMarker: { levels[min($0, rtfListLevels - 1)].marker ?? .decimal },
            levelValue: {
                let l = min($0, rtfListLevels - 1)
                return seen[l] ? vals[l] : levels[l].start
            })
        return (value, label)
    }

    /// Pin a counter to a number taken from the source (legacy `\pn` labels).
    mutating func seed(_ ls: Int32, _ level: Int, _ value: UInt64) {
        let level = min(level, rtfListLevels - 1)
        var vals = values[ls] ?? Array(repeating: 0, count: rtfListLevels)
        var seen = started[ls] ?? Array(repeating: false, count: rtfListLevels)
        vals[level] = value
        seen[level] = true
        for i in (level + 1)..<rtfListLevels {
            seen[i] = false
        }
        values[ls] = vals
        started[ls] = seen
    }
}

/// Byte-level text decoding: pending code-page bytes, `\uN` fallback skips,
/// and surrogate pairing.
private struct TextDecoder {
    let defaultEncoding: LegacyEncoding
    var pending: [UInt8] = []
    var skip: UInt32 = 0
    var surrogate: UInt16?

    /// Buffer one text byte, honoring an active `\uN` fallback skip.
    mutating func byte(_ b: UInt8) {
        if skip > 0 {
            skip -= 1
        } else {
            pending.append(b)
        }
    }

    /// True when an active fallback skip consumed the character.
    mutating func skipChar() -> Bool {
        if skip > 0 {
            skip -= 1
            return true
        }
        return false
    }

    /// Decode and take the buffered bytes with the current font's encoding.
    mutating func takePending(_ encoding: LegacyEncoding?) -> String? {
        if pending.isEmpty { return nil }
        let bytes = pending
        pending = []
        return (encoding ?? defaultEncoding).decode(bytes)
    }

    /// `\uN`: the completed scalar (surrogate pairs are held and combined),
    /// arming the `ucSkip`-length fallback skip.
    mutating func unicode(_ param: Int32?, _ ucSkip: UInt32) -> Unicode.Scalar? {
        // A new \u ends the previous one's fallback range.
        skip = 0
        guard let n = param else { return nil }
        // Producers write code points above 0x7FFF as negative i16 values.
        let code = n < 0 ? UInt32(bitPattern: n &+ 65536) : UInt32(n)
        let unit = UInt16(truncatingIfNeeded: code)
        let held = surrogate
        surrogate = nil
        var out: Unicode.Scalar?
        if held == nil, (0xD800...0xDBFF).contains(unit) {
            // High surrogate: hold for its pair.
            surrogate = unit
            out = nil
        } else if let high = held, (0xDC00...0xDFFF).contains(unit) {
            let combined = 0x10000 + (UInt32(high - 0xD800) << 10) + UInt32(unit - 0xDC00)
            out = Unicode.Scalar(combined)
        } else {
            out = Unicode.Scalar(code)
        }
        skip = ucSkip
        return out
    }
}

/// An accumulating `\pict` destination: the payload arrives as ASCII hex
/// characters (or one `\binN` run), typed by a format control word.
private struct PictState {
    /// Group depth of the `\pict` destination itself: payload bytes live at
    /// this depth only (subgroups like `\*\picprop` carry properties).
    var depth = 0
    var hex: [UInt8] = []
    var binary: [UInt8]?
    /// Media type and extension from `\pngblip`/`\jpegblip`/`\emfblip`/
    /// `\wmetafile`; `nil` = unsupported format.
    var format: (mediaType: String, ext: String)?
    /// Whether a format word was seen at all.
    var formatSeen = false

    /// The decoded payload bytes.
    func payload() -> [UInt8] {
        if let binary { return binary }
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var high: UInt8?
        for b in hex {
            guard let digit = hexDigit(b) else { continue }
            if let h = high {
                out.append((h << 4) | digit)
                high = nil
            } else {
                high = digit
            }
        }
        return out
    }
}

private func hexDigit(_ b: UInt8) -> UInt8? {
    switch b {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
    default: return nil
    }
}

/// Destinations whose content is excluded: headers/footers by fixed policy,
/// metadata and binary destinations because they carry no document text.
private let suppressedDestinations: Set<String> = [
    "fonttbl", "colortbl", "stylesheet", "info", "object", "header", "footer", "headerl",
    "headerr", "headerf", "footerl", "footerr", "footerf", "ftnsep", "ftnsepc", "aftnsep",
    "aftnsepc", "xmlnstbl", "themedata", "colorschememapping", "datastore", "latentstyles",
    "listtable", "listoverridetable", "rsidtbl", "generator", "filetbl", "revtbl", "datafield",
    "bkmkend", "annotation", "atnid", "atnauthor", "template", "defchp", "defpap", "panose",
    "falt", "objdata", "blipuid", "nonshppict", "wgrffmtfilter", "pgdsctbl", "docvar", "sp",
    "sn", "sv", "shpinst", "background", "userprops", "operator", "author", "title", "subject",
    "keywords", "doccomm", "creatim", "revtim", "printim",
]

private struct RtfParser {
    var lexer: RtfLexer
    var stack: [CharState] = []
    var state = CharState()
    let prelude: RtfPrelude
    var decoder: TextDecoder
    var recovered = false

    var inlines: [Inline] = []
    var blocks: [Block] = []
    var listRun: [ListEntry] = []
    var styled = StyledRun()
    var counters = Counters()
    var table = RtfTableState()
    var assets = AssetSink()

    // Destination state: frames open at a group depth and close when the
    // group stack unwinds past it.
    var fields: [RtfFieldFrame] = []
    var noteFrames: [RtfNoteFrame] = []
    var notes: [Note] = []
    var bookmark = ""
    /// Captured `\listtext` label for the current paragraph.
    var listText: String?
    /// The `\pict` destination currently accumulating, if any.
    var pict: PictState?

    init(bytes: [UInt8], prelude: RtfPrelude, defaultEncoding: LegacyEncoding) {
        self.lexer = RtfLexer(bytes)
        self.prelude = prelude
        self.decoder = TextDecoder(defaultEncoding: defaultEncoding)
    }

    mutating func run() throws {
        while let token = lexer.next() {
            switch token {
            case .open:
                flushPending()
                stack.append(state)
            case .close:
                flushPending()
                if let prev = stack.popLast() {
                    state = prev
                } else {
                    recovered = true
                }
                let depth = stack.count
                closeFields(depth)
                closeNotes(depth)
                closeBookmark(stillCapturing: state.capture == .bookmark)
                // The pict destination finishes when the stack unwinds past
                // its own group (inner property groups close first).
                if let p = pict, stack.count < p.depth {
                    try finishPict()
                }
            case .word(let name, let param):
                try controlWord(name, param)
            case .symbol(let b):
                controlSymbol(b)
            case .hex(let b), .byte(let b):
                if state.capture == .pict {
                    if pict != nil, stack.count == pict!.depth {
                        pict!.hex.append(b)
                    }
                } else if acceptsText {
                    decoder.byte(b)
                }
            case .bin(let payload):
                if state.capture == .pict, pict != nil, stack.count == pict!.depth {
                    pict!.binary = Array(payload)
                } else {
                    Log.debug("skipping \(payload.count) bytes of embedded binary data")
                }
            }
        }
        if !stack.isEmpty {
            recovered = true
        }
        if recovered {
            Log.warn("recovered unbalanced rtf groups")
        }
        flushPending()
        try endParagraph()
    }

    var acceptsText: Bool {
        state.capture != .none || !state.suppress
    }

    mutating func controlSymbol(_ b: UInt8) {
        switch b {
        case UInt8(ascii: "~"): pushChar("\u{a0}")
        // An optional hyphen is a break opportunity, not a character.
        case UInt8(ascii: "-"): break
        case UInt8(ascii: "_"): pushChar("-")
        case UInt8(ascii: "*"): state.suppress = true
        case UInt8(ascii: "\\"), UInt8(ascii: "{"), UInt8(ascii: "}"):
            pushChar(Unicode.Scalar(b))
        default: break
        }
    }

    /// Dispatch a control word to its subsystem handler; unhandled words
    /// that name a suppressed destination silence their group.
    mutating func controlWord(_ word: String, _ param: Int32?) throws {
        if try textControl(word, param) { return }
        if try tableControl(word, param) { return }
        if listControl(word, param) { return }
        if objectControl(word) { return }
        if suppressedDestinations.contains(word) {
            flushPending()
            state.suppress = true
            state.capture = .none
        }
    }

    /// Character- and paragraph-level controls: text encoding, styling,
    /// paragraph and line breaks, and special characters.
    mutating func textControl(_ word: String, _ param: Int32?) throws -> Bool {
        let on = param != 0
        switch word {
        case "u":
            if acceptsText {
                flushPending()
                if let scalar = decoder.unicode(param, state.ucSkip) {
                    pushText(String(scalar))
                }
            }
        case "uc":
            state.ucSkip = UInt32(max(param ?? 1, 0))
        case "f":
            flushPending()
            state.font = param
        case "b": setStyle { $0.bold = on }
        case "i": setStyle { $0.italic = on }
        case "strike", "striked": setStyle { $0.strike = on }
        case "plain":
            flushPending()
            let font = state.font
            state.style = .plain
            state.font = font
        case "s":
            // Paragraph style: outline level for headings plus its
            // formatting delta as the new base.
            if let id = param, let def = prelude.styles[id] {
                flushPending()
                state.outline = def.outline
                state.block = def.block
                state.style = def.delta.apply(state.style)
                state.styleBase = state.style
            }
        case "par", "sect":
            flushPending()
            if state.note != nil {
                inlines.append(.lineBreak)
            } else if !state.suppress {
                try endParagraph()
            }
        case "pard":
            flushPending()
            state.inTable = false
            state.itap = 1
            state.ilvl = 0
            state.ls = nil
            state.legacyList = nil
            state.outline = nil
            state.block = nil
            state.styleBase = .plain
        // \page and \column break the flow without ending the paragraph;
        // the page they start is unrepresentable, the word boundary they
        // carry is not.
        case "line", "lbr", "page", "column":
            flushPending()
            if !state.suppress {
                inlines.append(.lineBreak)
            }
        case "tab": pushChar(" ")
        case "emdash": pushChar("\u{2014}")
        case "endash": pushChar("\u{2013}")
        case "lquote": pushChar("\u{2018}")
        case "rquote": pushChar("\u{2019}")
        case "ldblquote": pushChar("\u{201c}")
        case "rdblquote": pushChar("\u{201d}")
        case "bullet": pushChar("\u{2022}")
        case "enspace", "emspace", "qmspace": pushChar(" ")
        default: return false
        }
        return true
    }

    /// Table controls, delegated to the per-depth table state.
    mutating func tableControl(_ word: String, _ param: Int32?) throws -> Bool {
        switch word {
        case "intbl":
            state.inTable = true
        case "itap":
            state.itap = Int(min(max(param ?? 1, 0), 8))
            if state.itap > 1 {
                state.inTable = true
            }
        case "trowd":
            if tableActive { table.beginRow(max(state.itap, 1)) }
        case "trhdr":
            if tableActive { table.markHeaderRow(max(state.itap, 1)) }
        case "clmgf": pendingCellProp { $0.mergeFirst = true }
        case "clmrg": pendingCellProp { $0.mergeCont = true }
        case "clvmgf": pendingCellProp { $0.vmergeFirst = true }
        case "clvmrg": pendingCellProp { $0.vmergeCont = true }
        case "cellx":
            if tableActive {
                table.declareCell(max(state.itap, 1), right: Int64(param ?? 0))
            }
        case "cell":
            flushPending()
            if tableActive { try endCell(1) }
        case "nestcell":
            flushPending()
            if tableActive { try endCell(max(state.itap, 2)) }
        case "row":
            flushPending()
            if tableActive { try endRow(1) }
        case "nestrow":
            flushPending()
            if tableActive { try endRow(max(state.itap, 2)) }
        // Nested row properties arrive in a `{\*\nesttableprops ...}`
        // destination; its \trowd/\cellx/\nestrow must still act.
        case "nesttableprops":
            state.suppress = false
        default: return false
        }
        return true
    }

    /// List and outline controls.
    mutating func listControl(_ word: String, _ param: Int32?) -> Bool {
        switch word {
        case "outlinelevel":
            if let n = param, (0..<9).contains(n) {
                state.outline = UInt8(n + 1)
            }
        case "ilvl":
            state.ilvl = Int(min(max(param ?? 0, 0), 8))
        case "ls":
            state.ls = param
        case "listtext", "pntext":
            flushPending()
            state.capture = .listText
            if listText == nil {
                listText = ""
            }
        case "pnlvlblt":
            state.legacyList = .bullet
        case "pnlvlbody", "pndec":
            state.legacyList = .decimal
        default: return false
        }
        return true
    }

    /// Field, footnote, bookmark, and picture controls.
    mutating func objectControl(_ word: String) -> Bool {
        switch word {
        case "field":
            flushPending()
            if !state.suppress {
                fields.append(RtfFieldFrame(depth: stack.count, instr: "", start: inlines.count))
            }
        case "fldinst":
            flushPending()
            if !fields.isEmpty {
                state.capture = .fieldInstr
            }
            state.suppress = true
        case "fldrslt":
            flushPending()
            state.capture = .none
        case "footnote":
            flushPending()
            state.note = .footnote
            state.suppress = false
            state.capture = .none
            noteFrames.append(
                RtfNoteFrame(depth: stack.count, start: inlines.count, kind: .footnote))
        case "ftnalt":
            // Marks the enclosing \footnote as an endnote.
            if !noteFrames.isEmpty {
                noteFrames[noteFrames.count - 1].kind = .endnote
            }
        case "chftn":
            break
        case "bkmkstart":
            flushPending()
            state.capture = .bookmark
            state.suppress = false
        // `{\*\shppict {\pict ...}}` wraps the preferred picture; the
        // `\nonshppict` fallback duplicate stays suppressed.
        case "shppict":
            state.suppress = false
        // `\shpinst` itself is suppressed (shape properties), but its
        // `\shptxt` destination holds the shape's real text.
        case "shptxt":
            state.suppress = false
        // Likewise `\object` is suppressed (class names, `\objdata`
        // payload), but `\result` is the object's displayable rendering.
        case "result":
            state.suppress = false
        case "pict":
            // A pict inside a suppressed destination (the nonshppict
            // fallback, excluded headers) is not extracted.
            if !state.suppress {
                flushPending()
                state.capture = .pict
                pict = PictState(depth: stack.count)
            }
        case "pngblip": setPictFormat(("image/png", "png"))
        case "jpegblip": setPictFormat(("image/jpeg", "jpg"))
        case "emfblip": setPictFormat(("image/emf", "emf"))
        case "wmetafile": setPictFormat(("image/wmf", "wmf"))
        case "macpict", "dibitmap", "wbitmap": setPictFormat(nil)
        default: return false
        }
        return true
    }

    mutating func setPictFormat(_ format: (mediaType: String, ext: String)?) {
        if state.capture == .pict, pict != nil {
            pict!.format = format
            pict!.formatSeen = true
        }
    }

    /// Finalize a closed `\pict` destination: retain the payload as an
    /// asset and emit its inline reference. Unsupported formats degrade
    /// with a log.
    mutating func finishPict() throws {
        guard let p = pict else { return }
        pict = nil
        guard let format = p.format else {
            Log.debug("skipping picture in an unsupported format")
            return
        }
        let bytes = p.payload()
        if bytes.isEmpty { return }
        let part = "pict/\(assets.assets.count).\(format.ext)"
        let id = try assets.add(mediaType: format.mediaType, originPart: part, bytes: bytes)
        inlines.append(.image(alt: "", source: .asset(id)))
    }

    /// Table controls act outside suppressed groups and note bodies.
    var tableActive: Bool {
        !state.suppress && state.note == nil
    }

    mutating func pendingCellProp(_ apply: (inout CellProp) -> Void) {
        if tableActive {
            table.withPendingProp(max(state.itap, 1), apply)
        }
    }

    mutating func setStyle(_ apply: (inout Style) -> Void) {
        flushPending()
        apply(&state.style)
    }

    mutating func pushChar(_ c: Unicode.Scalar) {
        guard acceptsText else { return }
        if decoder.skipChar() { return }
        flushPending()
        pushText(String(c))
    }

    mutating func flushPending() {
        let encoding = state.font.flatMap { prelude.fonts[$0] }
        if let text = decoder.takePending(encoding) {
            pushText(text)
        }
    }

    mutating func pushText(_ raw: String) {
        let text = cleanText(raw)
        if text.isEmpty { return }
        switch state.capture {
        case .listText:
            if listText != nil { listText! += text }
        case .fieldInstr:
            if !fields.isEmpty { fields[fields.count - 1].instr += text }
        case .bookmark:
            bookmark += text
        // Picture payload bytes are collected raw in the token loop.
        case .pict:
            break
        case .none:
            if !state.suppress {
                inlines.append(.text(text, style: state.style))
            }
        }
    }

    // MARK: destination frames

    /// Close field frames opened deeper than `depth`, folding their results
    /// back into the inline stream.
    mutating func closeFields(_ depth: Int) {
        while let last = fields.last, last.depth > depth {
            fields.removeLast()
            let start = min(last.start, inlines.count)
            let content = Array(inlines[start...])
            inlines.removeSubrange(start..<inlines.count)
            inlines.append(contentsOf: fieldResult(last.instr, content))
        }
    }

    /// Close note frames opened deeper than `depth`, replacing their content
    /// with a reference to the collected note.
    mutating func closeNotes(_ depth: Int) {
        while let last = noteFrames.last, last.depth > depth {
            noteFrames.removeLast()
            let start = min(last.start, inlines.count)
            let content = Array(inlines[start...])
            inlines.removeSubrange(start..<inlines.count)
            if !inlinesAreEmpty(content) {
                let id = "rtf\(notes.count)"
                notes.append(Note(id: id, kind: last.kind, blocks: [.paragraph(content)]))
                inlines.append(.noteRef(id))
            }
        }
    }

    /// Emit a completed bookmark capture as an anchor.
    mutating func closeBookmark(stillCapturing: Bool) {
        if !stillCapturing, !bookmark.isEmpty {
            let name = bookmark.rustTrim()
            bookmark = ""
            if !name.isEmpty {
                inlines.append(.anchor(name))
            }
        }
    }

    // MARK: blocks

    /// Flush the finished top-level table, if any, into the block stream.
    mutating func flushTopTable() throws {
        if let block = try table.takeTable(1) {
            flushRuns()
            blocks.append(block)
        }
    }

    mutating func endParagraph() throws {
        let inlines = self.inlines
        self.inlines = []
        let listText = self.listText
        self.listText = nil

        if state.inTable {
            table.pushCellParagraph(max(state.itap, 1), state.block, inlines)
            return
        }
        try flushTopTable()

        // A styled container absorbs its blank paragraphs: they are the
        // blank lines of a code block.
        if let style = state.block {
            flushList(&blocks, &listRun)
            styled.push(style, inlines, &blocks)
            return
        }
        if inlinesAreEmpty(inlines) {
            flushRuns()
            return
        }
        // Numbering identity comes from the list tables; the captured label
        // text only seeds legacy Word-95 numbering. Numbered headings
        // advance the sequence and keep their number visible.
        let entry = listEntry(listText)
        if let level = state.outline {
            flushRuns()
            var content = inlines
            rebaseEmphasis(&content, base: state.styleBase)
            if let entry, entry.key.marker.ordered {
                let text = (entry.label ?? entry.key.marker.label(entry.number)) + " "
                content.insert(.text(text, style: .plain), at: 0)
            }
            blocks.append(.heading(level: Int(level), anchor: nil, content: content))
            return
        }
        if let entry {
            listRun.append(
                ListEntry(
                    level: entry.level, key: entry.key, number: entry.number, label: entry.label,
                    blocks: [.paragraph(inlines)]))
            return
        }
        flushRuns()
        blocks.append(.paragraph(inlines))
    }

    /// A captured `\listtext` as a literal marker label: trimmed, non-empty.
    static func trimmedLabel(_ listText: String?) -> String? {
        guard let trimmed = listText?.rustTrim(), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    mutating func listEntry(_ listText: String?)
        -> (key: ListKey, level: Int, number: UInt64, label: String?)?
    {
        if let ls = state.ls {
            let level = state.ilvl
            if let list = prelude.lists[ls] {
                let def = list.levels[min(level, rtfListLevels - 1)]
                guard let marker = def.marker else { return nil }
                var number: UInt64 = 0
                var label: String?
                if marker.ordered {
                    let labeled = counters.nextLabeled(ls, level, list.levels)
                    number = labeled.number
                    label = labeled.label
                }
                return (ListKey(instance: UInt64(UInt32(bitPattern: ls)), marker: marker),
                    level, number, label)
            }
            // No table definition behind the \ls: the captured \listtext is
            // the only surviving evidence of the real marker; carry it as
            // the item's literal label over a bullet base.
            return (ListKey(instance: UInt64(UInt32(bitPattern: ls)), marker: .bullet),
                level, 0, Self.trimmedLabel(listText))
        }
        if let marker = state.legacyList {
            var number: UInt64 = 0
            if marker.ordered {
                // Legacy \pn numbering: the label text carries the number,
                // clamped so a crafted label cannot overflow the counter.
                let digits = String(
                    (listText ?? "").unicodeScalars.prefix(while: { $0.isAsciiDigit })
                        .map(Character.init))
                if !digits.isEmpty, let parsed = UInt64(digits) {
                    let n = min(parsed, UInt64(UInt32.max))
                    counters.seed(Int32.max, state.ilvl, n)
                    number = n
                } else {
                    number = counters.next(Int32.max, state.ilvl, start: 1)
                }
            }
            return (ListKey(instance: UInt64.max, marker: marker), state.ilvl, number, nil)
        }
        // A bare \listtext with no list state still marks a list paragraph
        // (some producers omit \ls); its text is the literal marker.
        if let text = listText, !text.rustTrim().isEmpty {
            return (ListKey(instance: UInt64.max - 1, marker: .bullet),
                state.ilvl, 0, Self.trimmedLabel(listText))
        }
        return nil
    }

    mutating func endCell(_ depth: Int) throws {
        let content = inlines
        inlines = []
        listText = nil
        try table.endCell(depth, state.block, content)
    }

    mutating func endRow(_ depth: Int) throws {
        if table.hasPendingCell(depth) || !inlinesAreEmpty(inlines) {
            try endCell(depth)
        }
        table.endRow(depth)
    }

    /// Close every open block run before something else is emitted.
    mutating func flushRuns() {
        styled.flush(&blocks)
        flushList(&blocks, &listRun)
    }

    mutating func finish() throws -> Document {
        if table.depth >= 1 {
            for depth in stride(from: table.depth, through: 1, by: -1) where table.hasPartialRow(depth) {
                try endRow(depth)
            }
        }
        // Collapse any dangling nested tables outward, then flush.
        try table.collapseNested()
        try flushTopTable()
        flushRuns()
        return Document(blocks: blocks, notes: notes, assets: assets.assets)
    }
}
