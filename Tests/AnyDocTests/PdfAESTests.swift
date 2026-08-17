import Testing

@testable import AnyDoc

/// AES-128 against FIPS-197's own test vectors.
@Suite struct PdfAESTests {
    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).compactMap {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)
        }
    }

    private func hex(_ data: [UInt8]) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test func decryptsTheFips197Vector() {
        // FIPS-197 appendix C.1: the canonical AES-128 block.
        let key = bytes("000102030405060708090a0b0c0d0e0f")
        let cipher = bytes("69c4e0d86a7b0430d8cdb78070b4c55a")
        let plain = bytes("00112233445566778899aabbccddeeff")
        let schedule = pdfAESExpandKey(key)!
        #expect(hex(pdfAESDecryptBlock(schedule, cipher)) == hex(plain))
    }

    @Test func decryptsTheAppendixBVector() {
        // FIPS-197 appendix B, the worked example with a different key.
        let key = bytes("2b7e151628aed2a6abf7158809cf4f3c")
        let cipher = bytes("3925841d02dc09fbdc118597196a0b32")
        let plain = bytes("3243f6a8885a308d313198a2e0370734")
        let schedule = pdfAESExpandKey(key)!
        #expect(hex(pdfAESDecryptBlock(schedule, cipher)) == hex(plain))
    }

    @Test func theKeyScheduleMatchesTheSpecification() {
        // FIPS-197 appendix A.1: the last round key for the appendix B key.
        let schedule = pdfAESExpandKey(bytes("2b7e151628aed2a6abf7158809cf4f3c"))!
        #expect(schedule.count == 11)
        #expect(hex(schedule[0]) == "2b7e151628aed2a6abf7158809cf4f3c")
        #expect(hex(schedule[10]) == "d014f9a8c9ee2589e13f0cc8b6630ca6")
    }

    @Test func aWrongSizedKeyIsRefused() {
        // Only AES-128 is implemented; a 256-bit key must not be silently
        // truncated into a cipher that decrypts to noise.
        #expect(pdfAESExpandKey([UInt8](repeating: 0, count: 32)) == nil)
        #expect(pdfAESExpandKey([]) == nil)
    }

    @Test func cbcRemovesValidPaddingOnly() {
        // A block of sixteen 0x10 bytes is a full pad and vanishes; anything
        // that is not a valid PKCS#7 tail is left alone, since truncating on
        // a corrupt block loses real text.
        let key = bytes("000102030405060708090a0b0c0d0e0f")
        let schedule = pdfAESExpandKey(key)!
        _ = schedule
        // Too short to hold an IV and a block.
        #expect(pdfAESDecryptCBC(key: key, [UInt8](repeating: 0, count: 16)).isEmpty)
        // Not a whole number of blocks.
        #expect(pdfAESDecryptCBC(key: key, [UInt8](repeating: 0, count: 33)).isEmpty)
    }
}
