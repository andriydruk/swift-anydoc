/// SHA-256, SHA-384 and SHA-512, for PDF's `/R 6` security handler.
///
/// Like MD5, RC4 and AES before them, these are not something the reference
/// implements — it hands the file to lopdf. They are written out here for the
/// same reason those were: the algorithms are fully specified in FIPS 180-4,
/// they have published test vectors, and this package takes no dependencies.
///
/// **All three are needed, not one.** The `/R 6` key derivation
/// (ISO 32000-2 Algorithm 2.B) picks between them on each of its sixty-odd
/// rounds, by the remainder of an intermediate value modulo three. Porting
/// only SHA-256 would produce a key that is right one time in three.
///
/// SHA-384 is SHA-512 with a different initial state and a truncated output,
/// so it costs nothing beyond the constant.

/// The SHA-256 round constants: the first thirty-two bits of the fractional
/// parts of the cube roots of the first sixty-four primes.
private let pdfSha256K: [UInt32] = [
    0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1,
    0x923f_82a4, 0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
    0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174, 0xe49b_69c1, 0xefbe_4786,
    0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
    0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147,
    0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
    0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85, 0xa2bf_e8a1, 0xa81a_664b,
    0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
    0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a,
    0x5b9c_ca4f, 0x682e_6ff3, 0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
    0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
]

/// Pad a message to a whole number of blocks, FIPS 180-4 §5.1.
///
/// A `0x80` byte, then zeros, then the bit length. The length field is eight
/// bytes for SHA-256 and sixteen for SHA-512 — the wider one is why this
/// takes the size rather than assuming.
private func pdfSha2Pad(_ message: [UInt8], blockSize: Int, lengthBytes: Int) -> [UInt8] {
    var padded = message
    padded.append(0x80)
    while (padded.count + lengthBytes) % blockSize != 0 { padded.append(0) }

    let bits = UInt64(message.count) &* 8
    // The high half of a 128-bit length is always zero here: a message long
    // enough to fill it cannot be held in memory.
    for _ in 0..<(lengthBytes - 8) { padded.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) {
        padded.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
    }
    return padded
}

/// SHA-256.
func pdfSha256(_ message: [UInt8]) -> [UInt8] {
    var state: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
        0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]
    let padded = pdfSha2Pad(message, blockSize: 64, lengthBytes: 8)

    var schedule = [UInt32](repeating: 0, count: 64)
    for start in stride(from: 0, to: padded.count, by: 64) {
        for index in 0..<16 {
            let offset = start + index * 4
            schedule[index] =
                UInt32(padded[offset]) << 24 | UInt32(padded[offset + 1]) << 16
                | UInt32(padded[offset + 2]) << 8 | UInt32(padded[offset + 3])
        }
        for index in 16..<64 {
            let a = schedule[index - 15]
            let b = schedule[index - 2]
            let s0 = pdfRotateRight(a, 7) ^ pdfRotateRight(a, 18) ^ (a >> 3)
            let s1 = pdfRotateRight(b, 17) ^ pdfRotateRight(b, 19) ^ (b >> 10)
            schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
        }

        var (a, b, c, d) = (state[0], state[1], state[2], state[3])
        var (e, f, g, h) = (state[4], state[5], state[6], state[7])
        for index in 0..<64 {
            let s1 = pdfRotateRight(e, 6) ^ pdfRotateRight(e, 11) ^ pdfRotateRight(e, 25)
            let choice = (e & f) ^ (~e & g)
            let temporary1 = h &+ s1 &+ choice &+ pdfSha256K[index] &+ schedule[index]
            let s0 = pdfRotateRight(a, 2) ^ pdfRotateRight(a, 13) ^ pdfRotateRight(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = s0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temporary1
            d = c
            c = b
            b = a
            a = temporary1 &+ temporary2
        }
        for (index, value) in [a, b, c, d, e, f, g, h].enumerated() { state[index] &+= value }
    }

    var digest: [UInt8] = []
    for word in state {
        for shift in stride(from: 24, through: 0, by: -8) {
            digest.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
        }
    }
    return digest
}

private func pdfRotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
    (value >> count) | (value << (32 - count))
}

private func pdfRotateRight64(_ value: UInt64, _ count: UInt64) -> UInt64 {
    (value >> count) | (value << (64 - count))
}

/// The SHA-512 round constants: the first sixty-four bits of the fractional
/// parts of the cube roots of the first eighty primes.
private let pdfSha512K: [UInt64] = [
    0x428a_2f98_d728_ae22, 0x7137_4491_23ef_65cd, 0xb5c0_fbcf_ec4d_3b2f,
    0xe9b5_dba5_8189_dbbc, 0x3956_c25b_f348_b538, 0x59f1_11f1_b605_d019,
    0x923f_82a4_af19_4f9b, 0xab1c_5ed5_da6d_8118, 0xd807_aa98_a303_0242,
    0x1283_5b01_4570_6fbe, 0x2431_85be_4ee4_b28c, 0x550c_7dc3_d5ff_b4e2,
    0x72be_5d74_f27b_896f, 0x80de_b1fe_3b16_96b1, 0x9bdc_06a7_25c7_1235,
    0xc19b_f174_cf69_2694, 0xe49b_69c1_9ef1_4ad2, 0xefbe_4786_384f_25e3,
    0x0fc1_9dc6_8b8c_d5b5, 0x240c_a1cc_77ac_9c65, 0x2de9_2c6f_592b_0275,
    0x4a74_84aa_6ea6_e483, 0x5cb0_a9dc_bd41_fbd4, 0x76f9_88da_8311_53b5,
    0x983e_5152_ee66_dfab, 0xa831_c66d_2db4_3210, 0xb003_27c8_98fb_213f,
    0xbf59_7fc7_beef_0ee4, 0xc6e0_0bf3_3da8_8fc2, 0xd5a7_9147_930a_a725,
    0x06ca_6351_e003_826f, 0x1429_2967_0a0e_6e70, 0x27b7_0a85_46d2_2ffc,
    0x2e1b_2138_5c26_c926, 0x4d2c_6dfc_5ac4_2aed, 0x5338_0d13_9d95_b3df,
    0x650a_7354_8baf_63de, 0x766a_0abb_3c77_b2a8, 0x81c2_c92e_47ed_aee6,
    0x9272_2c85_1482_353b, 0xa2bf_e8a1_4cf1_0364, 0xa81a_664b_bc42_3001,
    0xc24b_8b70_d0f8_9791, 0xc76c_51a3_0654_be30, 0xd192_e819_d6ef_5218,
    0xd699_0624_5565_a910, 0xf40e_3585_5771_202a, 0x106a_a070_32bb_d1b8,
    0x19a4_c116_b8d2_d0c8, 0x1e37_6c08_5141_ab53, 0x2748_774c_df8e_eb99,
    0x34b0_bcb5_e19b_48a8, 0x391c_0cb3_c5c9_5a63, 0x4ed8_aa4a_e341_8acb,
    0x5b9c_ca4f_7763_e373, 0x682e_6ff3_d6b2_b8a3, 0x748f_82ee_5def_b2fc,
    0x78a5_636f_4317_2f60, 0x84c8_7814_a1f0_ab72, 0x8cc7_0208_1a64_39ec,
    0x90be_fffa_2363_1e28, 0xa450_6ceb_de82_bde9, 0xbef9_a3f7_b2c6_7915,
    0xc671_78f2_e372_532b, 0xca27_3ece_ea26_619c, 0xd186_b8c7_21c0_c207,
    0xeada_7dd6_cde0_eb1e, 0xf57d_4f7f_ee6e_d178, 0x06f0_67aa_7217_6fba,
    0x0a63_7dc5_a2c8_98a6, 0x113f_9804_bef9_0dae, 0x1b71_0b35_131c_471b,
    0x28db_77f5_2304_7d84, 0x32ca_ab7b_40c7_2493, 0x3c9e_be0a_15c9_bebc,
    0x431d_67c4_9c10_0d4c, 0x4cc5_d4be_cb3e_42b6, 0x597f_299c_fc65_7e2a,
    0x5fcb_6fab_3ad6_faec, 0x6c44_198c_4a47_5817,
]

/// SHA-512, and SHA-384 through the same core.
///
/// The two differ only in the initial state and how much of the result is
/// kept, which is why one function serves both.
private func pdfSha512Core(_ message: [UInt8], state initial: [UInt64], outputBytes: Int)
    -> [UInt8]
{
    var state = initial
    let padded = pdfSha2Pad(message, blockSize: 128, lengthBytes: 16)

    var schedule = [UInt64](repeating: 0, count: 80)
    for start in stride(from: 0, to: padded.count, by: 128) {
        for index in 0..<16 {
            var word: UInt64 = 0
            for byte in 0..<8 { word = word << 8 | UInt64(padded[start + index * 8 + byte]) }
            schedule[index] = word
        }
        for index in 16..<80 {
            let a = schedule[index - 15]
            let b = schedule[index - 2]
            let s0 = pdfRotateRight64(a, 1) ^ pdfRotateRight64(a, 8) ^ (a >> 7)
            let s1 = pdfRotateRight64(b, 19) ^ pdfRotateRight64(b, 61) ^ (b >> 6)
            schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
        }

        var (a, b, c, d) = (state[0], state[1], state[2], state[3])
        var (e, f, g, h) = (state[4], state[5], state[6], state[7])
        for index in 0..<80 {
            let s1 =
                pdfRotateRight64(e, 14) ^ pdfRotateRight64(e, 18) ^ pdfRotateRight64(e, 41)
            let choice = (e & f) ^ (~e & g)
            let temporary1 = h &+ s1 &+ choice &+ pdfSha512K[index] &+ schedule[index]
            let s0 =
                pdfRotateRight64(a, 28) ^ pdfRotateRight64(a, 34) ^ pdfRotateRight64(a, 39)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = s0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temporary1
            d = c
            c = b
            b = a
            a = temporary1 &+ temporary2
        }
        for (index, value) in [a, b, c, d, e, f, g, h].enumerated() { state[index] &+= value }
    }

    var digest: [UInt8] = []
    for word in state {
        for shift in stride(from: 56, through: 0, by: -8) {
            digest.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
        }
    }
    return Array(digest.prefix(outputBytes))
}

/// SHA-512.
func pdfSha512(_ message: [UInt8]) -> [UInt8] {
    pdfSha512Core(
        message,
        state: [
            0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b,
            0xa54f_f53a_5f1d_36f1, 0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f,
            0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179,
        ],
        outputBytes: 64)
}

/// SHA-384: SHA-512's core, seeded from the fractional parts of the square
/// roots of the *ninth* through sixteenth primes, and truncated.
func pdfSha384(_ message: [UInt8]) -> [UInt8] {
    pdfSha512Core(
        message,
        state: [
            0xcbbb_9d5d_c105_9ed8, 0x629a_292a_367c_d507, 0x9159_015a_3070_dd17,
            0x152f_ecd8_f70e_5939, 0x6733_2667_ffc0_0b31, 0x8eb4_4a87_6858_1511,
            0xdb0c_2e0d_64f9_8fa7, 0x47b5_481d_befa_4fa4,
        ],
        outputBytes: 48)
}
