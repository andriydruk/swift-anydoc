// CompoundFile (MS-CFB) tests: real Office fixtures, a hand-built container
// exercising the mini stream and name ordering, error-message parity with the
// cfb crate (one message is pinned by a golden), and a corruption sweep.
import Foundation
import Testing
@testable import AnyDoc

func fixtureBytes(_ rel: String) throws -> [UInt8] {
    [UInt8](try Data(contentsOf: fixtureRoot.appendingPathComponent(rel)))
}

func testResourceBytes(_ name: String) throws -> [UInt8] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Resources")
        .appendingPathComponent(name)
    return [UInt8](try Data(contentsOf: url))
}

// MARK: - Minimal CFB builder (V3): FAT sector, one directory sector, one
// mini-FAT sector, then mini-stream and regular-stream data sectors.

private func appendU16(_ out: inout [UInt8], _ v: UInt16) {
    out.append(UInt8(v & 0xFF))
    out.append(UInt8(v >> 8))
}

private func appendU32(_ out: inout [UInt8], _ v: UInt32) {
    appendU16(&out, UInt16(v & 0xFFFF))
    appendU16(&out, UInt16(v >> 16))
}

private let END: UInt32 = 0xFFFF_FFFE
private let FREE: UInt32 = 0xFFFF_FFFF
private let NOSTREAM: UInt32 = 0xFFFF_FFFF

private func dirEntry(
    name: String, type: UInt8, right: UInt32, child: UInt32, start: UInt32, len: UInt64
) -> [UInt8] {
    var out: [UInt8] = []
    let units = Array(name.utf16)
    precondition(units.count <= 31)
    for u in units { appendU16(&out, u) }
    for _ in units.count..<32 { appendU16(&out, 0) }
    appendU16(&out, UInt16((units.count + 1) * 2))
    out.append(type)
    out.append(1)  // black
    appendU32(&out, NOSTREAM)  // left
    appendU32(&out, right)
    appendU32(&out, child)
    out.append(contentsOf: [UInt8](repeating: 0, count: 16))  // CLSID
    appendU32(&out, 0)  // state bits
    out.append(contentsOf: [UInt8](repeating: 0, count: 16))  // timestamps
    appendU32(&out, start)
    appendU32(&out, UInt32(len & 0xFFFF_FFFF))
    appendU32(&out, UInt32(len >> 32))
    return out
}

/// Build a V3 compound file holding `streams` directly under root. At most
/// three streams (one directory sector); streams under 4096 bytes go to the
/// mini stream, larger ones get regular chains.
func makeCfb(_ streams: [(name: String, bytes: [UInt8])]) -> [UInt8] {
    let sorted = streams.sorted { cfbCompareNames($0.name, $1.name) < 0 }
    precondition(sorted.count <= 3, "one directory sector holds root + 3 entries")

    // Allocate mini sectors, then the sector layout:
    // 0 = FAT, 1 = directory, 2 = mini-FAT, 3... = mini container, then
    // regular stream chains.
    var miniStarts: [Int: UInt32] = [:]  // stream index -> first mini sector
    var miniCount = 0
    for (i, s) in sorted.enumerated() where s.bytes.count < 4096 {
        let n = (s.bytes.count + 63) / 64
        miniStarts[i] = n == 0 ? END : UInt32(miniCount)
        miniCount += n
    }
    let containerSectors = (miniCount * 64 + 511) / 512
    var nextSector = UInt32(3 + containerSectors)
    var regularStarts: [Int: UInt32] = [:]
    var fatEntries: [UInt32] = [0xFFFF_FFFD, END, END]  // FAT, dir, mini-FAT
    for s in 3..<(3 + containerSectors) {
        fatEntries.append(s == 3 + containerSectors - 1 ? END : UInt32(s + 1))
    }
    for (i, s) in sorted.enumerated() where s.bytes.count >= 4096 {
        let n = (s.bytes.count + 511) / 512
        regularStarts[i] = nextSector
        for k in 0..<n {
            fatEntries.append(k == n - 1 ? END : nextSector + UInt32(k) + 1)
        }
        nextSector += UInt32(n)
    }
    precondition(fatEntries.count <= 128, "one FAT sector")

    var out: [UInt8] = []
    // Header.
    out.append(contentsOf: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    out.append(contentsOf: [UInt8](repeating: 0, count: 16))
    appendU16(&out, 0x3E)  // minor version
    appendU16(&out, 3)
    appendU16(&out, 0xFFFE)
    appendU16(&out, 9)  // sector shift
    appendU16(&out, 6)  // mini sector shift
    out.append(contentsOf: [UInt8](repeating: 0, count: 6))
    appendU32(&out, 0)  // num dir sectors
    appendU32(&out, 1)  // num FAT sectors
    appendU32(&out, 1)  // first dir sector
    appendU32(&out, 0)  // transaction signature
    appendU32(&out, 4096)  // mini stream cutoff
    appendU32(&out, 2)  // first mini-FAT sector
    appendU32(&out, 1)  // num mini-FAT sectors
    appendU32(&out, END)  // first DIFAT sector
    appendU32(&out, 0)  // num DIFAT sectors
    appendU32(&out, 0)  // DIFAT[0]: the FAT sector
    for _ in 1..<109 { appendU32(&out, FREE) }

    // Sector 0: FAT.
    for e in fatEntries { appendU32(&out, e) }
    for _ in fatEntries.count..<128 { appendU32(&out, FREE) }

    // Sector 1: directory.
    out.append(
        contentsOf: dirEntry(
            name: "Root Entry", type: 5, right: NOSTREAM,
            child: sorted.isEmpty ? NOSTREAM : 1,
            start: containerSectors > 0 ? 3 : END,
            len: UInt64(miniCount * 64)))
    for (i, s) in sorted.enumerated() {
        let start = miniStarts[i] ?? regularStarts[i] ?? END
        out.append(
            contentsOf: dirEntry(
                name: s.name, type: 2,
                right: i + 1 < sorted.count ? UInt32(i + 2) : NOSTREAM,
                child: NOSTREAM, start: start, len: UInt64(s.bytes.count)))
    }
    for _ in sorted.count..<3 {
        out.append(contentsOf: [UInt8](repeating: 0, count: 128))
    }

    // Sector 2: mini-FAT.
    var miniFatEntries: [UInt32] = []
    for (i, s) in sorted.enumerated() where s.bytes.count < 4096 {
        let n = (s.bytes.count + 63) / 64
        guard n > 0, let start = miniStarts[i] else { continue }
        for k in 0..<n {
            miniFatEntries.append(k == n - 1 ? END : start + UInt32(k) + 1)
        }
    }
    for e in miniFatEntries { appendU32(&out, e) }
    for _ in miniFatEntries.count..<128 { appendU32(&out, FREE) }

    // Mini container sectors.
    var container: [UInt8] = []
    for (i, s) in sorted.enumerated() where s.bytes.count < 4096 && miniStarts[i] != END {
        container.append(contentsOf: s.bytes)
        let pad = (64 - s.bytes.count % 64) % 64
        container.append(contentsOf: [UInt8](repeating: 0, count: pad))
    }
    let containerPad = containerSectors * 512 - container.count
    container.append(contentsOf: [UInt8](repeating: 0, count: max(containerPad, 0)))
    out.append(contentsOf: container)

    // Regular stream sectors.
    for (i, s) in sorted.enumerated() where regularStarts[i] != nil {
        out.append(contentsOf: s.bytes)
        let pad = (512 - s.bytes.count % 512) % 512
        out.append(contentsOf: [UInt8](repeating: 0, count: pad))
    }
    return out
}

// MARK: - Tests

@Suite struct CfbTests {
    @Test func docFixtureExposesItsStreams() throws {
        let ole = try CompoundFile(bytes: try fixtureBytes("doc/text.doc"))
        #expect(ole.hasRootEntry("WordDocument"))
        #expect(ole.hasRootEntry("WORDDOCUMENT"), "lookups are case-insensitive")
        #expect(ole.hasRootEntry("ObjectPool"), "storages count as entries")
        #expect(!ole.hasRootEntry("PowerPoint Document"))
        let wordDoc = try #require(ole.readStream(["WordDocument"]))
        #expect(wordDoc.count == 8239)
        #expect(getU16(wordDoc, 0) == 0xA5EC, "a Word stream starts with the FIB magic")
        #expect(ole.readStream(["ObjectPool"]) == nil, "a storage is not readable as a stream")
        #expect(ole.readStream(["NoSuchStream"]) == nil)
        let names = ole.rootEntryNames
        #expect(names.contains("WordDocument"))
        #expect(names.contains("1Table"))
        #expect(
            names == names.sorted { cfbCompareNames($0, $1) < 0 },
            "root entries iterate in CFB name order")
    }

    @Test func pptFixturesExposeThePowerPointStream() throws {
        for fixture in ["ppt/pres.ppt", "ppt/handmade-multimaster.ppt", "ppt/handmade-sparsenotes.ppt"] {
            let ole = try CompoundFile(bytes: try fixtureBytes(fixture))
            #expect(ole.hasRootEntry("PowerPoint Document"), "fixture \(fixture)")
            let stream = try #require(ole.readStream(["PowerPoint Document"]), "fixture \(fixture)")
            #expect(!stream.isEmpty, "fixture \(fixture)")
        }
    }

    @Test func xlsFixtureExposesTheWorkbookStream() throws {
        let ole = try CompoundFile(bytes: try fixtureBytes("xls/sheet.xls"))
        #expect(ole.hasRootEntry("Workbook"))
        let workbook = try #require(ole.readStream(["Workbook"]))
        #expect(workbook.count == 3246)
    }

    @Test func miniStreamRoundtrips() throws {
        let small = (0..<100).map { UInt8($0 % 251) }
        let medium = (0..<200).map { UInt8(($0 &* 7) % 253) }
        let ole = try CompoundFile(bytes: makeCfb([("Small", small), ("Medium", medium)]))
        #expect(ole.readStream(["Small"]) == small)
        #expect(ole.readStream(["Medium"]) == medium)
        #expect(ole.readStream(["small"]) == small, "case-insensitive")
        #expect(try ole.readStream(["Small"], limit: 10) == Array(small.prefix(10)))
    }

    @Test func regularStreamRoundtrips() throws {
        let big = (0..<5000).map { UInt8($0 % 249) }
        let ole = try CompoundFile(bytes: makeCfb([("Big", big)]))
        #expect(ole.readStream(["Big"]) == big)
    }

    @Test func rootEntriesIterateInShortlexNameOrder() throws {
        let ole = try CompoundFile(bytes: makeCfb([("bb", [1]), ("a", [2]), ("Q", [3])]))
        // Shorter names first; equal lengths compare uppercased.
        #expect(ole.rootEntryNames == ["a", "Q", "bb"])
        #expect(ole.hasRootEntry("q"))
    }

    @Test func truncatedDocErrorMatchesTheRustGolden() throws {
        // The malformed__truncated--errors.doc golden pins this message via
        // the doc frontend's "not an OLE2 compound file: {e}" wrapper.
        let bytes = try fixtureBytes("malformed/truncated--errors.doc")
        do {
            _ = try CompoundFile(bytes: bytes)
            Issue.record("expected the truncated fixture to be rejected")
        } catch let error as ConvertError {
            #expect(
                error.message
                    == "malformed document: Malformed FAT (FAT has 39 entries, but file has only 7 sectors)")
        }
    }

    @Test func headerValidationMessagesMatchTheCrate() throws {
        do {
            _ = try CompoundFile(bytes: [])
            Issue.record("expected an error")
        } catch let error as ConvertError {
            #expect(error.message == "malformed document: Invalid CFB file (0 bytes is too small)")
        }
        do {
            _ = try CompoundFile(bytes: [UInt8](repeating: 0, count: 512))
            Issue.record("expected an error")
        } catch let error as ConvertError {
            #expect(
                error.message
                    == "malformed document: Invalid CFB file (wrong magic number): [0, 0, 0, 0, 0, 0, 0, 0]")
        }
        var badShift = makeCfb([])
        badShift[30] = 12
        do {
            _ = try CompoundFile(bytes: badShift)
            Issue.record("expected an error")
        } catch let error as ConvertError {
            #expect(
                error.message
                    == "malformed document: Incorrect sector shift for CFB version 3 (expected 9, found 12)")
        }
    }

    @Test func corruptionSweepNeverCrashesOrHangs() throws {
        // Deterministically flip bytes across the whole file; every mutation
        // must either parse or throw, boundedly.
        let original = try fixtureBytes("doc/text.doc")
        var opened = 0
        var rejected = 0
        for i in 0..<50 {
            var mutated = original
            let pos = (original.count / 50) * i
            mutated[pos] ^= 0xA5
            do {
                let ole = try CompoundFile(bytes: mutated)
                _ = ole.rootEntryNames
                _ = ole.hasRootEntry("WordDocument")
                _ = ole.readStream(["WordDocument"])
                _ = ole.readStream(["1Table"])
                opened += 1
            } catch {
                rejected += 1
            }
        }
        // Truncations, including mid-sector cuts.
        for length in [0, 100, 511, 512, 513, 1024, 4096, original.count - 100] {
            let cut = Array(original.prefix(length))
            do {
                let ole = try CompoundFile(bytes: cut)
                _ = ole.readStream(["WordDocument"])
            } catch {}
        }
        #expect(opened + rejected == 50)
    }
}
