/// PDF's standard security handler (ISO 32000-1 §7.6.3), for the RC4
/// revisions.
///
/// Most "protected" PDFs in the wild are encrypted with an **empty user
/// password**: the producer wanted to set permissions, not to keep anyone
/// out, and every reader opens them without asking. A reader that cannot
/// decrypt them fails on a large share of real documents — and fails
/// *silently*, since the file parses and its streams simply decode to noise.
///
/// The reference does not implement any of this; it hands the file to lopdf.
/// This port has no such dependency, so the handler is written out here.
///
/// **RC4 (revisions 2 and 3), AES-128 (`/V 4` with `/AESV2`) and AES-256
/// (`/V 5` with `/AESV3`, revisions 5 and 6).** The last of those lives in
/// `PdfDecryptionAes256.swift`, because it shares almost nothing with these:
/// it keys from SHA-2 rather than MD5, unwraps the file key from `/UE`
/// instead of deriving it, and uses no per-object key at all.

/// The padding every password is extended with, from the specification's
/// Algorithm 2. It is a fixed 32-byte string and not a secret.
private let pdfPasswordPadding: [UInt8] = [
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56,
    0xFF, 0xFA, 0x01, 0x08, 0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80,
    0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
]

/// What a document's `/Encrypt` dictionary asks for.
struct PdfEncryption {
    /// Revision of the standard handler: 2 and 3 are RC4.
    var revision: Int
    /// Key length in bytes. Revision 2 is always 5; revision 3 reads `/Length`.
    var keyLength: Int
    var ownerKey: [UInt8]
    var userKey: [UInt8]
    var permissions: Int32
    var documentID: [UInt8]
    /// Whether `/EncryptMetadata` is false, which changes the key derivation.
    var encryptMetadata: Bool
    /// True when the crypt filter is `/AESV2` rather than RC4.
    var usesAES = false
    /// True when the crypt filter is `/AESV3` — AES-256, revisions 5 and 6.
    var usesAES256 = false
    /// `/UE`: the file key, wrapped under a key derived from the password.
    var userEncryptedKey: [UInt8] = []
    /// The file key, once derived.
    var key: [UInt8] = []

    /// Whether this port can decrypt the document at all.
    ///
    /// A revision it does not implement is refused rather than attempted:
    /// decrypting with the wrong algorithm yields plausible-looking bytes
    /// and a document full of noise.
    var isSupported: Bool {
        revision == 2 || revision == 3 || (revision == 4 && usesAES)
            || ((revision == 5 || revision == 6) && usesAES256)
    }
}

/// Read an `/Encrypt` dictionary, if the document has one.
func pdfReadEncryption(
    _ document: inout PdfDocument, _ encrypt: PdfDictionary, documentID: [UInt8]
) -> PdfEncryption? {
    // Only the standard handler. A document using a custom one names it here
    // and cannot be opened without the filter that wrote it.
    let filter = document.value(encrypt, "Filter")?.asName
        .map { String(decoding: $0, as: UTF8.self) }
    guard filter == nil || filter == "Standard" else { return nil }

    let revision = Int(document.value(encrypt, "R")?.asInteger ?? 0)
    // Revision 2 fixes the key at 40 bits whatever `/Length` claims.
    let bits = Int(document.value(encrypt, "Length")?.asInteger ?? 40)
    var keyLength = revision == 2 ? 5 : max(5, min(16, bits / 8))

    // `/V 4` names its algorithm in a crypt filter rather than inline. The
    // one that matters is `/StmF`'s: `/AESV2` is AES-128, and its `/Length`
    // is in *bytes* here where the outer one is in bits, which is a trap
    // worth naming.
    var usesAES = false
    var usesAES256 = false
    if let filters = document.value(encrypt, "CF")?.asDictionary {
        let streamFilter = document.value(encrypt, "StmF")?.asName
            .map { String(decoding: $0, as: UTF8.self) } ?? "Identity"
        if let chosen = document.value(filters, streamFilter)?.asDictionary {
            let method = document.value(chosen, "CFM")?.asName
                .map { String(decoding: $0, as: UTF8.self) }
            if method == "AESV2" {
                usesAES = true
                keyLength = 16
            } else if method == "AESV3" {
                usesAES256 = true
                keyLength = 32
            }
        }
    }

    guard let owner = document.value(encrypt, "O")?.asStringBytes,
        let user = document.value(encrypt, "U")?.asStringBytes
    else { return nil }
    // `/P` is a signed 32-bit integer whose high bits are usually set, so it
    // arrives as a large negative number and must stay one.
    let permissions = Int32(truncatingIfNeeded: document.value(encrypt, "P")?.asInteger ?? 0)
    var encryptMetadata = true
    if case .boolean(let flag)? = document.value(encrypt, "EncryptMetadata") {
        encryptMetadata = flag
    }

    return PdfEncryption(
        revision: revision, keyLength: keyLength, ownerKey: owner, userKey: user,
        permissions: permissions, documentID: documentID, encryptMetadata: encryptMetadata,
        usesAES: usesAES, usesAES256: usesAES256,
        userEncryptedKey: document.value(encrypt, "UE")?.asStringBytes ?? [])
}

/// Derive the file key from a password — the specification's Algorithm 2.
func pdfDeriveFileKey(_ encryption: PdfEncryption, password: [UInt8] = []) -> [UInt8] {
    // Revisions 5 and 6 do not derive the key from the password at all: the
    // password unwraps `/UE`, which *holds* the key.
    if encryption.revision >= 5 { return pdfAes256FileKey(encryption, password: password) }

    // The password, padded to exactly 32 bytes: truncated if longer, topped
    // up from the fixed padding string if shorter.
    var input = Array(password.prefix(32))
    input.append(contentsOf: pdfPasswordPadding.prefix(32 - input.count))

    input.append(contentsOf: encryption.ownerKey)
    // Little-endian, and *signed* — the permissions word is normally
    // negative, and treating it as unsigned changes every byte of the key.
    let permissions = UInt32(bitPattern: encryption.permissions)
    for shift in stride(from: 0, to: 32, by: 8) {
        input.append(UInt8(truncatingIfNeeded: permissions >> UInt32(shift)))
    }
    input.append(contentsOf: encryption.documentID)

    // Revision 3 and up append four `0xFF` bytes when metadata is left in
    // the clear.
    if encryption.revision >= 3 && !encryption.encryptMetadata {
        input.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
    }

    var digest = pdfMD5(input)
    // Revision 3 and up re-hash the first `keyLength` bytes fifty times,
    // which is the whole of the specification's key-strengthening.
    if encryption.revision >= 3 {
        for _ in 0..<50 { digest = pdfMD5(Array(digest.prefix(encryption.keyLength))) }
    }
    return Array(digest.prefix(encryption.keyLength))
}

/// The key for one object, which mixes the file key with the object's own
/// number and generation — so the same bytes in two objects encrypt
/// differently.
func pdfObjectKey(_ encryption: PdfEncryption, _ id: PdfObjectId) -> [UInt8] {
    var input = encryption.key
    let number = UInt32(truncatingIfNeeded: id.number)
    let generation = UInt32(truncatingIfNeeded: id.generation)
    // Three low bytes of the object number, then two of the generation.
    input.append(UInt8(truncatingIfNeeded: number))
    input.append(UInt8(truncatingIfNeeded: number >> 8))
    input.append(UInt8(truncatingIfNeeded: number >> 16))
    input.append(UInt8(truncatingIfNeeded: generation))
    input.append(UInt8(truncatingIfNeeded: generation >> 8))
    // AES adds a fixed four-byte salt before hashing — `sAlT` spelled in
    // ASCII, which is the specification's own joke and its own constant.
    if encryption.usesAES { input.append(contentsOf: [0x73, 0x41, 0x6C, 0x54]) }
    // Capped at sixteen: a longer key gains nothing and the specification
    // says so explicitly.
    return Array(pdfMD5(input).prefix(min(encryption.key.count + 5, 16)))
}

/// Whether the empty user password opens this document — Algorithm 6.
///
/// Revision 2 compares the whole `/U` string; revision 3 compares only the
/// first sixteen bytes, because the rest is arbitrary padding the producer
/// was free to choose.
func pdfEmptyUserPasswordWorks(_ encryption: PdfEncryption) -> Bool {
    // Revisions 5 and 6 validate against `/U`'s own salts rather than by
    // re-running the RC4 dance below.
    if encryption.revision >= 5 { return pdfAes256UserPasswordWorks(encryption) }

    var candidate = encryption
    candidate.key = pdfDeriveFileKey(encryption)

    if encryption.revision == 2 {
        return pdfRC4(key: candidate.key, pdfPasswordPadding) == encryption.userKey
    }
    // Revision 4 validates exactly as revision 3 does: the crypt filter
    // changes how *data* is encrypted, not how the password is checked.

    // Revision 3: MD5 of the padding and the document id, encrypted with the
    // file key, then nineteen more times with the key's bytes each XORed
    // against the round number.
    var input = pdfPasswordPadding
    input.append(contentsOf: encryption.documentID)
    var value = pdfRC4(key: candidate.key, pdfMD5(input))
    for round in 1...19 {
        let roundKey = candidate.key.map { $0 ^ UInt8(round) }
        value = pdfRC4(key: roundKey, value)
    }
    return Array(encryption.userKey.prefix(16)) == Array(value.prefix(16))
}

/// Decrypt one object's bytes.
func pdfDecrypt(_ encryption: PdfEncryption, _ id: PdfObjectId, _ data: [UInt8]) -> [UInt8] {
    guard encryption.isSupported, !encryption.key.isEmpty else { return data }
    // `/V 5` uses the file key directly. Mixing in the object number, as the
    // earlier revisions require, would produce noise here — and noise that
    // still inflates, which is the failure worth avoiding.
    if encryption.usesAES256 { return pdfAESDecryptCBC(key: encryption.key, data) }
    let key = pdfObjectKey(encryption, id)
    return encryption.usesAES ? pdfAESDecryptCBC(key: key, data) : pdfRC4(key: key, data)
}
