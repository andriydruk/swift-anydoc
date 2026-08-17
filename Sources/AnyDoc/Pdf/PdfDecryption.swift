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
/// **Revisions 2 and 3 with RC4 only.** `/V 4` with `/AESV2`, and `/R 6`
/// with AES-256, are not implemented — a document using them is reported as
/// encrypted rather than decoded to noise, which is the one behaviour worse
/// than failing.

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
    /// The file key, once derived.
    var key: [UInt8] = []

    /// Whether this port can decrypt the document at all.
    ///
    /// A revision it does not implement is refused rather than attempted:
    /// decrypting with the wrong algorithm yields plausible-looking bytes
    /// and a document full of noise.
    var isSupported: Bool { revision == 2 || revision == 3 }
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
    let keyLength = revision == 2 ? 5 : max(5, min(16, bits / 8))

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
        permissions: permissions, documentID: documentID, encryptMetadata: encryptMetadata)
}

/// Derive the file key from a password — the specification's Algorithm 2.
func pdfDeriveFileKey(_ encryption: PdfEncryption, password: [UInt8] = []) -> [UInt8] {
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
    var candidate = encryption
    candidate.key = pdfDeriveFileKey(encryption)

    if encryption.revision == 2 {
        return pdfRC4(key: candidate.key, pdfPasswordPadding) == encryption.userKey
    }

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
    return pdfRC4(key: pdfObjectKey(encryption, id), data)
}
