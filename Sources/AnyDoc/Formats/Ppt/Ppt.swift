/// Legacy PowerPoint 97-2003 binary (`.ppt`): OLE2 container, record stream.
/// Slides resolve through the persist directory (the only default path);
/// text comes from TextHeaderAtom + TextCharsAtom/TextBytesAtom with
/// StyleTextPropAtom runs and TxMasterStyleAtom defaults applied. Raw
/// stream-order scanning exists only as an explicitly labelled recovery for
/// files whose persist directory is unusable. Speaker notes are included
/// (fixed policy), rendered as a quote after their slide.

/// One master's per-text-type level defaults, keyed by TxMasterStyleAtom
/// instance (the text type).
typealias MasterStyles = [UInt16: [PptMasterLevel]]

func parsePpt(_ bytes: [UInt8]) throws -> Document {
    let ole: CompoundFile
    do {
        ole = try CompoundFile(bytes: bytes)
    } catch let e as ConvertError {
        throw ConvertError.malformed("not an OLE2 compound file: \(e.message)")
    }
    let data = try readOleStream(ole, "PowerPoint Document")
    let currentUser = (try? readOleStream(ole, "Current User")) ?? []
    if getU32(currentUser, 12) == 0xF3D1_C4DF {
        throw ConvertError.encrypted
    }

    var extractor = PptExtractor()
    if try !extractor.parseSlides(data, currentUser) {
        // Labelled recovery path: the persist directory is unusable, so text
        // is taken in raw stream order (may include superseded edits).
        Log.warn("ppt persist directory unusable; recovering text in raw stream order")
        extractor = PptExtractor()
        extractor.recovering = true
        try extractor.walk(data[...])
        extractor.endSegment(nil)
    }
    if extractor.encrypted {
        throw ConvertError.encrypted
    }
    let assets = try collectPictures(ole)
    return Document(blocks: extractor.intoBlocks(), notes: [], assets: assets)
}

/// Retain the deck's embedded pictures from the `Pictures` stream (OfficeArt
/// BStore file blocks). Pictures are document-level assets; per-slide
/// placement is not resolved. Unsupported formats degrade with a log.
private func collectPictures(_ ole: CompoundFile) throws -> [Asset] {
    guard let pictures = try? readOleStream(ole, "Pictures") else { return [] }
    var sink = AssetSink()
    var pos = 0
    var index: UInt32 = 0
    while let (verInst, recType, body) = recordAt(pictures[...], pos) {
        pos += 8 + body.count
        index += 1
        if index > 100_000 { break }
        let cap = Int(Limits.maxEntryBytes)
        let blip =
            recType == 0xF007
            ? fbseBlip(body, maxBytes: cap)
            : decodeBlip(verInst: verInst, recType: recType, body: body, maxBytes: cap)
        guard let blip else {
            Log.debug("skipping unsupported Pictures record 0x\(hex4(recType))")
            continue
        }
        _ = try sink.add(
            mediaType: blip.mediaType, originPart: "pictures/\(index).\(blip.extension)",
            bytes: blip.bytes)
    }
    return sink.assets
}

private func hex4(_ value: UInt16) -> String {
    var text = String(value, radix: 16, uppercase: true)
    while text.count < 4 { text = "0" + text }
    return text
}

/// The record at `off`, when it is of the expected type.
private func recordAt(_ data: ArraySlice<UInt8>, _ off: Int, type: UInt16) -> ArraySlice<UInt8>? {
    guard let record = recordAt(data, off), record.recType == type else { return nil }
    return record.body
}

/// The records laid out back to back in `data`.
private func pptChildren(_ data: ArraySlice<UInt8>)
    -> [(verInst: UInt16, recType: UInt16, body: ArraySlice<UInt8>)]
{
    var out: [(verInst: UInt16, recType: UInt16, body: ArraySlice<UInt8>)] = []
    var pos = 0
    while let record = recordAt(data, pos) {
        pos += 8 + record.body.count
        out.append(record)
    }
    return out
}

/// A text shape being accumulated: header type, text, then styling.
struct PendingShape {
    var txType: UInt8
    var text: String
    var styles: PptStyleRuns?
}

/// The persist-resolved layout of the presentation: slide/notes lists from
/// the current DocumentContainer, persist id -> offset for every container.
private struct DocLayout {
    var persist: [UInt32: Int]
    var slideList: ArraySlice<UInt8>
    var notesList: ArraySlice<UInt8>?
    var masterList: ArraySlice<UInt8>?
}

/// Resolve the UserEditAtom chain into the persist directory and find the
/// DocumentContainer's SlideListWithText instances. `nil` means the persist
/// directory is unusable and the caller falls back to raw-order recovery.
private func locateDocument(_ data: [UInt8], _ currentUser: [UInt8]) -> DocLayout? {
    var persist: [UInt32: Int] = [:]
    var docPersist: UInt32?
    guard var editOff = getU32(currentUser, 16).map(Int.init) else { return nil }
    for _ in 0..<100 {
        if editOff == 0 { break }
        guard let (_, recType, body) = recordAt(data[...], editOff) else { return nil }
        if recType != 0x0FF5 { return nil }
        if docPersist == nil {
            docPersist = sliceU32(body, 16)
        }
        guard let dirOff = sliceU32(body, 12).map(Int.init) else { return nil }
        if let dir = recordAt(data[...], dirOff, type: 0x1772) {
            var pos = 0
            while pos + 4 <= dir.count {
                guard let head = sliceU32(dir, pos) else { return nil }
                let id = head & 0xF_FFFF
                let count = Int(head >> 20)
                pos += 4
                for k in 0..<count {
                    guard let offset = sliceU32(dir, pos).map(Int.init) else { return nil }
                    // Newer edits win: keep the first offset seen.
                    if persist[id &+ UInt32(k)] == nil {
                        persist[id &+ UInt32(k)] = offset
                    }
                    pos += 4
                }
            }
        }
        guard let prev = sliceU32(body, 8).map(Int.init) else { return nil }
        if prev == editOff { break }
        editOff = prev
    }

    guard let docPersist, let docOff = persist[docPersist] else { return nil }
    guard let doc = recordAt(data[...], docOff, type: 0x03E8) else { return nil }
    let lists = pptChildren(doc)
    guard let slideList = lists.first(where: { $0.recType == 0x0FF0 && $0.verInst >> 4 == 0 })?.body
    else { return nil }
    return DocLayout(
        persist: persist,
        slideList: slideList,
        notesList: lists.first(where: { $0.recType == 0x0FF0 && $0.verInst >> 4 == 2 })?.body,
        masterList: lists.first(where: { $0.recType == 0x0FF0 && $0.verInst >> 4 == 1 })?.body)
}

/// One master's TxMasterStyleAtoms, keyed by text-type instance.
private func masterStyles(_ master: ArraySlice<UInt8>) -> MasterStyles {
    var styles = MasterStyles()
    for (verInst, recType, body) in pptChildren(master) where recType == 0x0FA3 {
        let instance = verInst >> 4
        if styles[instance] == nil {
            styles[instance] = parseMasterStyle(body, instance: instance)
        }
    }
    return styles
}

/// Masters in master-list order (MasterPersistAtoms: persistIdRef at 0,
/// masterId at 12); falls back to a persist-directory scan when the list is
/// absent so single-master decks still get their defaults.
private func collectMasters(
    _ masterList: ArraySlice<UInt8>?, _ persist: [UInt32: Int], _ data: [UInt8]
) -> [(id: UInt32, styles: MasterStyles)] {
    var out: [(id: UInt32, styles: MasterStyles)] = []
    if let masterList {
        for (_, recType, body) in pptChildren(masterList) where recType == 0x03F3 {
            guard let persistRef = sliceU32(body, 0), let masterId = sliceU32(body, 12) else {
                continue
            }
            if let off = persist[persistRef], let master = recordAt(data[...], off, type: 0x03F8) {
                out.append((id: masterId, styles: masterStyles(master)))
            }
        }
    }
    if out.isEmpty {
        for off in persist.values.sorted() {
            if let master = recordAt(data[...], off, type: 0x03F8) {
                out.append((id: 0, styles: masterStyles(master)))
            }
        }
    }
    return out
}

struct PptExtractor {
    /// Finished segments: blocks, pairing id, and whether they are notes.
    var segments: [(blocks: [Block], id: UInt32?, isNotes: Bool)] = []
    var current: [Block] = []
    var currentIsNotes = false
    var listRun: [ListEntry] = []
    var pending: PendingShape?
    /// Master style tables in master-list order.
    var masters: [(id: UInt32, styles: MasterStyles)] = []
    /// Index into `masters` for the slide being extracted (0 fallback).
    var activeMaster = 0
    var shapeCounter: UInt64 = 0
    var encrypted = false
    /// Raw-stream recovery: no persist lists, so notes descend inline.
    var recovering = false
    /// Records visited across the whole extraction, capped.
    var records: UInt64 = 0

    /// Walk slides in presentation order. `false` means the persist
    /// directory was unusable.
    mutating func parseSlides(_ data: [UInt8], _ currentUser: [UInt8]) throws -> Bool {
        guard let layout = locateDocument(data, currentUser) else { return false }
        masters = collectMasters(layout.masterList, layout.persist, data)
        try walkSlideList(
            layout.slideList, layout.persist, data, isNotes: false, containerType: 0x03EE)
        if let notesList = layout.notesList {
            try walkSlideList(
                notesList, layout.persist, data, isNotes: true, containerType: 0x03F0)
        }
        return true
    }

    private mutating func walkSlideList(
        _ list: ArraySlice<UInt8>, _ persist: [UInt32: Int], _ data: [UInt8], isNotes: Bool,
        containerType: UInt16
    ) throws {
        // (persistIdRef, slideId) of the page whose container is pending.
        var pendingPage: (persistRef: UInt32, slideId: UInt32)?
        for (verInst, recType, body) in pptChildren(list) {
            // SlidePersistAtom: the next slide/notes page begins.
            if recType == 0x03F3 {
                let id = try finishSlide(
                    pendingPage, persist, data, containerType: containerType, isNotes: isNotes)
                endSegment(id)
                currentIsNotes = isNotes
                pendingPage = sliceU32(body, 0).map {
                    (persistRef: $0, slideId: sliceU32(body, 12) ?? 0)
                }
                if !isNotes {
                    selectMaster(pendingPage?.persistRef, persist, data)
                }
            } else {
                try record(verInst, recType, body)
            }
        }
        let id = try finishSlide(
            pendingPage, persist, data, containerType: containerType, isNotes: isNotes)
        endSegment(id)
    }

    /// Emit a slide's own textboxes after its outline text. Returns the
    /// segment's pairing id: the slideId for slides, or the owning slide's
    /// id (NotesAtom slideIdRef) for notes pages.
    private mutating func finishSlide(
        _ pendingPage: (persistRef: UInt32, slideId: UInt32)?, _ persist: [UInt32: Int],
        _ data: [UInt8], containerType: UInt16, isNotes: Bool
    ) throws -> UInt32? {
        guard let page = pendingPage else { return nil }
        var id: UInt32? = isNotes ? nil : (page.slideId != 0 ? page.slideId : nil)
        if let off = persist[page.persistRef], let (_, type, body) = recordAt(data[...], off),
            type == containerType
        {
            if isNotes {
                // NotesAtom.slideIdRef names the owning slide (0 = none).
                id = pptChildren(body).first(where: { $0.recType == 0x03F1 })
                    .flatMap { sliceU32($0.body, 0) }
                    .flatMap { $0 != 0 ? $0 : nil }
            }
            try walk(body)
        }
        return id
    }

    mutating func endSegment(_ id: UInt32?) {
        flushShape()
        flushList(&current, &listRun)
        if !current.isEmpty {
            let blocks = current
            current = []
            segments.append((blocks: blocks, id: id, isNotes: currentIsNotes))
        }
    }

    mutating func intoBlocks() -> [Block] {
        endSegment(nil)
        var slides: [(id: UInt32?, blocks: [Block])] = []
        var notes: [(id: UInt32?, blocks: [Block])] = []
        for segment in segments {
            if segment.isNotes {
                notes.append((id: segment.id, blocks: segment.blocks))
            } else {
                slides.append((id: segment.id, blocks: segment.blocks))
            }
        }
        // Notes pages pair to slides by their stored slide id, not by list
        // position: the notes list may be sparse (notes on only some
        // slides), which order-based zipping would misattribute.
        var used = [Bool](repeating: false, count: notes.count)
        var out: [Block] = []
        for slide in slides {
            out.append(contentsOf: slide.blocks)
            for i in notes.indices where !used[i] && slide.id != nil && notes[i].id == slide.id {
                used[i] = true
                out.append(.blockQuote(notes[i].blocks))
                notes[i].blocks = []
            }
        }
        // Notes without a resolvable owner keep document order at the end.
        for (i, note) in notes.enumerated() where !used[i] && !note.blocks.isEmpty {
            out.append(.blockQuote(note.blocks))
        }
        return out
    }

    /// Pick the master the slide references (SlideAtom.masterIdRef at
    /// offset 12); the first listed master is the deterministic fallback.
    private mutating func selectMaster(
        _ slide: UInt32?, _ persist: [UInt32: Int], _ data: [UInt8]
    ) {
        activeMaster = 0
        guard let slide, let off = persist[slide],
            let body = recordAt(data[...], off, type: 0x03EE),
            let atom = pptChildren(body).first(where: { $0.recType == 0x03EF }),
            let masterId = sliceU32(atom.body, 12),
            let index = masters.firstIndex(where: { $0.id == masterId })
        else { return }
        activeMaster = index
    }

    /// Iterative container walk over an explicit stack with fixed depth and
    /// record-count bounds — nesting or record counts beyond any real
    /// presentation are attack shapes and hard-fail.
    mutating func walk(_ data: ArraySlice<UInt8>) throws {
        var stack: [(buf: ArraySlice<UInt8>, pos: Int)] = [(buf: data, pos: 0)]
        while let top = stack.last {
            guard let (verInst, recType, body) = recordAt(top.buf, top.pos) else {
                stack.removeLast()
                continue
            }
            stack[stack.count - 1].pos += 8 + body.count
            try chargeRecord()
            if verInst & 0xF != 0xF {
                atom(recType, body)
                continue
            }
            switch recType {
            // CryptSession10Container: the stream is encrypted.
            case 0x2F14:
                encrypted = true
            // Notes containers are walked via the notes list; recovery has
            // no lists, so their text is taken inline (as notes). A NotesAtom
            // slideIdRef in the masters range (high bit set) marks the notes
            // master: template chrome, excluded.
            case 0x03F0 where recovering:
                let isMaster = pptChildren(body).first(where: { $0.recType == 0x03F1 })
                    .flatMap { sliceU32($0.body, 0) }
                    .map { $0 & 0x8000_0000 != 0 } ?? false
                if !isMaster {
                    endSegment(nil)
                    currentIsNotes = true
                    try walk(body)
                    endSegment(nil)
                    currentIsNotes = false
                }
            // Notes, master, and handout containers are walked via their own
            // lists, not inline.
            case 0x03F0, 0x03F8, 0x0FC9:
                break
            // Only instance 0 of SlideListWithText holds slide text here.
            case 0x0FF0 where verInst >> 4 != 0:
                break
            default:
                if stack.count >= Limits.maxRecordDepth {
                    throw ConvertError.resourceLimit(
                        limit: "max_record_depth",
                        detail: "record nesting exceeds \(Limits.maxRecordDepth)")
                }
                stack.append((buf: body, pos: 0))
            }
        }
    }

    /// One record outside `walk` (slide-list traversal): containers descend
    /// through the bounded walk, atoms extract directly.
    private mutating func record(
        _ verInst: UInt16, _ recType: UInt16, _ body: ArraySlice<UInt8>
    ) throws {
        try chargeRecord()
        if verInst & 0xF == 0xF {
            switch recType {
            case 0x2F14: encrypted = true
            case 0x03F0, 0x03F8, 0x0FC9: break
            case 0x0FF0 where verInst >> 4 != 0: break
            default: try walk(body)
            }
        } else {
            atom(recType, body)
        }
    }

    private mutating func chargeRecord() throws {
        records += 1
        if records > Limits.maxRecords {
            throw ConvertError.resourceLimit(
                limit: "max_records",
                detail: "record stream exceeds \(Limits.maxRecords) records")
        }
    }

    private mutating func atom(_ recType: UInt16, _ body: ArraySlice<UInt8>) {
        switch recType {
        // TextHeaderAtom: a new text shape begins.
        case 0x0F9F:
            flushShape()
            pending = PendingShape(txType: body.first ?? 1, text: "", styles: nil)
        // TextCharsAtom: UTF-16LE.
        case 0x0FA0:
            pushText(decodeUtf16NoBom(body))
        // TextBytesAtom: low bytes of UTF-16 code units.
        case 0x0FA8:
            var out = String.UnicodeScalarView()
            out.reserveCapacity(body.count)
            for byte in body {
                out.append(Unicode.Scalar(byte))
            }
            pushText(String(out))
        // StyleTextPropAtom: styling for the pending shape's text.
        case 0x0FA1:
            if pending != nil {
                let len = pending!.text.unicodeScalars.reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
                pending!.styles = parseStyleText(body, textLen: len)
            }
        // ExHyperlinkAtom: explicit degradation — hyperlink targets in the
        // legacy record stream are not resolved to link inlines.
        case 0x0FD3:
            Log.debug("ppt hyperlink records present; targets are not resolved")
        default:
            break
        }
    }

    private mutating func pushText(_ text: String) {
        if pending != nil {
            pending!.text += text
        } else {
            pending = PendingShape(txType: 1, text: text, styles: nil)
        }
    }

    /// Emit the pending shape: paragraphs split on CR, styled by the
    /// character runs, listed by paragraph depth/bullet with master defaults.
    private mutating func flushShape() {
        guard let shape = pending else { return }
        pending = nil
        if shape.text.isEmpty { return }
        shapeCounter += 1
        let shapeId = shapeCounter
        let isTitle = shape.txType == 0 || shape.txType == 6
        let styles = shape.styles ?? PptStyleRuns()
        // The active master's per-level defaults for this text type; local
        // exceptions are tri-state and resolve over these.
        let masterLevels: [PptMasterLevel] =
            masters[safe: activeMaster]?.styles[UInt16(shape.txType)] ?? []
        func levelDefault(_ depth: UInt16) -> PptMasterLevel {
            masterLevels[safe: Int(depth)] ?? PptMasterLevel()
        }

        // Cursors over the style runs, counted in UTF-16 units.
        var charIndex = 0
        var charRun: PptCharProps? = styles.chars.first
        var charLeft = charRun?.count ?? Int.max
        var paraIndex = 0
        var paraRun: PptParaProps? = styles.paragraphs.first
        var paraLeft = paraRun?.count ?? Int.max

        var paragraphs: [(inlines: [Inline], depth: UInt16, bullet: Bool?)] = []
        var inlines: [Inline] = []
        var runText = ""
        var runStyle = Style.plain
        func paraProps(_ run: PptParaProps?) -> (depth: UInt16, bullet: Bool?) {
            guard let run else { return (0, nil) }
            return (run.depth, run.bullet)
        }
        func takeRun() {
            if runText.isEmpty { return }
            let text = cleanText(runText)
            runText = ""
            if !text.isEmpty {
                inlines.append(.text(text, style: runStyle))
            }
        }

        for scalar in shape.text.unicodeScalars {
            let d = levelDefault(paraProps(paraRun).depth)
            let style = Style(
                bold: charRun?.bold ?? d.bold ?? false,
                italic: charRun?.italic ?? d.italic ?? false,
                strike: false, code: false)
            if scalar == "\r" {
                takeRun()
                let props = paraProps(paraRun)
                paragraphs.append((inlines: inlines, depth: props.depth, bullet: props.bullet))
                inlines = []
            } else if scalar == "\u{b}" {
                takeRun()
                inlines.append(.lineBreak)
            } else {
                if style != runStyle && !runText.isEmpty {
                    takeRun()
                }
                runStyle = style
                runText.unicodeScalars.append(scalar)
            }
            // Advance run cursors by the character's UTF-16 width.
            let width = scalar.value > 0xFFFF ? 2 : 1
            charLeft = charLeft >= width ? charLeft - width : 0
            if charLeft == 0 {
                charIndex += 1
                charRun = styles.chars[safe: charIndex]
                charLeft = charRun?.count ?? Int.max
            }
            paraLeft = paraLeft >= width ? paraLeft - width : 0
            if paraLeft == 0 {
                paraIndex += 1
                paraRun = styles.paragraphs[safe: paraIndex]
                paraLeft = paraRun?.count ?? Int.max
            }
        }
        takeRun()
        if !inlines.isEmpty {
            let props = paraProps(paraRun)
            paragraphs.append((inlines: inlines, depth: props.depth, bullet: props.bullet))
        }

        for paragraph in paragraphs {
            var content = paragraph.inlines
            if inlinesAreEmpty(content) {
                flushList(&current, &listRun)
                continue
            }
            if isTitle {
                flushList(&current, &listRun)
                let d = levelDefault(paragraph.depth)
                let base = StyleDelta(bold: d.bold, italic: d.italic)
                rebaseEmphasis(&content, base: base.apply(.plain))
                current.append(
                    .heading(
                        level: 2, anchor: inlinesToPlainText(content), content: content))
                continue
            }
            let bullet = paragraph.bullet ?? levelDefault(paragraph.depth).bullet ?? false
            if bullet {
                listRun.append(
                    ListEntry(
                        level: Int(paragraph.depth),
                        key: ListKey(instance: shapeId, marker: .bullet),
                        number: 0, label: nil, blocks: [.paragraph(content)]))
            } else {
                flushList(&current, &listRun)
                current.append(.paragraph(content))
            }
        }
    }
}

/// UTF-16LE without BOM handling: PPT text atoms are raw code units, and a
/// leading U+FEFF would be content rather than a mark.
private func decodeUtf16NoBom(_ body: ArraySlice<UInt8>) -> String {
    var units: [UInt16] = []
    units.reserveCapacity(body.count / 2)
    var i = body.startIndex
    while i + 1 < body.endIndex {
        units.append(UInt16(body[i]) | (UInt16(body[i + 1]) << 8))
        i += 2
    }
    var out = String.UnicodeScalarView()
    var j = 0
    while j < units.count {
        let unit = units[j]
        if unit < 0xD800 || unit > 0xDFFF {
            out.append(Unicode.Scalar(unit)!)
            j += 1
        } else if unit >= 0xDC00 {
            out.append("\u{FFFD}")
            j += 1
        } else if j + 1 < units.count, (0xDC00...0xDFFF).contains(units[j + 1]) {
            let value = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(units[j + 1] - 0xDC00)
            out.append(Unicode.Scalar(value)!)
            j += 2
        } else {
            out.append("\u{FFFD}")
            j += 1
        }
    }
    return String(out)
}
