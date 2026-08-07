// Tests for src/shared/officeart.rs behavior (the Rust module carries no
// unit tests of its own; these pin the record and blip layouts it decodes).
import Testing
@testable import AnyDoc

/// An OfficeArt record: 8-byte header (verInst, recType, length) + body.
private func record(verInst: UInt16, recType: UInt16, body: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.append(UInt8(verInst & 0xFF))
    out.append(UInt8(verInst >> 8))
    out.append(UInt8(recType & 0xFF))
    out.append(UInt8(recType >> 8))
    let len = UInt32(body.count)
    out.append(UInt8(len & 0xFF))
    out.append(UInt8((len >> 8) & 0xFF))
    out.append(UInt8((len >> 16) & 0xFF))
    out.append(UInt8((len >> 24) & 0xFF))
    out.append(contentsOf: body)
    return out
}

@Suite struct OfficeArtTests {
    @Test func recordAtParsesHeadersAndRejectsOverruns() {
        let data = record(verInst: 0x1234, recType: 0xF01E, body: [1, 2, 3])
        let rec = recordAt(data[...], 0)
        #expect(rec?.verInst == 0x1234)
        #expect(rec?.recType == 0xF01E)
        #expect(rec.map { Array($0.body) } == [1, 2, 3])
        // Declared length past the end of the data is no record.
        var truncated = data
        truncated[4] = 4
        #expect(recordAt(truncated[...], 0) == nil)
        #expect(recordAt(data[...], -1) == nil)
        #expect(recordAt(data[...], data.count) == nil)
    }

    @Test func bitmapBlipsSkipUidAndTag() {
        // Single UID (16 bytes) + tag byte, then the payload.
        let payload: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let body = [UInt8](repeating: 0xAA, count: 17) + payload
        let png = decodeBlip(verInst: 0x6E0 << 4, recType: 0xF01E, body: body[...], maxBytes: 1 << 20)
        #expect(png?.mediaType == "image/png")
        #expect(png?.extension == "png")
        #expect(png?.bytes == payload)
        // Doubled instance carries two UIDs.
        let doubled = [UInt8](repeating: 0xBB, count: 33) + payload
        let jpegInstance: UInt16 = 0x46B
        let jpg = decodeBlip(
            verInst: jpegInstance << 4, recType: 0xF01D, body: doubled[...], maxBytes: 1 << 20)
        #expect(jpg?.mediaType == "image/jpeg")
        #expect(jpg?.bytes == payload)
        // A body shorter than the UID prefix is no blip.
        #expect(decodeBlip(verInst: 0, recType: 0xF01E, body: body.prefix(10), maxBytes: 1 << 20) == nil)
    }

    @Test func uncompressedMetafileBlipsKeepTheirBytes() {
        let payload: [UInt8] = [1, 2, 3, 4, 5]
        var header = [UInt8](repeating: 0, count: 34)
        header[32] = 0xFE  // uncompressed
        let body = [UInt8](repeating: 0xCC, count: 16) + header + payload
        let wmf = decodeBlip(verInst: 0x216 << 4, recType: 0xF01B, body: body[...], maxBytes: 1 << 20)
        #expect(wmf?.mediaType == "image/wmf")
        #expect(wmf?.extension == "wmf")
        #expect(wmf?.bytes == payload)
    }

    @Test(.disabled("inflate lands at integration"))
    func compressedMetafileBlipsInflate() throws {
        // Deflate-compressed EMF payload: raw-deflate of [1,2,3,4,5]
        // (one stored block).
        let deflated: [UInt8] = [0x01, 0x05, 0x00, 0xFA, 0xFF, 1, 2, 3, 4, 5]
        var header = [UInt8](repeating: 0, count: 34)
        header[0] = 5  // cbSize
        header[32] = 0x00  // deflate-compressed
        let body = [UInt8](repeating: 0, count: 16) + header + deflated
        let emf = decodeBlip(verInst: 0x3D4 << 4, recType: 0xF01A, body: body[...], maxBytes: 1 << 20)
        #expect(emf?.mediaType == "image/emf")
        #expect(emf?.bytes == [1, 2, 3, 4, 5])
    }

    @Test func firstBlipDescendsContainersAndFbse() {
        let payload: [UInt8] = [9, 8, 7]
        let blipBody = [UInt8](repeating: 0, count: 17) + payload
        let blipRec = record(verInst: 0x6E0 << 4, recType: 0xF01E, body: blipBody)
        // FBSE: 36-byte header (cbName at 33) + name + embedded blip record.
        var fbseBody = [UInt8](repeating: 0, count: 36)
        fbseBody[33] = 2  // cbName
        fbseBody += [0x41, 0x42]
        fbseBody += blipRec
        let fbseRec = record(verInst: 0x2, recType: 0xF007, body: fbseBody)
        // A container (ver nibble 0xF) wrapping the FBSE.
        let container = record(verInst: 0xF, recType: 0xF001, body: fbseRec)
        let found = firstBlip(container[...], maxBytes: 1 << 20)
        #expect(found?.bytes == payload)
        #expect(fbseBlip(fbseBody[...], maxBytes: 1 << 20)?.bytes == payload)
        // No blip anywhere yields nil, boundedly.
        let empty = record(verInst: 0xF, recType: 0xF001, body: [])
        #expect(firstBlip(empty[...], maxBytes: 1 << 20) == nil)
    }
}
