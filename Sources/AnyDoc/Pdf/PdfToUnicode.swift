/// `ToUnicode` CMap parsing (ISO 32000-1 §9.10.3), ported from
/// `ToUnicodeCMap::parse` in pdf-inspector's `tounicode.rs`.
///
/// A CMap maps the character codes a content stream shows to Unicode. The
/// reference scans the decoded CMap as text rather than running a PostScript
/// interpreter over it, because the constructs that matter — the codespace
/// ranges and the `bfchar`/`bfrange` sections — are a fixed shape.
///
/// **This file was rewritten in wave 97.** Wave 5 ported it by
/// reimplementing the scan and flattening every mapping into one dictionary,
/// which was simpler and wrong in four ways that only a differential probe
/// against the reference could show: direct mappings must outrank ranges
/// whatever order they appear in; a one-byte destination is legal; an
/// unpaired surrogate voids its whole destination rather than being dropped
/// from it; and the code width is inferred from the entries when the
/// codespace disagrees with them. The structure below is the reference's,
/// because the structure is what carries those behaviours.

struct PdfToUnicodeCMap {
    /// Direct mappings from `bfchar`, and from `bfrange`'s array form.
    /// **These outrank ranges** — see `lookup`.
    fileprivate(set) var charMap: [UInt16: String] = [:]
    /// `bfrange`'s base form, held unexpanded as `(start, end, base)`. A
    /// range covering the whole code space costs three numbers here; the
    /// earlier port expanded them and had to cap the size to stay safe.
    fileprivate(set) var ranges: [(start: UInt16, end: UInt16, base: UInt32)] = []
    /// How many bytes a code occupies. One for a simple encoding, two for a
    /// CID font — but see the inference in `parsePdfToUnicode`, which does
    /// not simply believe the codespace.
    fileprivate(set) var codeByteLength: Int = 2

    /// The string a code maps to, if any.
    ///
    /// A direct mapping wins outright. Only if there is none are the ranges
    /// consulted — and then just the two nearest the code, which is the
    /// reference's binary search reproduced rather than a full scan. With
    /// overlapping ranges that can miss a match a linear search would find.
    private func lookupCid(_ cid: UInt16) -> String? {
        if let direct = charMap[cid] { return direct }

        // `binary_search_by` returns the index of an exact hit, or where the
        // code would be inserted.
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if ranges[middle].start < cid {
                low = middle + 1
            } else if ranges[middle].start > cid {
                high = middle
            } else {
                low = middle
                break
            }
        }
        let index = low

        // The range at that index, then the one before it. Note a match
        // whose arithmetic lands outside Unicode does **not** stop the
        // search — it falls through, as the reference's `if let` does.
        for candidate in [index, index - 1] where candidate >= 0 && candidate < ranges.count {
            let range = ranges[candidate]
            if cid >= range.start && cid <= range.end {
                let value = range.base + UInt32(cid - range.start)
                if let scalar = Unicode.Scalar(value), !(0xD800...0xDFFF).contains(value) {
                    return String(Character(scalar))
                }
            }
        }
        return nil
    }

    /// Codes above `0xFFFF` cannot appear: the reference parses them with a
    /// 16-bit reader, so a wider code never enters the map.
    /// The lowest and highest source CID the map mentions, across both
    /// `bfchar` entries and `bfrange` starts.
    ///
    /// These exist for one caller: the subset-remap check in
    /// `PdfSubsetRemap.swift`, which reads a high minimum as evidence that
    /// the CMap was written against a font's *pre-subsetting* glyph ids.
    var minSourceCid: UInt16? {
        [charMap.keys.min(), ranges.map(\.start).min()].compactMap { $0 }.min()
    }

    var maxSourceCid: UInt16? {
        [charMap.keys.max(), ranges.map(\.end).max()].compactMap { $0 }.max()
    }

    /// Renumber every mapping onto sequential CIDs starting at 1.
    ///
    /// A subsetting producer renumbers the glyphs it keeps into 1, 2, 3, …
    /// but writes a `/ToUnicode` still keyed by the original glyph ids. The
    /// content stream then draws CIDs the CMap has no entry for, and the page
    /// extracts as nothing at all. Sorting the old CIDs and reassigning them
    /// in order recovers the text — *if* the guess is right, which is why the
    /// result is a candidate to be scored rather than a replacement.
    ///
    /// Starting at 1, not 0: glyph 0 is `.notdef` and no content stream draws
    /// it deliberately.
    func remapToSequential() -> PdfToUnicodeCMap {
        var cidToUnicode: [UInt16: String] = [:]
        // Ranges first, so a `bfchar` entry for the same CID overrides one —
        // the same precedence `lookup` applies.
        for range in ranges {
            for cid in range.start...range.end {
                let scalarValue = range.base + UInt32(cid - range.start)
                guard let scalar = Unicode.Scalar(scalarValue) else { continue }
                cidToUnicode[cid] = String(Character(scalar))
            }
        }
        for (cid, text) in charMap { cidToUnicode[cid] = text }

        var remapped = PdfToUnicodeCMap()
        for (index, oldCid) in cidToUnicode.keys.sorted().enumerated() {
            remapped.charMap[UInt16(index + 1)] = cidToUnicode[oldCid]
        }
        remapped.codeByteLength = codeByteLength
        return remapped
    }

    func lookup(_ code: UInt32) -> String? {
        guard code <= 0xFFFF else { return nil }
        return lookupCid(UInt16(code))
    }

    /// Direct mappings plus ranges, which is how the reference measures a
    /// CMap's density when deciding whether to fall back.
    var entryCount: Int { charMap.count + ranges.count }

    /// The reference's `parse` returns nothing at all when no mapping was
    /// found; this port models that as an empty map.
    var isEmpty: Bool { charMap.isEmpty && ranges.isEmpty }
}

/// Parse a decoded `ToUnicode` stream.
func parsePdfToUnicode(_ content: [UInt8]) -> PdfToUnicodeCMap {
    var cmap = PdfToUnicodeCMap()
    let text = Array(content)
    /// The digit count of every source code seen, which decides the code
    /// width when the codespace is absent or disagrees.
    var sourceHexLengths: [Int] = []

    // The codespace range, if declared. The *last* pair in the section wins,
    // because the reference overwrites as it scans.
    var codespaceByteLength: Int?
    if let section = sectionBody(text, begin: "begincodespacerange", end: "endcodespacerange") {
        var scanner = PdfHexScanner(text, range: section)
        while let digits = scanner.nextHexDigits() {
            if !digits.isEmpty { codespaceByteLength = (digits.count + 1) / 2 }
        }
    }

    // `beginbfchar`: pairs of <src> <dst>.
    var searchFrom = 0
    while let section = sectionBody(text, begin: "beginbfchar", end: "endbfchar", from: searchFrom) {
        var scanner = PdfHexScanner(text, range: section)
        while let source = scanner.nextHexDigits() {
            guard let destination = scanner.nextHexDigits() else { break }
            if !source.isEmpty { sourceHexLengths.append(source.count) }
            guard let code = pdfParseHexU16(String(decoding: source, as: UTF8.self)),
                let value = pdfHexToUnicodeString(String(decoding: destination, as: UTF8.self))
            else { continue }
            cmap.charMap[code] = value
        }
        searchFrom = section.upperBound
    }

    // `beginbfrange`: <lo> <hi> <dst>, or <lo> <hi> [<d1> <d2> ...].
    searchFrom = 0
    while let section = sectionBody(text, begin: "beginbfrange", end: "endbfrange", from: searchFrom)
    {
        var scanner = PdfHexScanner(text, range: section)
        while let lowDigits = scanner.nextHexDigits() {
            if !lowDigits.isEmpty { sourceHexLengths.append(lowDigits.count) }
            guard let highDigits = scanner.nextHexDigits() else { break }
            let low = pdfParseHexU16(String(decoding: lowDigits, as: UTF8.self))
            let high = pdfParseHexU16(String(decoding: highDigits, as: UTF8.self))

            switch scanner.nextDestination() {
            case .single(let digits):
                // The base must denote exactly one scalar. A ligature base —
                // `<0004> <0004> <00660066>` — maps to nothing at all rather
                // than to `ff`, which loses text the font really shows.
                if let low, let high,
                    let base = pdfHexToUnicodeScalar(String(decoding: digits, as: UTF8.self))
                {
                    // Stored unchecked: an inverted range is kept, and simply
                    // never matches. That still makes the CMap non-empty,
                    // which is observable.
                    cmap.ranges.append((start: low, end: high, base: base))
                }
            case .array(let entries):
                guard let low, let high else { break }
                var code = low
                for digits in entries {
                    if let value = pdfHexToUnicodeString(String(decoding: digits, as: UTF8.self)) {
                        cmap.charMap[code] = value
                    }
                    // The array stops at the range's end even if more
                    // entries follow, and `>=` means a one-code range takes
                    // exactly one entry.
                    if code >= high { break }
                    code = code &+ 1
                }
            case .none:
                break
            }
        }
        searchFrom = section.upperBound
    }

    if cmap.isEmpty { return cmap }

    // The code width. A codespace of `<0000> <FFFF>` beside entries that are
    // all one byte is a producer's boilerplate, not a description — so the
    // entries win.
    if let declared = codespaceByteLength {
        cmap.codeByteLength =
            (declared == 2 && !sourceHexLengths.isEmpty && sourceHexLengths.allSatisfy { $0 <= 2 })
            ? 1 : declared
    } else if let longest = sourceHexLengths.max() {
        cmap.codeByteLength = longest <= 2 ? 1 : 2
    } else {
        cmap.codeByteLength = 2
    }

    // Sorted for the binary search in `lookup`. The reference sorts
    // unstably, so two ranges sharing a start are in an unspecified order
    // there; this port keeps them in the order they were read.
    cmap.ranges = cmap.ranges.enumerated().sorted {
        $0.element.start != $1.element.start
            ? $0.element.start < $1.element.start : $0.offset < $1.offset
    }.map(\.element)

    return cmap
}

/// The byte range between a `begin...`/`end...` keyword pair.
private func sectionBody(
    _ text: [UInt8], begin: String, end: String, from: Int = 0
) -> Range<Int>? {
    guard let beginAt = find(text, Array(begin.utf8), from: from) else { return nil }
    let bodyStart = beginAt + begin.utf8.count
    guard let endAt = find(text, Array(end.utf8), from: bodyStart) else { return nil }
    return bodyStart..<endAt
}

private func find(_ haystack: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
    guard !needle.isEmpty, from >= 0, haystack.count >= needle.count else { return nil }
    var i = max(0, from)
    while i + needle.count <= haystack.count {
        var matched = true
        for k in 0..<needle.count where haystack[i + k] != needle[k] {
            matched = false
            break
        }
        if matched { return i }
        i += 1
    }
    return nil
}

/// Walks `<hex>` tokens and `[...]` destination arrays inside a CMap section.
private struct PdfHexScanner {
    let text: [UInt8]
    var pos: Int
    let end: Int

    init(_ text: [UInt8], range: Range<Int>) {
        self.text = text
        self.pos = range.lowerBound
        self.end = min(range.upperBound, text.count)
    }

    enum Destination {
        case single([UInt8])
        case array([[UInt8]])
        case none
    }

    /// The digits of the next `<...>` token.
    mutating func nextHexDigits() -> [UInt8]? {
        while pos < end, text[pos] != UInt8(ascii: "<") {
            // A `[` means the next token is a destination array, not a plain
            // hex string; the caller handles it.
            if text[pos] == UInt8(ascii: "[") { return nil }
            pos += 1
        }
        guard pos < end else { return nil }
        pos += 1
        var digits: [UInt8] = []
        while pos < end, text[pos] != UInt8(ascii: ">") {
            let c = text[pos]
            if !PdfLexer.isWhitespace(c) { digits.append(c) }
            pos += 1
        }
        if pos < end { pos += 1 }
        return digits
    }

    /// The destination of a `bfrange` entry: one hex string or an array.
    mutating func nextDestination() -> Destination {
        while pos < end, PdfLexer.isWhitespace(text[pos]) { pos += 1 }
        guard pos < end else { return .none }
        if text[pos] == UInt8(ascii: "[") {
            pos += 1
            var entries: [[UInt8]] = []
            while pos < end, text[pos] != UInt8(ascii: "]") {
                if text[pos] == UInt8(ascii: "<") {
                    pos += 1
                    var digits: [UInt8] = []
                    while pos < end, text[pos] != UInt8(ascii: ">") {
                        if !PdfLexer.isWhitespace(text[pos]) { digits.append(text[pos]) }
                        pos += 1
                    }
                    if pos < end { pos += 1 }
                    entries.append(digits)
                } else {
                    pos += 1
                }
            }
            if pos < end { pos += 1 }
            return .array(entries)
        }
        guard let digits = nextHexDigits() else { return .none }
        return .single(digits)
    }
}
