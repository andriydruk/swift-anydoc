// Ported from src/package/archive.rs tests, plus reader-level coverage for
// the raw ZIP layer (error strings mirror the Rust zip crate) and a
// deterministic mutation smoke test in the spirit of tests/robustness.rs.
import Testing
@testable import AnyDoc

/// One entry for `makeZip`. Stored (method 0) by default; pass `method: 8`
/// with pre-compressed `bytes` plus explicit crc/size for deflate entries.
struct TestZipEntry {
    var name: String
    var bytes: [UInt8]
    var flags: UInt16 = 0
    var method: UInt16 = 0
    var crc: UInt32? = nil
    var uncompressedSize: UInt32? = nil
    /// Central-record compressed size; defaults to `bytes.count` (set the
    /// 0xFFFFFFFF sentinel to exercise the ZIP64 extra field).
    var compressedSize: UInt32? = nil
    /// Extra field bytes written to the central record only.
    var centralExtra: [UInt8] = []
}

/// Minimal ZIP writer for tests: local headers, central directory, EOCD.
func makeZip(_ entries: [TestZipEntry]) -> [UInt8] {
    var out: [UInt8] = []
    var central: [UInt8] = []
    for entry in entries {
        let nameBytes = Array(entry.name.utf8)
        let crc = entry.crc ?? zipCrc32(entry.bytes[...])
        let uncompressed = entry.uncompressedSize ?? UInt32(entry.bytes.count)
        let offset = UInt32(out.count)
        putU32(&out, 0x0403_4B50)
        putU16(&out, 20)
        putU16(&out, entry.flags)
        putU16(&out, entry.method)
        putU16(&out, 0)
        putU16(&out, 0)
        putU32(&out, crc)
        putU32(&out, UInt32(entry.bytes.count))
        putU32(&out, uncompressed)
        putU16(&out, UInt16(nameBytes.count))
        putU16(&out, 0)
        out += nameBytes
        out += entry.bytes

        putU32(&central, 0x0201_4B50)
        putU16(&central, 20)
        putU16(&central, 20)
        putU16(&central, entry.flags)
        putU16(&central, entry.method)
        putU16(&central, 0)
        putU16(&central, 0)
        putU32(&central, crc)
        putU32(&central, entry.compressedSize ?? UInt32(entry.bytes.count))
        putU32(&central, uncompressed)
        putU16(&central, UInt16(nameBytes.count))
        putU16(&central, UInt16(entry.centralExtra.count))
        putU16(&central, 0)
        putU16(&central, 0)
        putU16(&central, 0)
        putU32(&central, 0)
        putU32(&central, offset)
        central += nameBytes
        central += entry.centralExtra
    }
    let cdOffset = UInt32(out.count)
    out += central
    putU32(&out, 0x0605_4B50)
    putU16(&out, 0)
    putU16(&out, 0)
    putU16(&out, UInt16(entries.count))
    putU16(&out, UInt16(entries.count))
    putU32(&out, UInt32(central.count))
    putU32(&out, cdOffset)
    putU16(&out, 0)
    return out
}

func makeZip(_ parts: [(String, [UInt8])]) -> [UInt8] {
    makeZip(parts.map { TestZipEntry(name: $0.0, bytes: $0.1) })
}

/// A stored-entry archive whose EOCD carries the ZIP64 sentinels, so entry
/// count and central-directory offset come from the EOCD64 record via its
/// locator.
func makeZip64(_ parts: [(String, [UInt8])]) -> [UInt8] {
    var zip = makeZip(parts)
    // Drop the zip32 EOCD written by makeZip (22 bytes, no comment).
    zip.removeLast(22)
    // Recompute the central directory span: it ends where the EOCD began.
    var central = 0
    var scan = 0
    while scan + 4 <= zip.count {
        if zip[scan] == 0x50, zip[scan + 1] == 0x4B, zip[scan + 2] == 0x01, zip[scan + 3] == 0x02 {
            central = scan
            break
        }
        scan += 1
    }
    let cdSize = zip.count - central
    let eocd64Offset = zip.count
    // EOCD64 record (fixed part only, record_size 44).
    putU32(&zip, 0x0606_4B50)
    putU64(&zip, 44)  // record size
    putU16(&zip, 45)  // version made by
    putU16(&zip, 45)  // version needed
    putU32(&zip, 0)  // disk number
    putU32(&zip, 0)  // disk with central directory
    putU64(&zip, UInt64(parts.count))
    putU64(&zip, UInt64(parts.count))
    putU64(&zip, UInt64(cdSize))
    putU64(&zip, UInt64(central))
    // EOCD64 locator.
    putU32(&zip, 0x0706_4B50)
    putU32(&zip, 0)  // disk with central directory
    putU64(&zip, UInt64(eocd64Offset))
    putU32(&zip, 1)  // total disks
    // Zip32 EOCD, all counts and offsets deferred to the EOCD64.
    putU32(&zip, 0x0605_4B50)
    putU16(&zip, 0)
    putU16(&zip, 0)
    putU16(&zip, 0xFFFF)
    putU16(&zip, 0xFFFF)
    putU32(&zip, 0xFFFF_FFFF)
    putU32(&zip, 0xFFFF_FFFF)
    putU16(&zip, 0)
    return zip
}

private func putU16(_ out: inout [UInt8], _ value: UInt16) {
    out.append(UInt8(value & 0xFF))
    out.append(UInt8(value >> 8))
}

private func putU32(_ out: inout [UInt8], _ value: UInt32) {
    out.append(UInt8(value & 0xFF))
    out.append(UInt8((value >> 8) & 0xFF))
    out.append(UInt8((value >> 16) & 0xFF))
    out.append(UInt8(value >> 24))
}

private func putU64(_ out: inout [UInt8], _ value: UInt64) {
    putU32(&out, UInt32(value & 0xFFFF_FFFF))
    putU32(&out, UInt32(value >> 32))
}

private func onePartZip(_ name: String, _ bytes: [UInt8]) -> [UInt8] {
    makeZip([(name, bytes)])
}

private func convertErrorMessage(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch let e as ConvertError {
        return e.message
    } catch {
        return "unexpected error type: \(error)"
    }
}

@Suite struct ArchiveTests {
    @Test func repeatedReadsAreCachedAndChargedOnce() throws {
        let data = onePartZip("media/a.bin", [UInt8](repeating: 7, count: 4096))
        let pkg = try Package.open(data)
        for _ in 0..<5 {
            let part = try #require(try pkg.part("media/a.bin"))
            #expect(part.count == 4096)
        }
        #expect(pkg.totalRead == 4096, "repeated reads must not re-charge the budget")
    }

    @Test func totalBudgetExhaustionReportsMaxTotalBytes() throws {
        let data = makeZip([
            ("a.bin", [UInt8](repeating: 7, count: 4096)),
            ("b.bin", [UInt8](repeating: 7, count: 4096)),
        ])
        let pkg = try Package.open(data)
        #expect(try pkg.part("a.bin") != nil)
        // Simulate a large archive having consumed almost the whole total
        // budget across earlier entries; the next entry no longer fits.
        pkg.totalRead = Limits.maxTotalBytes - 100
        let message = convertErrorMessage { _ = try pkg.part("b.bin") }
        #expect(
            message
                == "resource limit exceeded (max_total_bytes): "
                + "b.bin exceeds the archive's remaining decompression budget")
    }

    @Test func leadingSlashPartNamesNormalize() throws {
        let data = onePartZip("word/document.xml", Array("<x/>".utf8))
        let pkg = try Package.open(data)
        #expect(try pkg.part("/word/document.xml") != nil)
        #expect(pkg.hasPart("/word/document.xml"))
    }

    @Test func absentPartsAreNilNotErrors() throws {
        let pkg = try Package.open(onePartZip("a.txt", Array("hi".utf8)))
        #expect(try pkg.part("missing.xml") == nil)
        let message = convertErrorMessage { _ = try pkg.requiredPart("missing.xml") }
        #expect(message == "missing required part: missing.xml")
    }

    @Test func emptyAndTruncatedArchivesReportMissingEocd() {
        for bytes in [[], Array("PK\u{03}\u{04}not really a zip".utf8)] as [[UInt8]] {
            let message = convertErrorMessage { _ = try Package.open(bytes) }
            #expect(
                message
                    == "malformed document: not a readable zip archive: "
                    + "invalid Zip archive: Could not find EOCD")
        }
    }

    @Test func encryptedEntriesReportPasswordRequired() throws {
        // General-purpose flag bit 0: the payload is encrypted (ZipCrypto
        // and AES both set it).
        let data = makeZip([
            TestZipEntry(name: "secret.xml", bytes: Array("x".utf8), flags: 0x0001)
        ])
        let pkg = try Package.open(data)
        let message = convertErrorMessage { _ = try pkg.part("secret.xml") }
        #expect(
            message
                == "malformed document (secret.xml): unreadable archive entry: "
                + "unsupported Zip archive: Password required to decrypt file")
    }

    @Test func unsupportedCompressionMethodIsNamed() throws {
        let data = makeZip([
            TestZipEntry(name: "a.bin", bytes: Array("x".utf8), method: 9)
        ])
        let pkg = try Package.open(data)
        let message = convertErrorMessage { _ = try pkg.part("a.bin") }
        #expect(
            message
                == "malformed document (a.bin): unreadable archive entry: "
                + "compression method not supported: 9")
    }

    @Test func crcMismatchSurfacesAsInvalidChecksum() throws {
        let data = makeZip([
            TestZipEntry(name: "a.bin", bytes: Array("hello".utf8), crc: 0xDEAD_BEEF)
        ])
        let pkg = try Package.open(data)
        let message = convertErrorMessage { _ = try pkg.part("a.bin") }
        #expect(
            message
                == "malformed document (a.bin): corrupt archive entry: Invalid checksum")
    }

    @Test func corruptDeflateStreamIsNamed() throws {
        let data = makeZip([
            TestZipEntry(
                name: "a.bin", bytes: [0xFF, 0xFF, 0xFF], method: 8, crc: 0,
                uncompressedSize: 100)
        ])
        let pkg = try Package.open(data)
        let message = convertErrorMessage { _ = try pkg.part("a.bin") }
        #expect(
            message
                == "malformed document (a.bin): corrupt archive entry: corrupt deflate stream")
    }

    @Test func deflateEntriesDecompress() throws {
        // Raw deflate of "hello world" (zlib wbits=-15).
        let compressed = hexBytes("cb48cdc9c95728cf2fca490100")
        let plain = Array("hello world".utf8)
        let data = makeZip([
            TestZipEntry(
                name: "word/document.xml", bytes: compressed, method: 8,
                crc: zipCrc32(plain[...]), uncompressedSize: UInt32(plain.count))
        ])
        let pkg = try Package.open(data)
        #expect(try pkg.part("word/document.xml") == plain)
    }

    @Test func declaredSizeOverEntryLimitIsRejected() throws {
        let data = makeZip([
            TestZipEntry(
                name: "big.bin", bytes: Array("x".utf8), crc: nil,
                uncompressedSize: UInt32.max - 1)
        ])
        let pkg = try Package.open(data)
        let message = convertErrorMessage { _ = try pkg.part("big.bin") }
        #expect(
            message
                == "resource limit exceeded (max_entry_bytes): "
                + "big.bin declares \(UInt32.max - 1) decompressed bytes")
    }

    @Test func duplicateNamesCollapseToTheLastEntry() throws {
        let data = makeZip([
            ("a.txt", Array("first".utf8)),
            ("a.txt", Array("second".utf8)),
        ])
        let pkg = try Package.open(data)
        #expect(try pkg.part("a.txt") == Array("second".utf8))
    }

    @Test func prependedJunkShiftsTheArchiveOffset() throws {
        // Self-extracting archives carry data before the first local header;
        // the first CDFH signature defines the offset.
        let zip = onePartZip("word/document.xml", Array("<x/>".utf8))
        let data = Array("JUNKJUNK".utf8) + zip
        let pkg = try Package.open(data)
        #expect(try pkg.part("word/document.xml") == Array("<x/>".utf8))
    }

    @Test func zip64FooterCarriesCountsAndOffsets() throws {
        let data = makeZip64([("a.txt", Array("hi".utf8))])
        let pkg = try Package.open(data)
        #expect(try pkg.part("a.txt") == Array("hi".utf8))
    }

    @Test func zip64ExtraFieldOverridesSentinelSizes() throws {
        let content = Array("hello zip64".utf8)
        var extra: [UInt8] = []
        putU16(&extra, 0x0001)
        putU16(&extra, 16)
        putU64(&extra, UInt64(content.count))  // uncompressed
        putU64(&extra, UInt64(content.count))  // compressed
        let data = makeZip([
            TestZipEntry(
                name: "a.txt", bytes: content, crc: zipCrc32(content[...]),
                uncompressedSize: 0xFFFF_FFFF, compressedSize: 0xFFFF_FFFF,
                centralExtra: extra)
        ])
        let pkg = try Package.open(data)
        #expect(try pkg.part("a.txt") == content)
    }

    @Test func missingZip64RecordIsNamed() throws {
        var data = makeZip64([("a.txt", Array("hi".utf8))])
        // Break the EOCD64 signature; the locator now points at nothing.
        let sig: [UInt8] = [0x50, 0x4B, 0x06, 0x06]
        for i in 0..<(data.count - 4) where Array(data[i..<i + 4]) == sig {
            data[i] = 0x00
        }
        let message = convertErrorMessage { _ = try Package.open(data) }
        #expect(
            message
                == "malformed document: not a readable zip archive: "
                + "invalid Zip archive: Could not find EOCD64")
    }

    @Test func mutatedZipsNeverCrash() throws {
        // Deterministic xorshift64* mutations, as in tests/robustness.rs:
        // open/read may fail with typed errors but must never trap or hang.
        var state: UInt64 = 0x5EED_1234_5678_9ABC
        func next() -> UInt64 {
            var x = state
            x ^= x >> 12
            x ^= x << 25
            x ^= x >> 27
            state = x
            return x &* 0x2545_F491_4F6C_DD1D
        }
        let compressed = hexBytes("cb48cdc9c95728cf2fca490100")
        let plain = Array("hello world".utf8)
        let original = makeZip([
            TestZipEntry(name: "word/document.xml", bytes: compressed, method: 8,
                crc: zipCrc32(plain[...]), uncompressedSize: UInt32(plain.count)),
            TestZipEntry(name: "media/raw.bin", bytes: [UInt8](repeating: 0xA5, count: 64)),
        ])
        for _ in 0..<200 {
            var bytes = original
            for _ in 0...(next() % 8) {
                bytes[Int(next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: next())
            }
            if next() % 4 == 0 {
                bytes = Array(bytes[..<max(1, Int(next() % UInt64(bytes.count)))])
            }
            guard let pkg = try? Package.open(bytes) else { continue }
            _ = try? pkg.part("word/document.xml")
            _ = try? pkg.part("media/raw.bin")
            _ = Format.detect(from: bytes)
        }
    }
}
