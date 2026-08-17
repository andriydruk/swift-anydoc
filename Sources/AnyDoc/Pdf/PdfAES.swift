/// AES-128 and AES-256 in CBC mode, for PDF's `/AESV2` and `/AESV3`
/// security handlers.
///
/// Like MD5 and RC4 in `PdfCrypto.swift`, this is not something the
/// reference implements — it hands the file to lopdf. And like those, it is
/// written out here because the algorithm is fully specified and has
/// published test vectors, which is what makes hand-rolling defensible.
///
/// **Encryption is implemented too, and only for one purpose.** The `/R 6`
/// key derivation (Algorithm 2.B) is defined in terms of AES-128-CBC
/// *encryption* of an intermediate buffer — the cipher is used there as a
/// mixing function, not to protect anything. Nothing in this package
/// encrypts a document.

/// The AES substitution box, and its inverse.
///
/// Tabulated rather than computed from the finite field, because the tables
/// are what the specification prints and a generated one is a place for an
/// error to hide.
private let pdfAESSBox: [UInt8] = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
]

private let pdfAESInverseSBox: [UInt8] = {
    var inverse = [UInt8](repeating: 0, count: 256)
    for (index, value) in pdfAESSBox.enumerated() { inverse[Int(value)] = UInt8(index) }
    return inverse
}()

/// Multiplication in GF(2^8), the field the whole cipher is defined over.
private func pdfGaloisMultiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
    var result: UInt8 = 0
    var x = a
    var y = b
    for _ in 0..<8 {
        if y & 1 != 0 { result ^= x }
        // The reduction polynomial is x⁸ + x⁴ + x³ + x + 1, or 0x11B — the
        // 0x1B is what remains after the overflowing bit is dropped.
        let high = x & 0x80
        x <<= 1
        if high != 0 { x ^= 0x1B }
        y >>= 1
    }
    return result
}

/// Expand a 128- or 256-bit key into the round keys the cipher consumes.
///
/// Eleven for AES-128, fifteen for AES-256. The 256-bit schedule differs in
/// more than length: it takes a `SubWord` at every fourth word *within* each
/// eight-word group as well, which a schedule written only for AES-128 has
/// no place for.
func pdfAESExpandKey(_ key: [UInt8]) -> [[UInt8]]? {
    guard key.count == 16 || key.count == 32 else { return nil }
    let keyWords = key.count / 4
    let rounds = keyWords == 4 ? 10 : 14
    let total = (rounds + 1) * 4

    var words: [[UInt8]] = stride(from: 0, to: key.count, by: 4).map {
        Array(key[$0..<($0 + 4)])
    }
    var rcon: UInt8 = 1
    for index in keyWords..<total {
        var word = words[index - 1]
        if index % keyWords == 0 {
            // Rotate, substitute, then add the round constant — the only
            // place the key schedule is not linear.
            word = [word[1], word[2], word[3], word[0]].map { pdfAESSBox[Int($0)] }
            word[0] ^= rcon
            rcon = pdfGaloisMultiply(rcon, 2)
        } else if keyWords == 8 && index % keyWords == 4 {
            // AES-256 only: a substitution with no rotation and no round
            // constant. Omitting it yields a plausible schedule and wrong
            // keys from round eight onwards.
            word = word.map { pdfAESSBox[Int($0)] }
        }
        words.append((0..<4).map { words[index - keyWords][$0] ^ word[$0] })
    }
    return stride(from: 0, to: total, by: 4).map { Array(words[$0..<($0 + 4)].joined()) }
}

/// Decrypt one sixteen-byte block.
func pdfAESDecryptBlock(_ roundKeys: [[UInt8]], _ block: [UInt8]) -> [UInt8] {
    guard block.count == 16, roundKeys.count == 11 || roundKeys.count == 15 else { return block }
    let rounds = roundKeys.count - 1
    var state = block
    func addRoundKey(_ round: Int) {
        for index in 0..<16 { state[index] ^= roundKeys[round][index] }
    }

    addRoundKey(rounds)
    for round in stride(from: rounds - 1, through: 0, by: -1) {
        // InvShiftRows: row r rotates right by r, and the state is held in
        // column-major order, so the indices step by four.
        var shifted = state
        for row in 1..<4 {
            for column in 0..<4 {
                shifted[((column + row) % 4) * 4 + row] = state[column * 4 + row]
            }
        }
        // InvSubBytes.
        state = shifted.map { pdfAESInverseSBox[Int($0)] }
        addRoundKey(round)
        // InvMixColumns, skipped on the final round exactly as the forward
        // cipher skips MixColumns on its first.
        if round > 0 {
            var mixed = state
            for column in 0..<4 {
                let base = column * 4
                let a0 = state[base], a1 = state[base + 1]
                let a2 = state[base + 2], a3 = state[base + 3]
                mixed[base] =
                    pdfGaloisMultiply(a0, 14) ^ pdfGaloisMultiply(a1, 11)
                    ^ pdfGaloisMultiply(a2, 13) ^ pdfGaloisMultiply(a3, 9)
                mixed[base + 1] =
                    pdfGaloisMultiply(a0, 9) ^ pdfGaloisMultiply(a1, 14)
                    ^ pdfGaloisMultiply(a2, 11) ^ pdfGaloisMultiply(a3, 13)
                mixed[base + 2] =
                    pdfGaloisMultiply(a0, 13) ^ pdfGaloisMultiply(a1, 9)
                    ^ pdfGaloisMultiply(a2, 14) ^ pdfGaloisMultiply(a3, 11)
                mixed[base + 3] =
                    pdfGaloisMultiply(a0, 11) ^ pdfGaloisMultiply(a1, 13)
                    ^ pdfGaloisMultiply(a2, 9) ^ pdfGaloisMultiply(a3, 14)
            }
            state = mixed
        }
    }
    return state
}

/// Decrypt a PDF string or stream encrypted with AES-128 in CBC mode.
///
/// The initialisation vector is the first sixteen bytes of the data, as PDF
/// specifies. Padding is PKCS#7 and is removed — but only when it is valid:
/// a corrupt final block otherwise truncates real text, and returning a
/// slightly-too-long string is the lesser damage.
func pdfAESDecryptCBC(key: [UInt8], _ data: [UInt8]) -> [UInt8] {
    guard let roundKeys = pdfAESExpandKey(key), data.count >= 32, data.count % 16 == 0 else {
        return []
    }
    var previous = Array(data[0..<16])
    var out: [UInt8] = []
    out.reserveCapacity(data.count - 16)

    for start in stride(from: 16, to: data.count, by: 16) {
        let block = Array(data[start..<(start + 16)])
        let decrypted = pdfAESDecryptBlock(roundKeys, block)
        for index in 0..<16 { out.append(decrypted[index] ^ previous[index]) }
        previous = block
    }

    if let padding = out.last, padding >= 1, padding <= 16, out.count >= Int(padding),
        out.suffix(Int(padding)).allSatisfy({ $0 == padding })
    {
        out.removeLast(Int(padding))
    }
    return out
}

/// Encrypt one sixteen-byte block.
///
/// The forward cipher, needed only by `/R 6`'s key derivation. It is the
/// mirror of the decryption above: substitute, shift, mix, add — with the
/// mix skipped on the final round, exactly as decryption skips it on its
/// first.
func pdfAESEncryptBlock(_ roundKeys: [[UInt8]], _ block: [UInt8]) -> [UInt8] {
    guard block.count == 16, roundKeys.count == 11 || roundKeys.count == 15 else { return block }
    let rounds = roundKeys.count - 1
    var state = block
    func addRoundKey(_ round: Int) {
        for index in 0..<16 { state[index] ^= roundKeys[round][index] }
    }

    addRoundKey(0)
    for round in 1...rounds {
        state = state.map { pdfAESSBox[Int($0)] }
        // ShiftRows: row r rotates *left* by r, the inverse of decryption's.
        var shifted = state
        for row in 1..<4 {
            for column in 0..<4 {
                shifted[column * 4 + row] = state[((column + row) % 4) * 4 + row]
            }
        }
        state = shifted
        if round < rounds {
            var mixed = state
            for column in 0..<4 {
                let base = column * 4
                let a0 = state[base], a1 = state[base + 1]
                let a2 = state[base + 2], a3 = state[base + 3]
                mixed[base] =
                    pdfGaloisMultiply(a0, 2) ^ pdfGaloisMultiply(a1, 3) ^ a2 ^ a3
                mixed[base + 1] =
                    a0 ^ pdfGaloisMultiply(a1, 2) ^ pdfGaloisMultiply(a2, 3) ^ a3
                mixed[base + 2] =
                    a0 ^ a1 ^ pdfGaloisMultiply(a2, 2) ^ pdfGaloisMultiply(a3, 3)
                mixed[base + 3] =
                    pdfGaloisMultiply(a0, 3) ^ a1 ^ a2 ^ pdfGaloisMultiply(a3, 2)
            }
            state = mixed
        }
        addRoundKey(round)
    }
    return state
}

/// Encrypt in CBC mode with **no padding** and an explicit IV.
///
/// Algorithm 2.B uses the cipher as a mixing function over a buffer that is
/// already a multiple of the block size, so neither padding nor a prepended
/// IV belongs here. Both would be right for encrypting a document and are
/// wrong for this.
func pdfAESEncryptCBCNoPadding(key: [UInt8], iv: [UInt8], _ data: [UInt8]) -> [UInt8] {
    guard let roundKeys = pdfAESExpandKey(key), iv.count == 16, data.count % 16 == 0 else {
        return []
    }
    var previous = iv
    var out: [UInt8] = []
    out.reserveCapacity(data.count)
    for start in stride(from: 0, to: data.count, by: 16) {
        var block = Array(data[start..<(start + 16)])
        for index in 0..<16 { block[index] ^= previous[index] }
        let encrypted = pdfAESEncryptBlock(roundKeys, block)
        out.append(contentsOf: encrypted)
        previous = encrypted
    }
    return out
}

/// Decrypt in CBC mode with an explicit IV and no padding removal.
///
/// `/AESV3` stream data still carries its IV in the first sixteen bytes and
/// is handled by `pdfAESDecryptCBC`; this is for the fixed-IV, unpadded uses
/// in the `/R 6` handler.
func pdfAESDecryptCBCNoPadding(key: [UInt8], iv: [UInt8], _ data: [UInt8]) -> [UInt8] {
    guard let roundKeys = pdfAESExpandKey(key), iv.count == 16, data.count % 16 == 0 else {
        return []
    }
    var previous = iv
    var out: [UInt8] = []
    out.reserveCapacity(data.count)
    for start in stride(from: 0, to: data.count, by: 16) {
        let block = Array(data[start..<(start + 16)])
        let decrypted = pdfAESDecryptBlock(roundKeys, block)
        for index in 0..<16 { out.append(decrypted[index] ^ previous[index]) }
        previous = block
    }
    return out
}
