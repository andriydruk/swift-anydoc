import Testing

@testable import AnyDoc

/// MD5 and RC4 against their specifications' own test vectors.
///
/// These are published constants, not values this port produced — which is
/// the only honest way to check a primitive whose whole purpose is to agree
/// with everyone else's implementation.
@Suite struct PdfCryptoTests {
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    @Test func md5MatchesRfc1321TestSuite() {
        // RFC 1321, appendix A.5 — every vector, verbatim.
        let vectors: [(String, String)] = [
            ("", "d41d8cd98f00b204e9800998ecf8427e"),
            ("a", "0cc175b9c0f1b6a831c399e269772661"),
            ("abc", "900150983cd24fb0d6963f7d28e17f72"),
            ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
            ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
            (
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
                "d174ab98d277d9f5a5611c2c9f419d9f"
            ),
            (
                "12345678901234567890123456789012345678901234567890"
                    + "123456789012345678901234567890",
                "57edf4a22be3c955ac49da2e2107b67a"
            ),
        ]
        for (input, expected) in vectors {
            #expect(hex(pdfMD5(Array(input.utf8))) == expected, "\(input.prefix(20))")
        }
    }

    @Test func md5HandlesTheBlockBoundary() {
        // 55, 56 and 64 bytes straddle the padding rule: 56 forces a second
        // block, which is where a length-encoding mistake first shows.
        #expect(hex(pdfMD5([UInt8](repeating: 0x61, count: 55)))
            == "ef1772b6dff9a122358552954ad0df65")
        #expect(hex(pdfMD5([UInt8](repeating: 0x61, count: 56)))
            == "3b0c8ac703f828b04c6c197006d17218")
        #expect(hex(pdfMD5([UInt8](repeating: 0x61, count: 64)))
            == "014842d480b571495a4a0363793f7367")
    }

    @Test func rc4MatchesRfc6229TestVectors() {
        // RFC 6229's first keystream bytes for two of its keys.
        let zeros = [UInt8](repeating: 0, count: 16)
        #expect(hex(pdfRC4(key: [0x01, 0x02, 0x03, 0x04, 0x05], zeros))
            == "b2396305f03dc027ccc3524a0a1118a8")
        #expect(hex(pdfRC4(key: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07], zeros))
            == "293f02d47f37c9b633f2af5285feb46b")
    }

    @Test func rc4IsItsOwnInverse() {
        let key: [UInt8] = [0x6b, 0x65, 0x79]
        let plain = Array("the quick brown fox".utf8)
        #expect(pdfRC4(key: key, pdfRC4(key: key, plain)) == plain)
    }

    @Test func anEmptyKeyPassesDataThrough() {
        // Not a cipher at all — but a document with no key must not have its
        // bytes mangled by a degenerate schedule.
        #expect(pdfRC4(key: [], [1, 2, 3]) == [1, 2, 3])
    }
}
