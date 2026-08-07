/// OfficeArt (MS-ODRAW) blip extraction shared by the legacy binary
/// formats: DOC picture data (`PICF` + OfficeArt records in the Data
/// stream) and the PPT `Pictures` stream (a sequence of BStore file
/// blocks). Only the picture payloads are extracted; drawing geometry is
/// out of scope.

/// (verAndInstance, recType, body) of the OfficeArt record at `off` — the
/// same 8-byte header the PPT record stream uses. `off` is relative to the
/// start of `data`.
func recordAt(_ data: ArraySlice<UInt8>, _ off: Int) -> (verInst: UInt16, recType: UInt16, body: ArraySlice<UInt8>)? {
    guard off >= 0, off <= data.count else { return nil }
    let rest = data.dropFirst(off)
    guard rest.count >= 8 else { return nil }
    let i = rest.startIndex
    let verInst = UInt16(rest[i]) | UInt16(rest[i + 1]) << 8
    let recType = UInt16(rest[i + 2]) | UInt16(rest[i + 3]) << 8
    let len32 =
        UInt32(rest[i + 4]) | UInt32(rest[i + 5]) << 8 | UInt32(rest[i + 6]) << 16
        | UInt32(rest[i + 7]) << 24
    guard let len = Int(exactly: len32), rest.count - 8 >= len else { return nil }
    let body = rest.dropFirst(8).prefix(len)
    return (verInst, recType, body)
}

/// An extracted picture payload.
struct Blip {
    var mediaType: String
    var `extension`: String
    var bytes: [UInt8]
}

/// Decode one blip record (`recType` 0xF01A–0xF01F). Metafile blips may be
/// deflate-compressed; the output is bounded by the declared uncompressed
/// size, capped at `maxBytes`.
func decodeBlip(verInst: UInt16, recType: UInt16, body: ArraySlice<UInt8>, maxBytes: Int) -> Blip? {
    let instance = verInst >> 4
    switch recType {
    // Bitmap blips: rgbUid1 (16), + rgbUid2 (16) for the doubled
    // instance, then the picture bytes, with one tag byte first.
    case 0xF01D, 0xF01E:
        let doubled = instance == 0x46B || instance == 0x6E3 || instance == 0x6E1
        let start = (doubled ? 32 : 16) + 1
        guard body.count >= start else { return nil }
        let bytes = body.dropFirst(start)
        let (mediaType, ext) = recType == 0xF01D ? ("image/jpeg", "jpg") : ("image/png", "png")
        return Blip(mediaType: mediaType, extension: ext, bytes: Array(bytes))
    // Metafile blips: rgbUid (16/32), then a 34-byte metafile header
    // (cbSize, bounds, ptSize, cbSave, compression, filter).
    case 0xF01A, 0xF01B:
        let doubled = instance == 0x3D5 || instance == 0x217
        let header = doubled ? 32 : 16
        guard body.count >= header else { return nil }
        let headerAndData = body.dropFirst(header)
        guard headerAndData.count >= 4 else { return nil }
        let h = headerAndData.startIndex
        let cbSize =
            UInt32(headerAndData[h]) | UInt32(headerAndData[h + 1]) << 8
            | UInt32(headerAndData[h + 2]) << 16 | UInt32(headerAndData[h + 3]) << 24
        guard headerAndData.count > 32 else { return nil }
        let compression = headerAndData[h + 32]
        guard headerAndData.count >= 34 else { return nil }
        let data = headerAndData.dropFirst(34)
        let (mediaType, ext) = recType == 0xF01A ? ("image/emf", "emf") : ("image/wmf", "wmf")
        let bytes: [UInt8]
        switch compression {
        // 0x00 = deflate-compressed; 0xFE = uncompressed.
        case 0x00:
            let limit = min(Int(cbSize), maxBytes)
            guard let out = try? inflateRaw(data, maxOutput: limit) else { return nil }
            bytes = out.bytes
        default:
            bytes = Array(data)
        }
        return Blip(mediaType: mediaType, extension: ext, bytes: bytes)
    default:
        return nil
    }
}

/// Find and decode the first blip in a run of OfficeArt records (a
/// `Pictures` stream block sequence, or an inline shape container),
/// descending into containers. Bounded traversal: record counts and
/// nesting beyond any real drawing abort the search.
func firstBlip(_ data: ArraySlice<UInt8>, maxBytes: Int) -> Blip? {
    // (cursor, end) ranges into `data`.
    var stack: [(cursor: Int, end: Int)] = [(0, data.count)]
    var visited: UInt32 = 0
    while true {
        guard let (cursor, end) = stack.last else { return nil }
        if cursor >= end {
            stack.removeLast()
            continue
        }
        guard let (verInst, recType, body) = recordAt(data.prefix(end), cursor) else {
            stack.removeLast()
            continue
        }
        let bodyStart = cursor + 8
        let bodyEnd = bodyStart + body.count
        stack[stack.count - 1].cursor = bodyEnd
        visited += 1
        if visited > 10_000 || stack.count > 16 {
            return nil
        }
        if let blip = decodeBlip(verInst: verInst, recType: recType, body: body, maxBytes: maxBytes) {
            return blip
        }
        if recType == 0xF007 {
            let innerStart = bodyStart + (fbseBlipOffset(body) ?? body.count)
            if innerStart < bodyEnd {
                stack.append((innerStart, bodyEnd))
            }
            continue
        }
        if verInst & 0xF == 0xF {
            stack.append((bodyStart, bodyEnd))
        }
    }
}

/// Offset of the embedded blip record inside an FBSE (0xF007) body: the
/// 36-byte header plus the entry's name.
private func fbseBlipOffset(_ body: ArraySlice<UInt8>) -> Int? {
    guard body.count > 33 else { return nil }
    let cbName = Int(body[body.startIndex + 33])
    return 36 + cbName
}

/// Decode the blip embedded in an FBSE (0xF007) record body, if present.
func fbseBlip(_ body: ArraySlice<UInt8>, maxBytes: Int) -> Blip? {
    guard let offset = fbseBlipOffset(body),
        let (verInst, recType, blipBody) = recordAt(body, offset)
    else { return nil }
    return decodeBlip(verInst: verInst, recType: recType, body: blipBody, maxBytes: maxBytes)
}
