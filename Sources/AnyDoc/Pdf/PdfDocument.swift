/// The PDF cross-reference layer and object resolution (ISO 32000-1 §7.5),
/// ported from `lopdf`'s reader.
///
/// A PDF is read backwards: `startxref` at the end names the cross-reference
/// section, which maps object numbers to byte offsets, and `/Prev` chains
/// back through earlier incremental updates. Both the classic table form and
/// the PDF 1.5 stream form are supported, as are the object streams that let
/// small objects live compressed inside another object.

/// Where an object lives.
enum PdfXrefEntry {
    /// A byte offset into the file.
    case normal(offset: Int, generation: UInt16)
    /// Inside an object stream: the container's object number, and the
    /// index of this object within it.
    case compressed(container: UInt32, index: Int)
}

/// The resolved cross-reference table.
struct PdfXref {
    var entries: [UInt32: PdfXrefEntry] = [:]
    var size: Int = 0
}

/// Caps on the structural work a file can demand. Malformed and hostile
/// files reach these; well-formed ones never do.
enum PdfLimits {
    /// `/Prev` chain length. Real files use a handful of updates.
    static let maxXrefSections = 64
    /// Depth of reference-following when resolving one object.
    static let maxResolveDepth = 32
    /// Objects an object stream may declare.
    static let maxObjectStreamEntries = 100_000
}

/// A parsed PDF file: its cross-reference table, trailer, and the objects
/// reachable through them.
struct PdfDocument {
    let bytes: [UInt8]
    private(set) var xref = PdfXref()
    private(set) var trailer = PdfDictionary()
    /// Objects already parsed, by id. Object streams populate this in bulk.
    private var cache: [PdfObjectId: PdfObject] = [:]
    /// Object streams already expanded, so each is inflated at most once.
    private var expandedStreams: Set<UInt32> = []

    init(bytes: [UInt8]) throws {
        self.bytes = bytes
        guard let headerEnd = findHeader(bytes) else {
            throw ConvertError.malformed("not a PDF file: no %PDF- header")
        }
        _ = headerEnd
        try loadXref()
    }

    /// The document catalog (`/Root`), the entry point to the page tree.
    var catalog: PdfDictionary? {
        guard let root = trailer["Root"] else { return nil }
        var copy = self
        return copy.resolve(root).asDictionary
    }

    // MARK: cross-reference loading

    private mutating func loadXref() throws {
        guard let start = findStartXref(bytes) else {
            throw ConvertError.malformed("no startxref in the trailer")
        }
        var offset: Int? = start
        var seen: Set<Int> = []
        var sections = 0
        var combined = PdfXref()
        var firstTrailer: PdfDictionary?

        while let current = offset, sections < PdfLimits.maxXrefSections {
            // A /Prev pointing back at a section already read is a loop.
            if !seen.insert(current).inserted { break }
            sections += 1
            guard current >= 0, current < bytes.count else { break }
            guard let section = readXrefSection(at: current) else { break }
            // Earlier sections must not overwrite later ones: the newest
            // definition of an object wins, and it is read first.
            for (id, entry) in section.xref.entries where combined.entries[id] == nil {
                combined.entries[id] = entry
            }
            combined.size = max(combined.size, section.xref.size)
            if firstTrailer == nil { firstTrailer = section.trailer }
            // /XRefStm points at a cross-reference stream carrying entries a
            // hybrid file also wrote in classic form.
            if let hybrid = section.trailer["XRefStm"]?.asInteger.map(Int.init),
                seen.insert(hybrid).inserted, hybrid >= 0, hybrid < bytes.count,
                let extra = readXrefSection(at: hybrid)
            {
                for (id, entry) in extra.xref.entries where combined.entries[id] == nil {
                    combined.entries[id] = entry
                }
            }
            offset = section.trailer["Prev"]?.asInteger.map(Int.init)
        }

        guard let firstTrailer, !combined.entries.isEmpty else {
            throw ConvertError.malformed("no usable cross-reference table")
        }
        self.xref = combined
        self.trailer = firstTrailer
    }

    /// One cross-reference section: either `xref` + `trailer`, or an
    /// indirect object holding a cross-reference stream.
    private func readXrefSection(at offset: Int) -> (xref: PdfXref, trailer: PdfDictionary)? {
        var lexer = PdfLexer(bytes, at: offset)
        lexer.skipSpace()
        if let classic = readClassicXref(&lexer) { return classic }
        // PDF 1.5: the section is an indirect object whose stream holds the
        // table, and whose dictionary is the trailer.
        var streamLexer = PdfLexer(bytes, at: offset)
        guard let (_, object) = readIndirectObject(&streamLexer), let stream = object.asStream
        else { return nil }
        guard let xref = decodeXrefStream(stream) else { return nil }
        return (xref: xref, trailer: stream.dict)
    }

    /// The classic table: `xref`, then subsections of `start count` followed
    /// by 20-byte entries, then `trailer` and its dictionary.
    private func readClassicXref(_ lexer: inout PdfLexer) -> (xref: PdfXref, trailer: PdfDictionary)?
    {
        guard lexer.parseKeyword() == Array("xref".utf8) else { return nil }
        var xref = PdfXref()
        while true {
            let save = lexer.pos
            lexer.skipSpace()
            // A subsection header is two integers; anything else ends the table.
            guard let start = lexer.parseUnsignedInt() else {
                lexer.pos = save
                break
            }
            lexer.skipSpace()
            guard let count = lexer.parseUnsignedInt() else {
                lexer.pos = save
                break
            }
            guard count >= 0, count < 10_000_000 else { return nil }
            for index in 0..<count {
                lexer.skipSpace()
                guard let offset = lexer.parseUnsignedInt() else { return nil }
                lexer.skipSpace()
                guard let generation = lexer.parseUnsignedInt() else { return nil }
                lexer.skipSpace()
                guard let kind = lexer.parseKeyword(), kind.count == 1 else { return nil }
                // 'n' is in use, 'f' is free; only in-use entries are kept.
                if kind[0] == UInt8(ascii: "n"), generation <= Int(UInt16.max) {
                    let id = UInt32(truncatingIfNeeded: start + index)
                    if xref.entries[id] == nil {
                        xref.entries[id] = .normal(
                            offset: offset, generation: UInt16(truncatingIfNeeded: generation))
                    }
                }
            }
        }
        lexer.skipSpace()
        guard lexer.parseKeyword() == Array("trailer".utf8) else { return nil }
        guard let trailer = lexer.parseObject()?.asDictionary else { return nil }
        xref.size = Int(trailer["Size"]?.asInteger ?? 0)
        return (xref: xref, trailer: trailer)
    }

    /// A cross-reference stream: `/W` gives the three field widths, `/Index`
    /// the object-number ranges, and the decoded content is those fields
    /// back to back, big-endian.
    private func decodeXrefStream(_ stream: PdfStream) -> PdfXref? {
        guard case .decoded(let content) = pdfDecodeStream(stream, maxOutput: Int(Limits.maxEntryBytes))
        else { return nil }
        guard let size = stream.dict["Size"]?.asInteger else { return nil }
        guard let widthsArray = stream.dict["W"]?.asArray else { return nil }
        let widths = widthsArray.compactMap { $0.asInteger.map(Int.init) }
        guard widths.count >= 3, widths[0] >= 0, widths[1] >= 0, widths[2] >= 0 else { return nil }

        var index: [Int] = [0, Int(size)]
        if let declared = stream.dict["Index"]?.asArray {
            let values = declared.compactMap { $0.asInteger.map(Int.init) }
            if !values.isEmpty { index = values }
        }

        var xref = PdfXref()
        xref.size = Int(size)
        var pos = 0
        func readField(_ width: Int) -> Int? {
            if width == 0 { return nil }
            guard pos + width <= content.count else { return nil }
            var value = 0
            for _ in 0..<width {
                value = (value << 8) | Int(content[pos])
                pos += 1
            }
            return value
        }
        for section in stride(from: 0, to: index.count - 1, by: 2) {
            let start = index[section]
            let count = index[section + 1]
            guard count >= 0, count < 10_000_000 else { return nil }
            for offset in 0..<count {
                // A zero-width type field means type 1, per the spec.
                let type = widths[0] == 0 ? 1 : readField(widths[0])
                guard let type else { return nil }
                let second = readField(widths[1]) ?? 0
                let third = readField(widths[2]) ?? 0
                let id = UInt32(truncatingIfNeeded: start + offset)
                switch type {
                case 1:
                    if xref.entries[id] == nil {
                        xref.entries[id] = .normal(
                            offset: second, generation: UInt16(truncatingIfNeeded: third))
                    }
                case 2:
                    if xref.entries[id] == nil {
                        xref.entries[id] = .compressed(
                            container: UInt32(truncatingIfNeeded: second), index: third)
                    }
                default:
                    break  // type 0 is a free object
                }
            }
        }
        return xref
    }

    // MARK: object access

    /// The object with this id, or `.null` when it cannot be read.
    mutating func object(_ id: PdfObjectId) -> PdfObject {
        if let hit = cache[id] { return hit }
        guard let entry = xref.entries[id.number] else { return .null }
        switch entry {
        case .normal(let offset, _):
            guard offset >= 0, offset < bytes.count else { return .null }
            var lexer = PdfLexer(bytes, at: offset)
            guard let (parsedId, object) = readIndirectObject(&lexer) else { return .null }
            // A mismatched header means the offset is stale; the object is
            // not what the table promised.
            guard parsedId.number == id.number else { return .null }
            cache[id] = object
            return object
        case .compressed(let container, _):
            expandObjectStream(container)
            return cache[id] ?? .null
        }
    }

    /// Follow references until a direct object is reached.
    mutating func resolve(_ object: PdfObject) -> PdfObject {
        var current = object
        var depth = 0
        while case .reference(let id) = current, depth < PdfLimits.maxResolveDepth {
            current = self.object(id)
            depth += 1
        }
        if case .reference = current { return .null }
        return current
    }

    /// A dictionary entry, resolved.
    mutating func value(_ dict: PdfDictionary, _ key: String) -> PdfObject? {
        guard let raw = dict[key] else { return nil }
        let resolved = resolve(raw)
        return resolved.isNull ? nil : resolved
    }

    /// A stream's raw bytes with an indirect `/Length` resolved. The parser
    /// leaves such streams empty because the length lives in another object
    /// that may not have been read yet.
    mutating func rawStream(_ stream: PdfStream) -> PdfStream? {
        guard let position = stream.startPosition else { return stream }
        guard let length = value(stream.dict, "Length")?.asInteger.map(Int.init),
            length >= 0, position >= 0, position + length <= bytes.count
        else { return nil }
        var resolved = stream
        resolved.content = Array(bytes[position..<(position + length)])
        resolved.startPosition = nil
        return resolved
    }

    /// A stream's decoded bytes, or `nil` when it cannot be decoded.
    mutating func decodedStream(_ stream: PdfStream) -> [UInt8]? {
        guard let stream = rawStream(stream) else { return nil }
        switch pdfDecodeStream(stream, maxOutput: Int(Limits.maxEntryBytes)) {
        case .decoded(let data):
            return data
        case .unsupported(let name):
            Log.debug("skipping stream with unsupported filter \(name)")
            return nil
        case .failed(let reason):
            Log.debug("skipping undecodable stream: \(reason)")
            return nil
        }
    }

    /// Parse every object inside an object stream into the cache.
    private mutating func expandObjectStream(_ container: UInt32) {
        guard expandedStreams.insert(container).inserted else { return }
        let containerId = PdfObjectId(number: container, generation: 0)
        // Read the container directly: going through `object(_:)` would
        // recurse back here for a stream that claims to contain itself.
        guard case .normal(let offset, _) = xref.entries[container],
            offset >= 0, offset < bytes.count
        else { return }
        var lexer = PdfLexer(bytes, at: offset)
        guard let (_, object) = readIndirectObject(&lexer), let stream = object.asStream else {
            return
        }
        cache[containerId] = object
        guard let content = decodedStream(stream) else { return }
        guard let count = value(stream.dict, "N")?.asInteger.map(Int.init),
            let first = value(stream.dict, "First")?.asInteger.map(Int.init),
            count >= 0, count <= PdfLimits.maxObjectStreamEntries, first >= 0
        else { return }

        // The stream begins with `count` pairs of (object number, offset),
        // then the objects themselves starting at /First.
        var header = PdfLexer(content)
        var pairs: [(number: UInt32, offset: Int)] = []
        pairs.reserveCapacity(count)
        for _ in 0..<count {
            header.skipSpace()
            guard let number = header.parseUnsignedInt() else { break }
            header.skipSpace()
            guard let offset = header.parseUnsignedInt() else { break }
            pairs.append((number: UInt32(truncatingIfNeeded: number), offset: offset))
        }
        for pair in pairs {
            let start = first + pair.offset
            guard start >= 0, start < content.count else { continue }
            var body = PdfLexer(content, at: start)
            guard let parsed = body.parseObject() else { continue }
            let id = PdfObjectId(number: pair.number, generation: 0)
            // A compressed object never overrides one the table placed in
            // the file proper.
            if cache[id] == nil { cache[id] = parsed }
        }
    }

    // MARK: indirect objects

    /// `N G obj ... endobj`, including the stream form. Returns the id the
    /// header declares alongside the object.
    private func readIndirectObject(_ lexer: inout PdfLexer) -> (PdfObjectId, PdfObject)? {
        lexer.skipSpace()
        guard let number = lexer.parseUnsignedInt() else { return nil }
        lexer.skipSpace()
        guard let generation = lexer.parseUnsignedInt() else { return nil }
        lexer.skipSpace()
        guard lexer.parseKeyword() == Array("obj".utf8) else { return nil }
        guard let object = lexer.parseObject() else { return nil }
        let id = PdfObjectId(
            number: UInt32(truncatingIfNeeded: number),
            generation: UInt16(truncatingIfNeeded: generation))

        // A dictionary followed by `stream` is a stream object.
        guard let dict = object.asDictionary, case .dictionary = object else {
            return (id, object)
        }
        let save = lexer.pos
        guard lexer.takeStreamKeyword() else {
            lexer.pos = save
            return (id, object)
        }
        let dataStart = lexer.pos
        // A direct /Length can be trusted enough to slice with; an indirect
        // one is left for `decodedStream` to resolve against the document.
        if let length = dict["Length"]?.asInteger.map(Int.init), length >= 0,
            dataStart + length <= bytes.count
        {
            let content = Array(bytes[dataStart..<(dataStart + length)])
            return (id, .stream(PdfStream(dict: dict, content: content)))
        }
        if dict["Length"]?.asReference != nil {
            return (id, .stream(PdfStream(dict: dict, content: [], startPosition: dataStart)))
        }
        // No usable /Length: recover by scanning for `endstream`.
        guard let end = findKeyword(bytes, Array("endstream".utf8), from: dataStart) else {
            return (id, object)
        }
        var contentEnd = end
        // The EOL before `endstream` is delimiter, not data.
        if contentEnd > dataStart, bytes[contentEnd - 1] == 0x0A { contentEnd -= 1 }
        if contentEnd > dataStart, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
        let content = Array(bytes[dataStart..<max(dataStart, contentEnd)])
        return (id, .stream(PdfStream(dict: dict, content: content)))
    }
}

// MARK: - file-level scanning

/// The `%PDF-` header must appear near the start; some files put junk before
/// it, which shifts every offset in the file.
private func findHeader(_ bytes: [UInt8]) -> Int? {
    let marker = Array("%PDF-".utf8)
    let limit = min(bytes.count, 1024)
    guard limit >= marker.count else { return nil }
    for i in 0...(limit - marker.count) where Array(bytes[i..<(i + marker.count)]) == marker {
        return i
    }
    return nil
}

/// The offset `startxref` names, searched from the end of the file.
private func findStartXref(_ bytes: [UInt8]) -> Int? {
    let marker = Array("startxref".utf8)
    guard bytes.count >= marker.count else { return nil }
    for i in stride(from: bytes.count - marker.count, through: 0, by: -1)
    where Array(bytes[i..<(i + marker.count)]) == marker {
        var lexer = PdfLexer(bytes, at: i + marker.count)
        lexer.skipSpace()
        return lexer.parseUnsignedInt()
    }
    return nil
}

/// The next occurrence of `keyword` at or after `from`.
private func findKeyword(_ bytes: [UInt8], _ keyword: [UInt8], from: Int) -> Int? {
    guard from >= 0, keyword.count > 0, bytes.count >= keyword.count else { return nil }
    var i = from
    while i + keyword.count <= bytes.count {
        if Array(bytes[i..<(i + keyword.count)]) == keyword { return i }
        i += 1
    }
    return nil
}
