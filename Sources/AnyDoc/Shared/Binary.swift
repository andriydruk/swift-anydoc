/// Shared primitives for the legacy OLE2 binary formats (DOC, PPT):
/// checked little-endian integer readers and bounded compound-file stream
/// reading.

/// Little-endian `u16` at `off`; `nil` when out of bounds.
func getU16(_ b: [UInt8], _ off: Int) -> UInt16? {
    guard off >= 0, b.count - off >= 2 else { return nil }
    return UInt16(b[off]) | UInt16(b[off + 1]) << 8
}

/// Little-endian `u32` at `off`; `nil` when out of bounds.
func getU32(_ b: [UInt8], _ off: Int) -> UInt32? {
    guard off >= 0, b.count - off >= 4 else { return nil }
    return UInt32(b[off]) | UInt32(b[off + 1]) << 8 | UInt32(b[off + 2]) << 16
        | UInt32(b[off + 3]) << 24
}

/// Read a named stream from an OLE2 compound file. A missing stream is
/// `missingPart`; the read is hard-capped at `maxEntryBytes` so a corrupt
/// sector chain cannot expand without bound.
func readOleStream(_ ole: CompoundFile, _ name: String) throws -> [UInt8] {
    let bytes: [UInt8]
    do {
        guard let read = try ole.readStream([name], limit: Limits.maxEntryBytes + 1) else {
            throw ConvertError.missingPart(part: name)
        }
        bytes = read
    } catch let e as CfbError {
        throw ConvertError.malformedPart(name, "unreadable stream: \(e.message)")
    }
    if UInt64(bytes.count) > Limits.maxEntryBytes {
        throw ConvertError.resourceLimit(
            limit: "max_entry_bytes",
            detail: "\(name) stream exceeds the read cap")
    }
    return bytes
}

/// MS-OLEDS `\x01CompObj` metadata of an embedded OLE object payload: the
/// ANSI user type (display name) and ProgID, when the payload is a compound
/// file with a parsable CompObj stream.
///
/// PARITY: the Rust reference (v0.1.7) never reads CompObj — docx takes the
/// ProgID from the `o:OLEObject` attribute — so this follows MS-OLEDS 2.3.8
/// directly: a 28-byte CompObjHeader, then length-prefixed ANSI strings
/// (user type, clipboard format, ProgID). ANSI strings are in the producer's
/// ANSI code page, which the stream does not name; windows-1252 is the
/// interoperable default.
struct OleObjectInfo: Equatable {
    var userType: String?
    var progId: String?
}

/// CompObj metadata for OLE object bytes, or `nil` when the bytes are not a
/// compound file or carry no CompObj stream.
func oleObjectInfo(_ bytes: [UInt8]) -> OleObjectInfo? {
    guard let ole = try? CompoundFile(bytes: bytes),
        let compObj = ole.readStream(["\u{01}CompObj"])
    else { return nil }
    return parseCompObj(compObj)
}

/// Parse a CompObj stream. Fields are best-effort: a short or garbled stream
/// yields whatever fields precede the damage.
func parseCompObj(_ b: [UInt8]) -> OleObjectInfo {
    var info = OleObjectInfo()
    // CompObjHeader: reserved marker, version, and 20 reserved bytes.
    var off = 28
    guard let userType = readAnsiField(b, &off) else { return info }
    info.userType = userType
    // ClipboardFormatOrAnsiString: 0 = none; FFFFFFFF/FFFFFFFE = a standard
    // clipboard format id; anything else = the length of a format name.
    guard let marker = getU32(b, off) else { return info }
    off += 4
    if marker == 0xFFFF_FFFF || marker == 0xFFFF_FFFE {
        guard getU32(b, off) != nil else { return info }
        off += 4
    } else if marker != 0 {
        guard let len = Int(exactly: marker), b.count - off >= len else { return info }
        off += len
    }
    // Reserved1 holds the ProgID; a length of 0 or over 40 means the field
    // (and everything after it) must be ignored.
    guard let progIdLen = getU32(b, off) else { return info }
    off += 4
    guard progIdLen >= 1, progIdLen <= 40, let len = Int(exactly: progIdLen),
        b.count - off >= len
    else { return info }
    info.progId = ansiString(b[off..<off + len])
    return info
}

/// A LengthPrefixedAnsiString: 4-byte length, then that many bytes including
/// the terminating NUL. Advances `off` past the field; `nil` when the field
/// overruns the buffer.
private func readAnsiField(_ b: [UInt8], _ off: inout Int) -> String? {
    guard let lenRaw = getU32(b, off) else { return nil }
    guard let len = Int(exactly: lenRaw), b.count - off - 4 >= len else { return nil }
    off += 4
    let field = b[off..<off + len]
    off += len
    return ansiString(field)
}

/// Decode an ANSI string field: content runs to the first NUL.
private func ansiString(_ field: ArraySlice<UInt8>) -> String {
    decodeWindows1252(field.prefix(while: { $0 != 0 }))
}
