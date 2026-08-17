/// MD5 and RC4, hand-rolled for PDF's standard security handler.
///
/// The reference does not implement these: it hands an encrypted document to
/// lopdf and lets that crate decrypt. This port has no such dependency, so
/// the algorithms are written out here — both are small, both are fully
/// specified, and both have published test vectors, which is what makes
/// hand-rolling them defensible.
///
/// Neither is used for anything but reading a document the user already has.
/// MD5 and RC4 are broken as security primitives and must never be used to
/// protect anything; they appear here because PDF's 1990s encryption
/// specifies them and files in the wild are still encrypted with them.

/// MD5 (RFC 1321).
///
/// Sixteen bytes, little-endian, exactly as the specification defines them —
/// PDF's key derivation feeds the digest straight back into itself, so any
/// deviation is invisible until a document fails to decrypt.
func pdfMD5(_ message: [UInt8]) -> [UInt8] {
    // Per-round shift amounts.
    let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]
    // `floor(abs(sin(i + 1)) * 2^32)`, tabulated rather than computed so the
    // result cannot depend on the platform's sine.
    let sines: [UInt32] = [
        0xd76a_a478, 0xe8c7_b756, 0x2420_70db, 0xc1bd_ceee,
        0xf57c_0faf, 0x4787_c62a, 0xa830_4613, 0xfd46_9501,
        0x6980_98d8, 0x8b44_f7af, 0xffff_5bb1, 0x895c_d7be,
        0x6b90_1122, 0xfd98_7193, 0xa679_438e, 0x49b4_0821,
        0xf61e_2562, 0xc040_b340, 0x265e_5a51, 0xe9b6_c7aa,
        0xd62f_105d, 0x0244_1453, 0xd8a1_e681, 0xe7d3_fbc8,
        0x21e1_cde6, 0xc337_07d6, 0xf4d5_0d87, 0x455a_14ed,
        0xa9e3_e905, 0xfcef_a3f8, 0x676f_02d9, 0x8d2a_4c8a,
        0xfffa_3942, 0x8771_f681, 0x6d9d_6122, 0xfde5_380c,
        0xa4be_ea44, 0x4bde_cfa9, 0xf6bb_4b60, 0xbebf_bc70,
        0x289b_7ec6, 0xeaa1_27fa, 0xd4ef_3085, 0x0488_1d05,
        0xd9d4_d039, 0xe6db_99e5, 0x1fa2_7cf8, 0xc4ac_5665,
        0xf429_2244, 0x432a_ff97, 0xab94_23a7, 0xfc93_a039,
        0x655b_59c3, 0x8f0c_cc92, 0xffef_f47d, 0x8584_5dd1,
        0x6fa8_7e4f, 0xfe2c_e6e0, 0xa301_4314, 0x4e08_11a1,
        0xf753_7e82, 0xbd3a_f235, 0x2ad7_d2bb, 0xeb86_d391,
    ]

    var a0: UInt32 = 0x6745_2301
    var b0: UInt32 = 0xefcd_ab89
    var c0: UInt32 = 0x98ba_dcfe
    var d0: UInt32 = 0x1032_5476

    // Padded to a multiple of 64 with a 1 bit, zeros, then the *bit* length
    // as a little-endian 64-bit integer.
    var padded = message
    padded.append(0x80)
    while padded.count % 64 != 56 { padded.append(0) }
    let bitLength = UInt64(message.count) &* 8
    for shift in stride(from: 0, to: 64, by: 8) {
        padded.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
    }

    for chunkStart in stride(from: 0, to: padded.count, by: 64) {
        var words = [UInt32](repeating: 0, count: 16)
        for index in 0..<16 {
            let base = chunkStart + index * 4
            words[index] =
                UInt32(padded[base]) | UInt32(padded[base + 1]) << 8
                | UInt32(padded[base + 2]) << 16 | UInt32(padded[base + 3]) << 24
        }

        var a = a0
        var b = b0
        var c = c0
        var d = d0
        for index in 0..<64 {
            var f: UInt32
            var g: Int
            switch index {
            case 0..<16:
                f = (b & c) | (~b & d)
                g = index
            case 16..<32:
                f = (d & b) | (~d & c)
                g = (5 * index + 1) % 16
            case 32..<48:
                f = b ^ c ^ d
                g = (3 * index + 5) % 16
            default:
                f = c ^ (b | ~d)
                g = (7 * index) % 16
            }
            f = f &+ a &+ sines[index] &+ words[g]
            a = d
            d = c
            c = b
            let shift = shifts[index]
            b = b &+ ((f << shift) | (f >> (32 - shift)))
        }
        a0 = a0 &+ a
        b0 = b0 &+ b
        c0 = c0 &+ c
        d0 = d0 &+ d
    }

    var digest: [UInt8] = []
    for word in [a0, b0, c0, d0] {
        for shift in stride(from: 0, to: 32, by: 8) {
            digest.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
        }
    }
    return digest
}

/// RC4, which is its own inverse — encrypting ciphertext returns the plain
/// text, so one function serves both directions.
func pdfRC4(key: [UInt8], _ data: [UInt8]) -> [UInt8] {
    guard !key.isEmpty else { return data }
    var state = [UInt8](0...255)
    var j = 0
    for i in 0..<256 {
        j = (j + Int(state[i]) + Int(key[i % key.count])) & 0xFF
        state.swapAt(i, j)
    }

    var out: [UInt8] = []
    out.reserveCapacity(data.count)
    var x = 0
    var y = 0
    for byte in data {
        x = (x + 1) & 0xFF
        y = (y + Int(state[x])) & 0xFF
        state.swapAt(x, y)
        let k = state[(Int(state[x]) + Int(state[y])) & 0xFF]
        out.append(byte ^ k)
    }
    return out
}
