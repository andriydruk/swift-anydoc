/// PDF stream filters (ISO 32000-1 §7.4), ported from `lopdf`'s
/// `decompressed_content`.
///
/// Only the filters the reference implements are here. `ASCIIHexDecode` and
/// `RunLengthDecode` are deliberately absent: `lopdf` returns
/// "unimplemented" for them, and a stream using one is skipped rather than
/// silently decoded differently from the reference. The image filters
/// (`DCTDecode`, `JPXDecode`) are likewise not decoded — their payloads are
/// image bytes, not content.

/// A decoded stream, or the reason it could not be decoded.
enum PdfFilterResult {
    case decoded([UInt8])
    /// A filter the reference does not implement either.
    case unsupported(name: String)
    case failed(String)
}

/// Decode a stream's content through its `/Filter` chain.
func pdfDecodeStream(_ stream: PdfStream, maxOutput: Int) -> PdfFilterResult {
    guard let filterObject = stream.dict["Filter"] else {
        // No /Filter: the stream is stored as-is.
        return .decoded(stream.content)
    }
    let filters: [[UInt8]]
    if let name = filterObject.asName {
        filters = [name]
    } else if let array = filterObject.asArray {
        var names: [[UInt8]] = []
        for entry in array {
            guard let name = entry.asName else {
                return .failed("/Filter array holds a non-name entry")
            }
            names.append(name)
        }
        filters = names
    } else {
        return .failed("/Filter is neither a name nor an array")
    }

    // The reference reads /DecodeParms as a single dictionary, so a
    // per-filter array of parameter dictionaries is not consulted.
    let params = stream.dict["DecodeParms"]?.asDictionary

    var data = stream.content
    for filter in filters {
        switch String(decoding: filter, as: UTF8.self) {
        case "FlateDecode":
            guard let inflated = inflateZlib(data, maxOutput: maxOutput) else {
                return .failed("corrupt flate stream")
            }
            data = inflated
        case "LZWDecode":
            let earlyChange = params?["EarlyChange"]?.asInteger.map { $0 != 0 } ?? true
            data = lzwDecode(data, earlyChange: earlyChange, maxOutput: maxOutput)
        case "ASCII85Decode":
            guard let decoded = ascii85Decode(data) else {
                return .failed("corrupt ascii85 stream")
            }
            data = decoded
        case let name:
            return .unsupported(name: name)
        }
        guard let predicted = applyPredictor(data, params) else {
            return .failed("corrupt predictor data")
        }
        data = predicted
    }
    return .decoded(data)
}

/// Inflate a zlib-wrapped stream (RFC 1950). On failure the reference retries
/// as raw deflate past the two-byte header, which recovers streams whose
/// checksum is wrong — common in encrypted files and sloppy producers.
func inflateZlib(_ input: [UInt8], maxOutput: Int) -> [UInt8]? {
    if input.isEmpty { return [] }
    // A zlib header is CMF+FLG with CM=8 and the pair a multiple of 31.
    if input.count > 2, input[0] & 0x0F == 8, (UInt16(input[0]) << 8 | UInt16(input[1])) % 31 == 0 {
        if let result = try? inflateRaw(input[2...], maxOutput: maxOutput) {
            return result.bytes
        }
    }
    // Either the header did not look like zlib, or the stream past it was
    // corrupt: try the whole buffer as raw deflate, then past the header.
    if let result = try? inflateRaw(input[...], maxOutput: maxOutput) {
        return result.bytes
    }
    if input.count > 2, let result = try? inflateRaw(input[2...], maxOutput: maxOutput) {
        return result.bytes
    }
    return nil
}

/// LZW as PDF uses it (§7.4.4): MSB-first codes, 9 to 12 bits, code 256
/// clears the table and 257 ends the stream. `earlyChange` (the default)
/// grows the code width one code sooner, which is what TIFF and PDF writers
/// emit.
func lzwDecode(_ input: [UInt8], earlyChange: Bool, maxOutput: Int) -> [UInt8] {
    var output: [UInt8] = []
    // Table entries are (prefix index, final byte); the first 256 are the
    // single bytes and 256/257 are the control codes.
    var prefixes: [Int32] = []
    var suffixes: [UInt8] = []
    var previous: Int = -1
    var codeWidth = 9
    var bitBuffer: UInt32 = 0
    var bitCount = 0

    func resetTable() {
        prefixes.removeAll(keepingCapacity: true)
        suffixes.removeAll(keepingCapacity: true)
        for byte in 0..<256 {
            prefixes.append(-1)
            suffixes.append(UInt8(byte))
        }
        // 256 = clear, 257 = end of data.
        prefixes.append(-1)
        suffixes.append(0)
        prefixes.append(-1)
        suffixes.append(0)
        codeWidth = 9
        previous = -1
    }
    resetTable()

    /// Expand one table entry to its bytes, walking the prefix chain.
    func expand(_ code: Int) -> [UInt8]? {
        var out: [UInt8] = []
        var cursor = code
        // The chain cannot be longer than the table.
        var steps = 0
        while cursor >= 0 {
            guard cursor < suffixes.count, steps <= suffixes.count else { return nil }
            out.append(suffixes[cursor])
            cursor = Int(prefixes[cursor])
            steps += 1
        }
        return out.reversed()
    }

    for byte in input {
        bitBuffer = (bitBuffer << 8) | UInt32(byte)
        bitCount += 8
        while bitCount >= codeWidth {
            let code = Int((bitBuffer >> UInt32(bitCount - codeWidth)) & ((1 << UInt32(codeWidth)) - 1))
            bitCount -= codeWidth
            if code == 256 {
                resetTable()
                continue
            }
            if code == 257 { return output }
            var entry: [UInt8]
            if code < suffixes.count {
                guard let expanded = expand(code) else { return output }
                entry = expanded
            } else if previous >= 0, let expanded = expand(previous), let first = expanded.first {
                // The "code not yet in the table" case: it is the previous
                // entry plus its own first byte.
                entry = expanded + [first]
            } else {
                return output
            }
            if output.count + entry.count > maxOutput { return output }
            output.append(contentsOf: entry)
            if previous >= 0, let first = entry.first, suffixes.count < 4096 {
                prefixes.append(Int32(previous))
                suffixes.append(first)
            }
            previous = code
            // The width grows as the table fills; early change grows it one
            // code sooner.
            let limit = earlyChange ? suffixes.count + 1 : suffixes.count
            if limit >= 512 && codeWidth == 9 {
                codeWidth = 10
            } else if limit >= 1024 && codeWidth == 10 {
                codeWidth = 11
            } else if limit >= 2048 && codeWidth == 11 {
                codeWidth = 12
            }
        }
    }
    return output
}

/// ASCII85 (§7.4.3). `z` stands for four zero bytes and is only legal at a
/// group boundary; a character outside `!`...`u` ends the data.
func ascii85Decode(_ input: [UInt8]) -> [UInt8]? {
    var output: [UInt8] = []
    var buffer: UInt32 = 0
    var count = 0
    // The EOD marker is optional in practice; the reference logs and carries on.
    var body = input[...]
    if input.count >= 2, input[input.count - 2] == UInt8(ascii: "~"),
        input[input.count - 1] == UInt8(ascii: ">")
    {
        body = input[..<(input.count - 2)]
    }
    for ch in body {
        if ch == UInt8(ascii: "z") {
            if count != 0 { return nil }
            output.append(contentsOf: [0, 0, 0, 0])
            continue
        }
        if PdfLexer.isWhitespace(ch) { continue }
        if ch < UInt8(ascii: "!") || ch > UInt8(ascii: "u") { break }
        let (scaled, overflow) = buffer.multipliedReportingOverflow(by: 85)
        if overflow { return nil }
        buffer = scaled &+ UInt32(ch - UInt8(ascii: "!"))
        count += 1
        if count == 5 {
            output.append(contentsOf: bigEndianBytes(buffer))
            buffer = 0
            count = 0
        }
    }
    if count > 0 {
        // A partial group is padded with the maximum digit.
        for _ in count..<5 {
            let (scaled, overflow) = buffer.multipliedReportingOverflow(by: 85)
            if overflow { return nil }
            buffer = scaled &+ 84
        }
        output.append(contentsOf: bigEndianBytes(buffer)[..<(count - 1)])
    }
    return output
}

private func bigEndianBytes(_ value: UInt32) -> [UInt8] {
    [
        UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
    ]
}

/// Undo a `/Predictor`. Only the PNG predictors (10-15) are applied, matching
/// the reference: `/Predictor 2` (the TIFF predictor) passes through
/// untouched there, so it does here too.
func applyPredictor(_ data: [UInt8], _ params: PdfDictionary?) -> [UInt8]? {
    guard let params else { return data }
    let predictor = params["Predictor"]?.asInteger ?? 1
    guard (10...15).contains(predictor) else { return data }
    let columns = max(1, Int(params["Columns"]?.asInteger ?? 1))
    let colors = max(1, Int(params["Colors"]?.asInteger ?? 1))
    // Sub-byte component depths are rounded up to a byte, as in the reference.
    let bits = max(8, Int(params["BitsPerComponent"]?.asInteger ?? 8))
    let bytesPerPixel = colors * bits / 8
    guard bytesPerPixel > 0 else { return data }
    return pngDecodeFrame(data, bytesPerPixel: bytesPerPixel, pixelsPerRow: columns)
}

/// Undo PNG row filtering. Each row is a filter-type byte then `bytesPerRow`
/// bytes; a row that runs past the end of the data is an error, as it is in
/// the reference's `read_exact`.
func pngDecodeFrame(_ content: [UInt8], bytesPerPixel: Int, pixelsPerRow: Int) -> [UInt8]? {
    let bytesPerRow = bytesPerPixel * pixelsPerRow
    guard bytesPerRow > 0 else { return nil }
    var previous = [UInt8](repeating: 0, count: bytesPerRow)
    var current = [UInt8](repeating: 0, count: bytesPerRow)
    var decoded: [UInt8] = []
    var pos = 0
    while pos < content.count {
        let filter = content[pos]
        guard filter <= 4 else { return nil }
        pos += 1
        guard pos + bytesPerRow <= content.count else { return nil }
        for i in 0..<bytesPerRow { current[i] = content[pos + i] }
        pos += bytesPerRow
        pngDecodeRow(filter, bytesPerPixel, previous, &current)
        decoded.append(contentsOf: current)
        swap(&previous, &current)
    }
    return decoded
}

private func pngDecodeRow(
    _ filter: UInt8, _ bytesPerPixel: Int, _ previous: [UInt8], _ current: inout [UInt8]
) {
    let len = current.count
    let bpp = min(bytesPerPixel, len)
    switch filter {
    case 0:  // None
        break
    case 1:  // Sub
        for i in bpp..<len { current[i] = current[i] &+ current[i - bpp] }
    case 2:  // Up
        for i in 0..<len { current[i] = current[i] &+ previous[i] }
    case 3:  // Average
        for i in 0..<bpp { current[i] = current[i] &+ (previous[i] / 2) }
        for i in bpp..<len {
            // Reproduces an upstream bug: the PNG specification averages the
            // two neighbours, `(left + above) / 2`, and lopdf's own *encoder*
            // does exactly that — but its decoder halves only `above`. Byte
            // parity with the reference is the contract here, so the bug is
            // reproduced rather than corrected. Fixing it would silently
            // change output for every stream using Predictor 13.
            let value = Int16(current[i - bpp]) + Int16(previous[i]) / 2
            current[i] = current[i] &+ UInt8(truncatingIfNeeded: value)
        }
    case 4:  // Paeth
        for i in 0..<bpp { current[i] = current[i] &+ paethPredict(0, previous[i], 0) }
        for i in bpp..<len {
            current[i] = current[i] &+ paethPredict(current[i - bpp], previous[i], previous[i - bpp])
        }
    default:
        break
    }
}

private func paethPredict(_ left: UInt8, _ above: UInt8, _ upperLeft: UInt8) -> UInt8 {
    let a = Int16(left)
    let b = Int16(above)
    let c = Int16(upperLeft)
    let estimate = a + b - c
    let distLeft = abs(estimate - a)
    let distAbove = abs(estimate - b)
    let distUpperLeft = abs(estimate - c)
    if distLeft <= distAbove && distLeft <= distUpperLeft { return left }
    if distAbove <= distUpperLeft { return above }
    return upperLeft
}
