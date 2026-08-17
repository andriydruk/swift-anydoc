import Testing

@testable import AnyDoc

/// The revision 5 and 6 security handler.
///
/// `encrypted-aes-256.pdf` covers this end to end — removing the support
/// costs that file its byte-identical status. These pin the pieces a single
/// document cannot separate, above all the two things most easily got wrong
/// in Algorithm 2.B.
@Suite struct PdfAes256HandlerTests {
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Revision 5 is a single SHA-256 of password, salt and user data. It is
    /// also the base case of revision 6, so getting it wrong breaks both.
    @Test func revisionFiveIsOneHash() {
        let salt: [UInt8] = Array(0..<8)
        let computed = pdfHardenedHash(password: [], salt: salt, revision: 5)
        #expect(computed == pdfSha256(salt))
        #expect(computed.count == 32)
    }

    /// Revision 6 must *not* stop at the first hash. This is the check that
    /// catches a port that took the revision-5 early return unconditionally
    /// — the output would still be 32 plausible bytes.
    @Test func revisionSixIsNotRevisionFive() {
        let salt: [UInt8] = Array(0..<8)
        let five = pdfHardenedHash(password: [], salt: salt, revision: 5)
        let six = pdfHardenedHash(password: [], salt: salt, revision: 6)
        #expect(six.count == 32)
        #expect(six != five)
    }

    /// The hash depends on the password, the salt and the user data
    /// separately, and is deterministic. A port that concatenated them in
    /// the wrong order, or dropped the user data, would still return 32
    /// plausible bytes for every input.
    ///
    /// Checked in **one** test on purpose. Algorithm 2.B is expensive by
    /// design — sixty-plus rounds over a buffer sixty-four times the key —
    /// and each call here costs about two seconds, so splitting this into
    /// four tests would spend eight seconds of every CI run to say the same
    /// thing.
    @Test func everyInputChangesTheResultDeterministically() {
        let salt: [UInt8] = Array(0..<8)
        let base = pdfHardenedHash(password: [], salt: salt, revision: 6)
        #expect(base == pdfHardenedHash(password: [], salt: salt, revision: 6))
        #expect(base != pdfHardenedHash(password: Array("x".utf8), salt: salt, revision: 6))
        #expect(base != pdfHardenedHash(password: [], salt: Array(1..<9), revision: 6))
        #expect(
            base
                != pdfHardenedHash(
                    password: [], salt: salt, userKey: Array(repeating: 9, count: 48),
                    revision: 6))
    }

    /// A malformed `/U` is refused rather than read past its end: a 48-byte
    /// field is assumed everywhere in Algorithm 2.A.
    @Test func aShortUserKeyIsRefused() {
        var encryption = PdfEncryption(
            revision: 6, keyLength: 32, ownerKey: [], userKey: Array(repeating: 0, count: 40),
            permissions: -4, documentID: [], encryptMetadata: true)
        encryption.usesAES256 = true
        #expect(!pdfAes256UserPasswordWorks(encryption))
        #expect(pdfAes256FileKey(encryption).isEmpty)
    }

    /// `/V 5` uses the file key directly, with no per-object mixing. The
    /// earlier revisions require the opposite, and using their rule here
    /// yields noise that still inflates — the failure worth naming.
    @Test func aes256UsesTheFileKeyDirectly() {
        var encryption = PdfEncryption(
            revision: 6, keyLength: 32, ownerKey: [], userKey: Array(repeating: 0, count: 48),
            permissions: -4, documentID: [], encryptMetadata: true)
        encryption.usesAES256 = true
        encryption.key = Array(repeating: 7, count: 32)

        // Round-trip a block through the same key the handler would use.
        let plain = Array("secret text in a stream".utf8)
        let iv = [UInt8](repeating: 3, count: 16)
        var padded = plain
        let pad = 16 - plain.count % 16
        padded.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
        let cipher = iv + pdfAESEncryptCBCNoPadding(key: encryption.key, iv: iv, padded)

        #expect(pdfDecrypt(encryption, PdfObjectId(number: 12, generation: 0), cipher) == plain)
        // The object id must make no difference at all.
        #expect(
            pdfDecrypt(encryption, PdfObjectId(number: 99, generation: 3), cipher) == plain)
    }
}
