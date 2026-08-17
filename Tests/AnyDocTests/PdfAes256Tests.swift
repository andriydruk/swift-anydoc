import Testing

@testable import AnyDoc

/// AES-256 and the forward cipher, against FIPS 197 and NIST SP 800-38A.
///
/// Like the SHA-2 tests, these are complete rather than representative: the
/// vectors are published, fixed, and independent of anything this port does.
///
/// The AES-256 key schedule is the part worth testing hardest. It is not
/// AES-128's with more rounds — it takes an extra `SubWord` at every fourth
/// word inside each eight-word group, and a schedule missing that produces
/// plausible round keys that are wrong from round eight onwards. The
/// round-trip tests below would still pass with that bug; only the published
/// ciphertext catches it.
@Suite struct PdfAes256Tests {
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16) ?? 0
        }
    }

    /// FIPS 197 Appendix C.1: AES-128, one block.
    @Test func aes128MatchesTheFipsVector() {
        let key = bytes("000102030405060708090a0b0c0d0e0f")
        let plain = bytes("00112233445566778899aabbccddeeff")
        let keys = try! #require(pdfAESExpandKey(key))
        #expect(hex(pdfAESEncryptBlock(keys, plain)) == "69c4e0d86a7b0430d8cdb78070b4c55a")
        #expect(hex(pdfAESDecryptBlock(keys, bytes("69c4e0d86a7b0430d8cdb78070b4c55a")))
            == hex(plain))
    }

    /// FIPS 197 Appendix C.3: AES-256, the vector that catches a key
    /// schedule written for 128-bit keys and stretched.
    @Test func aes256MatchesTheFipsVector() {
        let key = bytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let plain = bytes("00112233445566778899aabbccddeeff")
        let keys = try! #require(pdfAESExpandKey(key))
        #expect(keys.count == 15)
        #expect(hex(pdfAESEncryptBlock(keys, plain)) == "8ea2b7ca516745bfeafc49904b496089")
        #expect(hex(pdfAESDecryptBlock(keys, bytes("8ea2b7ca516745bfeafc49904b496089")))
            == hex(plain))
    }

    /// NIST SP 800-38A F.2.5/F.2.6: AES-256-CBC over four blocks. A
    /// single-block test cannot catch a chaining error.
    @Test func aes256CbcMatchesTheNistVector() {
        let key = bytes("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let iv = bytes("000102030405060708090a0b0c0d0e0f")
        let plain = bytes(
            "6bc1bee22e409f96e93d7e117393172a"
                + "ae2d8a571e03ac9c9eb76fac45af8e51"
                + "30c81c46a35ce411e5fbc1191a0a52ef"
                + "f69f2445df4f9b17ad2b417be66c3710")
        let expected =
            "f58c4c04d6e5f1ba779eabfb5f7bfbd6"
            + "9cfc4e967edb808d679f777bc6702c7d"
            + "39f23369a9d9bacfa530e26304231461"
            + "b2eb05e2c39be9fcda6c19078c6a9d1b"

        #expect(hex(pdfAESEncryptCBCNoPadding(key: key, iv: iv, plain)) == expected)
        #expect(hex(pdfAESDecryptCBCNoPadding(key: key, iv: iv, bytes(expected))) == hex(plain))
    }

    /// NIST SP 800-38A F.2.1: AES-128-CBC, which Algorithm 2.B uses as its
    /// mixing function.
    @Test func aes128CbcMatchesTheNistVector() {
        let key = bytes("2b7e151628aed2a6abf7158809cf4f3c")
        let iv = bytes("000102030405060708090a0b0c0d0e0f")
        let plain = bytes("6bc1bee22e409f96e93d7e117393172a")
        #expect(
            hex(pdfAESEncryptCBCNoPadding(key: key, iv: iv, plain))
                == "7649abac8119b246cee98e9b12e9197d")
    }

    /// A key of the wrong length is refused rather than padded or truncated:
    /// guessing would decrypt to noise that parses.
    @Test func onlySupportedKeyLengthsExpand() {
        #expect(pdfAESExpandKey([UInt8](repeating: 0, count: 16))?.count == 11)
        #expect(pdfAESExpandKey([UInt8](repeating: 0, count: 32))?.count == 15)
        #expect(pdfAESExpandKey([UInt8](repeating: 0, count: 24)) == nil)
        #expect(pdfAESExpandKey([]) == nil)
    }
}
