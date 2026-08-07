/// Raw DEFLATE (RFC 1951) decompression. In-repo implementation — the
/// zero-dependency replacement for flate2/zip's inflater.
///
/// - Decompresses `input` as a raw deflate stream (no zlib/gzip wrapper).
/// - Never produces more than `maxOutput` bytes: when the budget is reached,
///   decompression stops and returns exactly `maxOutput` bytes with
///   `limitHit: true` (callers decide whether truncation is an error).
/// - Throws `ConvertError.malformed` on corrupt streams. The detail text is
///   "corrupt deflate stream", the message flate2 surfaces for every decode
///   failure, so archive error strings stay byte-compatible with Rust.
struct InflateResult {
    var bytes: [UInt8]
    /// True when output was truncated at `maxOutput` before the stream ended.
    var limitHit: Bool
}

func inflateRaw(_ input: ArraySlice<UInt8>, maxOutput: Int) throws -> InflateResult {
    var state = Inflater(input: input, maxOutput: max(0, maxOutput))
    return try state.run()
}

private func corruptStream() -> ConvertError {
    .malformed("corrupt deflate stream")
}

/// Canonical Huffman code, decoded bit-serially from the code-length counts
/// (the construction in RFC 1951 §3.2.2, as in zlib's contrib/puff).
private struct Huffman {
    /// `count[len]`: number of codes of each bit length, 0...15.
    var count: [Int]
    /// Symbols sorted by (length, symbol value).
    var symbol: [Int]

    /// Build from per-symbol code lengths. Returns `nil` when the code is
    /// over-subscribed; `left > 0` flags an incomplete code (callers decide
    /// whether that is permitted).
    static func construct(lengths: ArraySlice<Int>) -> (code: Huffman, left: Int)? {
        var count = [Int](repeating: 0, count: 16)
        for len in lengths {
            count[len] += 1
        }
        if count[0] == lengths.count {
            // No codes at all: complete by convention, decoding will fail.
            return (Huffman(count: count, symbol: []), 0)
        }
        // Check for an over-subscribed or incomplete set of lengths.
        var left = 1
        for len in 1...15 {
            left <<= 1
            left -= count[len]
            if left < 0 {
                return nil
            }
        }
        // Offsets into the symbol table for each length.
        var offs = [Int](repeating: 0, count: 16)
        for len in 1..<15 {
            offs[len + 1] = offs[len] + count[len]
        }
        var symbol = [Int](repeating: 0, count: lengths.count)
        for (i, len) in lengths.enumerated() where len != 0 {
            symbol[offs[len]] = i
            offs[len] += 1
        }
        return (Huffman(count: count, symbol: symbol), left)
    }
}

/// Fixed literal/length and distance codes (RFC 1951 §3.2.6).
private let fixedCodes: (len: Huffman, dist: Huffman) = {
    var lengths = [Int](repeating: 8, count: 288)
    for i in 144...255 { lengths[i] = 9 }
    for i in 256...279 { lengths[i] = 7 }
    let len = Huffman.construct(lengths: lengths[...])!.code
    let dist = Huffman.construct(lengths: [Int](repeating: 5, count: 30)[...])!.code
    return (len, dist)
}()

/// Extra bits and base values for length codes 257...285 (RFC 1951 §3.2.5).
private let lengthBase: [Int] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
]
private let lengthExtra: [Int] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
]

/// Extra bits and base values for distance codes 0...29.
private let distBase: [Int] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]
private let distExtra: [Int] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
]

/// Order in which code-length code lengths are stored (RFC 1951 §3.2.7).
private let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

private struct Inflater {
    let input: ArraySlice<UInt8>
    let maxOutput: Int
    var pos: Int
    var bitBuf: UInt32 = 0
    var bitCount: Int = 0
    var out: [UInt8] = []
    var limitHit = false

    init(input: ArraySlice<UInt8>, maxOutput: Int) {
        self.input = input
        self.maxOutput = maxOutput
        self.pos = input.startIndex
    }

    mutating func run() throws -> InflateResult {
        while true {
            let final = try bits(1)
            let type = try bits(2)
            switch type {
            case 0: try storedBlock()
            case 1: try codes(len: fixedCodes.len, dist: fixedCodes.dist)
            case 2:
                let (len, dist) = try dynamicTables()
                try codes(len: len, dist: dist)
            default:
                throw corruptStream()
            }
            if limitHit {
                return InflateResult(bytes: out, limitHit: true)
            }
            if final == 1 {
                return InflateResult(bytes: out, limitHit: false)
            }
        }
    }

    // MARK: bit input

    mutating func bits(_ n: Int) throws -> Int {
        while bitCount < n {
            guard pos < input.endIndex else { throw corruptStream() }
            bitBuf |= UInt32(input[pos]) << bitCount
            pos += 1
            bitCount += 8
        }
        let value = Int(bitBuf & ((1 << UInt32(n)) - 1))
        bitBuf >>= n
        bitCount -= n
        return value
    }

    /// Decode one symbol bit-serially against a canonical code. A walk that
    /// exhausts all 15 lengths ran off the code (incomplete code hit).
    mutating func decode(_ h: Huffman) throws -> Int {
        var code = 0
        var first = 0
        var index = 0
        for len in 1...15 {
            code |= try bits(1)
            let count = h.count[len]
            if code - first < count {
                return h.symbol[index + (code - first)]
            }
            index += count
            first = (first + count) << 1
            code <<= 1
        }
        throw corruptStream()
    }

    // MARK: output, budget-capped

    /// Append one byte unless the budget is exhausted; false stops the block.
    mutating func emit(_ byte: UInt8) -> Bool {
        if out.count >= maxOutput {
            limitHit = true
            return false
        }
        out.append(byte)
        return true
    }

    // MARK: block types

    mutating func storedBlock() throws {
        // Discard bits to the next byte boundary; LEN and its complement.
        bitBuf = 0
        bitCount = 0
        guard pos + 4 <= input.endIndex else { throw corruptStream() }
        let len = Int(input[pos]) | Int(input[pos + 1]) << 8
        let nlen = Int(input[pos + 2]) | Int(input[pos + 3]) << 8
        pos += 4
        guard len ^ 0xFFFF == nlen else { throw corruptStream() }
        guard pos + len <= input.endIndex else { throw corruptStream() }
        for i in 0..<len {
            if !emit(input[pos + i]) {
                pos += len
                return
            }
        }
        pos += len
    }

    mutating func dynamicTables() throws -> (Huffman, Huffman) {
        let nlen = try bits(5) + 257
        let ndist = try bits(5) + 1
        let ncode = try bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw corruptStream() }

        var clLengths = [Int](repeating: 0, count: 19)
        for i in 0..<ncode {
            clLengths[codeLengthOrder[i]] = try bits(3)
        }
        // The code-length code must be complete.
        guard let (clCode, clLeft) = Huffman.construct(lengths: clLengths[...]), clLeft == 0 else {
            throw corruptStream()
        }

        var lengths = [Int](repeating: 0, count: nlen + ndist)
        var index = 0
        while index < nlen + ndist {
            let symbol = try decode(clCode)
            switch symbol {
            case 0...15:
                lengths[index] = symbol
                index += 1
            case 16:
                guard index > 0 else { throw corruptStream() }
                let repeatLen = lengths[index - 1]
                let count = 3 + (try bits(2))
                guard index + count <= nlen + ndist else { throw corruptStream() }
                for _ in 0..<count {
                    lengths[index] = repeatLen
                    index += 1
                }
            case 17:
                let count = 3 + (try bits(3))
                guard index + count <= nlen + ndist else { throw corruptStream() }
                index += count
            case 18:
                let count = 11 + (try bits(7))
                guard index + count <= nlen + ndist else { throw corruptStream() }
                index += count
            default:
                throw corruptStream()
            }
        }
        // The end-of-block code must exist.
        guard lengths[256] != 0 else { throw corruptStream() }

        // Incomplete codes are permitted only in the degenerate single-code
        // form (all assigned codes have length 1), as in zlib.
        guard let (lenCode, lenLeft) = Huffman.construct(lengths: lengths[..<nlen]) else {
            throw corruptStream()
        }
        if lenLeft > 0, nlen != lenCode.count[0] + lenCode.count[1] {
            throw corruptStream()
        }
        guard let (distCode, distLeft) = Huffman.construct(lengths: lengths[nlen...]) else {
            throw corruptStream()
        }
        if distLeft > 0, ndist != distCode.count[0] + distCode.count[1] {
            throw corruptStream()
        }
        return (lenCode, distCode)
    }

    mutating func codes(len lenCode: Huffman, dist distCode: Huffman) throws {
        while true {
            let symbol = try decode(lenCode)
            if symbol < 256 {
                if !emit(UInt8(symbol)) {
                    return
                }
            } else if symbol == 256 {
                return
            } else {
                guard symbol - 257 < lengthBase.count else { throw corruptStream() }
                let length = lengthBase[symbol - 257] + (try bits(lengthExtra[symbol - 257]))
                let distSymbol = try decode(distCode)
                guard distSymbol < distBase.count else { throw corruptStream() }
                let distance = distBase[distSymbol] + (try bits(distExtra[distSymbol]))
                // Raw deflate has no preset dictionary: a copy from before
                // the start of output is corrupt.
                guard distance <= out.count else { throw corruptStream() }
                for _ in 0..<length {
                    if !emit(out[out.count - distance]) {
                        return
                    }
                }
            }
        }
    }
}
