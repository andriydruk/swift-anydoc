import Testing

@testable import AnyDoc

/// SHA-256, SHA-384 and SHA-512 against the published vectors.
///
/// These are FIPS 180-4's own examples plus the NIST byte-oriented test
/// vectors. A hash is the one kind of code where a test can be *complete*:
/// the answer is fixed, public, and independent of anything this port does,
/// so there is no judgement here at all — only whether the arithmetic is
/// right.
///
/// All three matter. `/R 6` key derivation picks between them per round by
/// an intermediate value modulo three, so porting only SHA-256 would give a
/// correct key one time in three.
@Suite struct PdfSha2Tests {
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SHA-256

    @Test func sha256OfTheEmptyString() {
        #expect(
            hex(pdfSha256([]))
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func sha256OfAbc() {
        #expect(
            hex(pdfSha256(Array("abc".utf8)))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// 56 bytes: the case that forces a second block, because the length
    /// field no longer fits after the `0x80`. An off-by-one in the padding
    /// shows up here and nowhere else.
    @Test func sha256AtThePaddingBoundary() {
        let message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        #expect(message.utf8.count == 56)
        #expect(
            hex(pdfSha256(Array(message.utf8)))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    /// A million 'a' characters — the vector that catches a broken length
    /// counter, since the bit count exceeds 2^23.
    @Test func sha256OfAMillionCharacters() {
        #expect(
            hex(pdfSha256([UInt8](repeating: 0x61, count: 1_000_000)))
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    // MARK: - SHA-512

    @Test func sha512OfTheEmptyString() {
        #expect(
            hex(pdfSha512([]))
                == "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce"
                + "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
    }

    @Test func sha512OfAbc() {
        #expect(
            hex(pdfSha512(Array("abc".utf8)))
                == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
    }

    /// 112 bytes: SHA-512's padding boundary, twice the width of SHA-256's
    /// and with a sixteen-byte length field.
    @Test func sha512AtThePaddingBoundary() {
        let message =
            "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
            + "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        #expect(message.utf8.count == 112)
        #expect(
            hex(pdfSha512(Array(message.utf8)))
                == "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018"
                + "501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909")
    }

    // MARK: - SHA-384

    @Test func sha384OfTheEmptyString() {
        #expect(
            hex(pdfSha384([]))
                == "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da"
                + "274edebfe76f65fbd51ad2f14898b95b")
    }

    @Test func sha384OfAbc() {
        #expect(
            hex(pdfSha384(Array("abc".utf8)))
                == "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed"
                + "8086072ba1e7cc2358baeca134c825a7")
    }

    /// SHA-384 is SHA-512 truncated, so its digest must be a prefix of
    /// nothing — the initial state differs, and a port that forgot that
    /// would pass the length check while returning SHA-512's answer.
    @Test func sha384IsNotTruncatedSha512() {
        #expect(Array(pdfSha512(Array("abc".utf8)).prefix(48)) != pdfSha384(Array("abc".utf8)))
        #expect(pdfSha384([]).count == 48)
        #expect(pdfSha512([]).count == 64)
        #expect(pdfSha256([]).count == 32)
    }
}
