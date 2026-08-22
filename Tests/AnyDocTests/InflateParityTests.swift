// The system zlib and the in-repo decoder must agree.
//
// `inflateRaw` goes through zlib; `inflateRawSwift` is the fallback for a
// platform where zlib will not start, and the thing that made the in-repo
// implementation worth keeping once zlib landed. Two decoders that disagree
// would produce different documents depending on which ran, so this compares
// them over every deflate stream the corpus contains.
//
// Gated on `ANYDOC_PDF_CORPUS`, whose PDFs carry Flate streams, plus the
// hand-written cases below which cover the shapes a corpus may not.
import CZlib
import Foundation
import Testing

@testable import AnyDoc

@Suite struct InflateParityTests {
    /// Deflate a byte pattern by hand is impractical, so the fixtures below
    /// are known-good streams: stored blocks, fixed codes and dynamic codes.
    private static let streams: [(name: String, hex: String)] = [
        ("fixed codes", "cb48cdc9c95728cf2fca490100"),
        ("stored block", "0105 00fa ff68656c6c6f".replacingOccurrences(of: " ", with: "")),
        ("empty final block", "0300"),
    ]

    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, hex.index(after: index) < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    @Test func bothDecodersAgreeOnKnownStreams() throws {
        for (name, hex) in Self.streams {
            let input = bytes(hex)[...]
            let viaZlib = try? inflateRaw(input, maxOutput: 1 << 20)
            let viaSwift = try? inflateRawSwift(input, maxOutput: 1 << 20)
            #expect(viaZlib?.bytes == viaSwift?.bytes, "\(name): bytes differ")
            #expect(viaZlib?.limitHit == viaSwift?.limitHit, "\(name): limitHit differs")
        }
    }

    /// The budget boundary, where the two could most easily part company: one
    /// byte under, exactly on, and one over.
    @Test func bothDecodersAgreeAtTheBudgetBoundary() throws {
        let input = bytes("cb48cdc9c95728cf2fca490100")[...]  // "hello world", 11 bytes
        for budget in [0, 1, 5, 10, 11, 12, 100] {
            let viaZlib = try? inflateRaw(input, maxOutput: budget)
            let viaSwift = try? inflateRawSwift(input, maxOutput: budget)
            #expect(viaZlib?.bytes == viaSwift?.bytes, "budget \(budget): bytes differ")
            #expect(
                viaZlib?.limitHit == viaSwift?.limitHit, "budget \(budget): limitHit differs")
        }
    }

    /// Random streams, compressed by zlib and decompressed by both.
    ///
    /// Stronger than a fixed corpus: the generator mixes literal runs with
    /// repeated blocks, so the output exercises stored, fixed and dynamic
    /// blocks and — through the repeats — the back-reference path where the
    /// two decoders could most plausibly part company.
    @Test func bothDecodersAgreeOnGeneratedStreams() throws {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> UInt64 {
            seed ^= seed >> 12
            seed ^= seed << 25
            seed ^= seed >> 27
            return seed &* 0x2545_F491_4F6C_DD1D
        }

        var compared = 0
        for round in 0..<60 {
            // Payloads from highly repetitive to nearly incompressible.
            var payload: [UInt8] = []
            let target = 64 + Int(next() % 8192)
            while payload.count < target {
                if next() % 3 == 0, !payload.isEmpty {
                    let back = 1 + Int(next() % UInt64(payload.count))
                    let run = 1 + Int(next() % 200)
                    for i in 0..<run { payload.append(payload[payload.count - back + (i % back)]) }
                } else {
                    payload.append(UInt8(next() % 256))
                }
            }

            guard let deflated = rawDeflate(payload) else { continue }
            let budget = round % 4 == 0 ? payload.count / 2 : 1 << 22
            let viaZlib = try? inflateRaw(deflated[...], maxOutput: budget)
            let viaSwift = try? inflateRawSwift(deflated[...], maxOutput: budget)
            compared += 1
            #expect(viaZlib?.bytes == viaSwift?.bytes, "round \(round): bytes differ")
            #expect(viaZlib?.limitHit == viaSwift?.limitHit, "round \(round): limitHit differs")
            if budget >= payload.count {
                #expect(viaZlib?.bytes == payload, "round \(round): did not round-trip")
            }
        }
        print("inflate parity: \(compared) generated streams compared")
    }

    /// Compress with the system zlib, raw deflate, so the test has streams to
    /// decompress without shipping binary fixtures.
    private func rawDeflate(_ bytes: [UInt8]) -> [UInt8]? {
        var stream = z_stream()
        guard deflateInit2_(&stream, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return nil }
        defer { deflateEnd(&stream) }
        var out = [UInt8](repeating: 0, count: bytes.count * 2 + 128)
        var produced = 0
        var input = bytes
        let ok = input.withUnsafeMutableBufferPointer { source -> Bool in
            stream.next_in = source.baseAddress
            stream.avail_in = uInt(source.count)
            return out.withUnsafeMutableBufferPointer { destination -> Bool in
                stream.next_out = destination.baseAddress
                stream.avail_out = uInt(destination.count)
                let code = deflate(&stream, Z_FINISH)
                produced = destination.count - Int(stream.avail_out)
                return code == Z_STREAM_END
            }
        }
        return ok ? Array(out[0..<produced]) : nil
    }
}
