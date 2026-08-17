/// PDF's standard security handler at revisions 5 and 6 — AES-256.
///
/// This is what Acrobat X and everything after it writes by default, so it
/// is not an exotic case: a port without it refuses a large and growing
/// share of protected documents. `PdfDecryption.swift` handles the RC4 and
/// AES-128 revisions and refused these, which was the right behaviour while
/// they were unimplemented and is now unnecessary.
///
/// **The two revisions differ by one loop.** Revision 5 (an Adobe extension,
/// deprecated before it was standardised) hashes the password and salt once
/// with SHA-256. Revision 6 (ISO 32000-2 Algorithm 2.B) feeds that hash
/// through at least sixty-four rounds of AES-mixing and re-hashing, choosing
/// between SHA-256, SHA-384 and SHA-512 each round. The hardening exists to
/// make brute force expensive; reproducing it is the whole cost of the
/// revision.
///
/// **No per-object key.** Unlike RC4 and AES-128, `/V 5` encrypts every
/// string and stream with the file key itself. Deriving an object key here
/// would produce noise that decompresses to nothing.

/// The hardened hash, ISO 32000-2 Algorithm 2.B.
///
/// - Parameters:
///   - password: the password bytes, already truncated to 127 by the caller.
///   - salt: eight bytes from `/U` or `/O` — the validation salt when
///     checking a password, the key salt when deriving one.
///   - userKey: the first 48 bytes of `/U`, and only when checking an
///     *owner* password. Empty for the user password.
///   - revision: 5 stops after the first hash; 6 runs the rounds.
func pdfHardenedHash(
    password: [UInt8], salt: [UInt8], userKey: [UInt8] = [], revision: Int
) -> [UInt8] {
    var k = pdfSha256(password + salt + userKey)
    if revision == 5 { return k }

    var round = 1
    while true {
        // Sixty-four repetitions of the password, the running key and the
        // user key. The repetition is what makes each round expensive.
        var k1: [UInt8] = []
        k1.reserveCapacity(64 * (password.count + k.count + userKey.count))
        for _ in 0..<64 {
            k1.append(contentsOf: password)
            k1.append(contentsOf: k)
            k1.append(contentsOf: userKey)
        }

        // The cipher is a mixing function here, keyed and seeded from the
        // running hash itself. Unpadded, because `k1` is already a whole
        // number of blocks: 64 × (a multiple of 16) always is.
        let e = pdfAESEncryptCBCNoPadding(
            key: Array(k[0..<16]), iv: Array(k[16..<32]), k1)
        guard !e.isEmpty else { return [] }

        // Which hash comes next is decided by the data, so an implementation
        // that always used SHA-256 would be right one round in three and
        // wrong overall.
        let remainder = e[0..<16].reduce(UInt32(0)) { $0 + UInt32($1) } % 3
        switch remainder {
        case 0: k = pdfSha256(e)
        case 1: k = pdfSha384(e)
        default: k = pdfSha512(e)
        }

        // At least sixty-four rounds, then a data-dependent stop. The last
        // byte of `e` decides, so the round count varies per password.
        if round >= 64 && UInt32(e[e.count - 1]) <= UInt32(round) - 32 { break }
        round += 1
    }
    return Array(k.prefix(32))
}

/// Whether the empty user password opens a revision 5 or 6 document.
///
/// `/U` is 48 bytes: a 32-byte hash, an 8-byte validation salt, and an
/// 8-byte key salt. The check re-derives the hash from the password and the
/// validation salt and compares.
func pdfAes256UserPasswordWorks(_ encryption: PdfEncryption, password: [UInt8] = []) -> Bool {
    guard encryption.userKey.count >= 48 else { return false }
    let expected = Array(encryption.userKey[0..<32])
    let validationSalt = Array(encryption.userKey[32..<40])
    let computed = pdfHardenedHash(
        password: password, salt: validationSalt, revision: encryption.revision)
    return computed.count >= 32 && Array(computed.prefix(32)) == expected
}

/// The file key for a revision 5 or 6 document — Algorithm 2.A.
///
/// The intermediate key comes from the password and the *key* salt; it then
/// unwraps `/UE`, which holds the real file key. The unwrapping uses a zero
/// IV and no padding, which is the one place in PDF where an all-zero IV is
/// correct rather than a bug.
func pdfAes256FileKey(_ encryption: PdfEncryption, password: [UInt8] = []) -> [UInt8] {
    guard encryption.userKey.count >= 48, encryption.userEncryptedKey.count == 32 else {
        return []
    }
    let keySalt = Array(encryption.userKey[40..<48])
    let intermediate = pdfHardenedHash(
        password: password, salt: keySalt, revision: encryption.revision)
    guard intermediate.count >= 32 else { return [] }
    return pdfAESDecryptCBCNoPadding(
        key: Array(intermediate.prefix(32)), iv: [UInt8](repeating: 0, count: 16),
        encryption.userEncryptedKey)
}
