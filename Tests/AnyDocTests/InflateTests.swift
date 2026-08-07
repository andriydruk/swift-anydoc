// Raw DEFLATE vectors generated with `python3 -c "import zlib; ..."` using
// raw streams (wbits=-15), pinning the Inflate implementation against zlib.
import Testing
@testable import AnyDoc

func hexBytes(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var digits = hex.unicodeScalars.makeIterator()
    while let hi = digits.next(), let lo = digits.next() {
        out.append(UInt8(String(hi) + String(lo), radix: 16)!)
    }
    return out
}

@Suite struct InflateTests {
    @Test func emptyStream() throws {
        let result = try inflateRaw(hexBytes("0300")[...], maxOutput: 1024)
        #expect(result.bytes.isEmpty)
        #expect(!result.limitHit)
    }

    @Test func helloWorldFixedHuffman() throws {
        let input = hexBytes("cb48cdc9c95728cf2fca490100")
        let result = try inflateRaw(input[...], maxOutput: 1024)
        #expect(result.bytes == Array("hello world".utf8))
        #expect(!result.limitHit)
    }

    @Test func repetitiveTextExercisesWindowCopies() throws {
        // zlib -9 of 100 KB of repeated text; back-references span the block.
        let input = hexBytes(
            "edcadb1182301400d1566e05f4a4100451a221c147f53a16e1d7f9dcd953a714f736f74b1c4b7eac31e6"
                + "679cdbf5b645de5389fadd97c3fb15433e75bf8261188661188661188661188661188661188661188661"
                + "188661188661188661188661188661188661188661188661188661188661188661188661188661188661"
                + "188661188661188661188661188661188661188661188661188661188661188661188661188661188661"
                + "188661188661188661188661188661188661188661188661188661188661188661188661188661188661"
                + "188661188661188661188661188661188661188661188661188661188661188661188661188661188661"
                + "188661188661188661188661188661188661188661188661188661188661188661188661188661188661"
                + "188661188661188661188661188661188661188661188661188661188661188661188661188661188661"
                + "188661188661188661188661188661f86ff803")
        let expected = Array(
            String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 2500)
                .utf8)[..<100_000]
        let result = try inflateRaw(input[...], maxOutput: 200_000)
        #expect(result.bytes.count == 100_000)
        #expect(result.bytes[...] == expected)
        #expect(!result.limitHit)
    }

    @Test func randomBytesRoundTripThroughStoredBlock() throws {
        // zlib level 0 stores incompressible data verbatim in a stored block.
        let raw = hexBytes(
            "e13b032e112a32b579080f08b1f7ed4c2e5d3a07f97f21ee232d178a209af6b5887f66e8092402aa49f"
            + "2c1551b27fe53266e490db138489ce814d58d145a8b4f994fed15c5b2fdaeeff317f157e1e0978c3f"
            + "5fd5df3d34f8c08262b03750894fa5e42428ca6d189213702ca29ceb218325da6733cb63eb78b869d"
            + "759689a1eb44efff1aa474318544a23a657001f2c4b6f14ddc8a66ac38f9bd8a34d2f858ed2cc8d3a"
            + "c08c6d98cb1ab2e177fb54c29d0125f5ca98dbf55fcdf45090bdb16956eaf20eef350dbbf32147a9b"
            + "29498a996638e2568adaba4ea882b3d7d83be460eca13166a4fa0b5de239c85f870b22a09a97553f4"
            + "ff47224a7c54c9a742e414be23bcd11624a07465b1c2fc1a0fe52996daae4bf87b0fb6bed45926096"
            + "c6448438219efb9be93cbd0bc779204")
        let stored = [0x01, 0x2C, 0x01, 0xD3, 0xFE].map(UInt8.init) + raw
        let result = try inflateRaw(stored[...], maxOutput: 1024)
        #expect(result.bytes == raw)
        #expect(!result.limitHit)
    }

    @Test func dynamicHuffmanBlockDecodes() throws {
        let input = hexBytes("4b4c4a4e84a194d434384acfc884a3c45135a36a86881a00")
        let expected = Array(String(repeating: "abcabcabcabcdefdefdefdefghighighighi", count: 20).utf8)
        let result = try inflateRaw(input[...], maxOutput: 4096)
        #expect(result.bytes == expected)
        #expect(!result.limitHit)
    }

    @Test func truncatedStreamThrowsInsteadOfHanging() {
        let input = hexBytes("cb48cdc9c95728cf2fca490100")
        for cut in 0..<(input.count - 1) {
            #expect(throws: ConvertError.self) {
                try inflateRaw(input[..<cut], maxOutput: 1024)
            }
        }
    }

    @Test func corruptStreamThrows() {
        // BTYPE=3 is reserved.
        #expect(throws: ConvertError.self) {
            try inflateRaw([0x07][...], maxOutput: 16)
        }
        // Stored block with a wrong length complement.
        #expect(throws: ConvertError.self) {
            try inflateRaw([0x01, 0x02, 0x00, 0x00, 0x00, 0xAA, 0xBB][...], maxOutput: 16)
        }
        // Distance too far back: a fixed block whose first symbol is a
        // 3-byte copy at distance 1 with nothing in the window (zlib:
        // "invalid distance too far back").
        #expect(throws: ConvertError.self) {
            try inflateRaw(hexBytes("030200")[...], maxOutput: 16)
        }
    }

    @Test func outputBudgetTruncatesExactly() throws {
        let input = hexBytes("cb48cdc9c95728cf2fca490100")
        let truncated = try inflateRaw(input[...], maxOutput: 5)
        #expect(truncated.bytes == Array("hello".utf8))
        #expect(truncated.limitHit)

        let exact = try inflateRaw(input[...], maxOutput: 11)
        #expect(exact.bytes == Array("hello world".utf8))
        #expect(!exact.limitHit)

        let zero = try inflateRaw(input[...], maxOutput: 0)
        #expect(zero.bytes.isEmpty)
        #expect(zero.limitHit)
    }
}
