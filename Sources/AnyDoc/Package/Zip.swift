/// Raw ZIP format reader over an in-memory buffer: EOCD discovery (with the
/// ZIP64 locator/record), central directory parse, local-header validation,
/// and stored/deflate entry reads with CRC verification.
///
/// Shaped after the subset of the Rust `zip` crate (v8) anydoc relies on, so
/// behavior and error strings surface identically through the archive layer:
/// entries are indexed by raw name bytes (later duplicates replace earlier
/// content in place), the EOCD scan walks backwards over the whole buffer,
/// and every failure is a typed error — crafted input can never trap or hang.

/// Mirrors `zip::result::ZipError` for the variants this reader can produce;
/// `description` reproduces its `Display` output byte-for-byte.
enum ZipError: Error, CustomStringConvertible {
    case invalidArchive(String)
    case unsupportedArchive(String)
    case fileNotFound
    case compressionMethodNotSupported(UInt16)

    var description: String {
        switch self {
        case .invalidArchive(let msg): "invalid Zip archive: \(msg)"
        case .unsupportedArchive(let msg): "unsupported Zip archive: \(msg)"
        case .fileNotFound: "specified file not found in archive"
        case .compressionMethodNotSupported(let id): "compression method not supported: \(id)"
        }
    }
}

/// A failure while decompressing entry content — the `std::io::Error` shape
/// the Rust reader surfaces from `read_to_end`, message compatible.
struct ZipEntryReadError: Error {
    var message: String
}

/// One central-directory record, ZIP64 fields already resolved.
struct ZipEntry {
    var nameRaw: [UInt8]
    var flags: UInt16
    var method: UInt16
    var crc32: UInt32
    var compressedSize: UInt64
    var uncompressedSize: UInt64
    /// Local header offset, archive offset already applied.
    var headerStart: UInt64

    /// General purpose flag bit 0: the entry payload is encrypted
    /// (ZipCrypto or AES — both set the bit).
    var encrypted: Bool { flags & 0x0001 != 0 }
}

/// An entry located and validated for reading (the Rust `by_name` result).
struct ZipEntryReader {
    /// Declared decompressed size (`ZipFile::size`).
    let size: UInt64
    let method: UInt16
    let crc32: UInt32
    /// The entry's compressed payload within the archive buffer.
    let content: ArraySlice<UInt8>

    /// Mirror of `take(limit).read_to_end` through the CRC-checking
    /// decompressor: at most `limit` bytes come back; the CRC is verified
    /// only when the entry's stream ends within the limit, exactly as the
    /// Rust reader's `Crc32Reader` behaves under an outer `Take`.
    func read(upTo limit: UInt64) throws -> [UInt8] {
        if limit == 0 {
            return []
        }
        let cap = limit > UInt64(Int.max) ? Int.max : Int(limit)
        let bytes: [UInt8]
        var streamEnded: Bool
        switch method {
        case 0:
            if content.count > cap {
                bytes = Array(content[content.startIndex..<content.startIndex + cap])
                streamEnded = false
            } else {
                bytes = Array(content)
                streamEnded = true
            }
        case 8:
            let result: InflateResult
            do {
                result = try inflateRaw(content, maxOutput: cap)
            } catch {
                throw ZipEntryReadError(message: "corrupt deflate stream")
            }
            bytes = result.bytes
            streamEnded = !result.limitHit
        default:
            // Unreachable: openEntry rejects other methods.
            throw ZipEntryReadError(message: "compression method not supported: \(method)")
        }
        // When the stream ends exactly at the take limit, the outer take
        // returns 0 without querying the CRC reader again: no check.
        if bytes.count == cap {
            streamEnded = false
        }
        if streamEnded, zipCrc32(bytes[...]) != crc32 {
            throw ZipEntryReadError(message: "Invalid checksum")
        }
        return bytes
    }
}

struct ZipArchive {
    let bytes: [UInt8]
    /// Central-directory entries, first-seen order, deduplicated by raw name
    /// (a later duplicate replaces the earlier entry in place, keeping its
    /// position — IndexMap semantics).
    private(set) var entries: [ZipEntry] = []
    private var indexByName: [[UInt8]: Int] = [:]

    var entryCount: Int { entries.count }

    func indexForName(_ name: String) -> Int? {
        indexByName[Array(name.utf8)]
    }

    /// Locate an entry and validate it for reading, mirroring `by_name`:
    /// missing name, encryption, the local header, and the compression
    /// method are checked in that order.
    func openEntry(_ name: String) throws -> ZipEntryReader {
        guard let index = indexForName(name) else {
            throw ZipError.fileNotFound
        }
        let entry = entries[index]
        if entry.encrypted {
            throw ZipError.unsupportedArchive("Password required to decrypt file")
        }
        // find_content: parse the local header to locate the payload.
        let header = entry.headerStart
        guard header <= UInt64(bytes.count), UInt64(bytes.count) - header >= 30 else {
            throw ZipError.invalidArchive("Unexpected end of zip::types::ZipLocalEntryBlock")
        }
        let h = Int(header)
        guard readU32(at: h) == 0x0403_4B50 else {
            throw ZipError.invalidArchive("Invalid local file header")
        }
        let nameLen = UInt64(readU16(at: h + 26))
        let extraLen = UInt64(readU16(at: h + 28))
        let dataStart = header + 30 + nameLen + extraLen
        let end = UInt64(bytes.count)
        let start = min(dataStart, end)
        let take = min(entry.compressedSize, end - start)
        let content = bytes[Int(start)..<Int(start + take)]
        // make_crypto_reader: an unsupported method is rejected up front.
        guard entry.method == 0 || entry.method == 8 else {
            throw ZipError.compressionMethodNotSupported(entry.method)
        }
        return ZipEntryReader(
            size: entry.uncompressedSize, method: entry.method, crc32: entry.crc32,
            content: content)
    }

    // MARK: open

    init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        let fileLen = bytes.count
        var endExclusive = fileLen
        var lastErr: ZipError? = nil
        while true {
            let eocd: Eocd
            do {
                eocd = try Self.findCentralDirectory(bytes, endExclusive: endExclusive)
            } catch let e as ZipError {
                throw lastErr ?? e
            }
            do {
                let info = try Self.centralDirectoryInfo(eocd)
                let files = try Self.readCentralDirectory(bytes, info: info)
                for entry in files {
                    if let existing = indexByName[entry.nameRaw] {
                        entries[existing] = entry
                    } else {
                        indexByName[entry.nameRaw] = entries.count
                        entries.append(entry)
                    }
                }
                return
            } catch let e as ZipError {
                // Something went wrong reading this central directory; look
                // for an earlier EOCD candidate.
                lastErr = e
                endExclusive = eocd.offset
            }
        }
    }

    // MARK: EOCD discovery

    private struct Eocd {
        /// Offset of the EOCD signature.
        var offset: Int
        var numberOfFilesOnThisDisk: UInt16
        var diskNumber: UInt16
        var diskWithCentralDirectory: UInt16
        var centralDirectoryOffset: UInt32
        var zip64: Eocd64?
        var archiveOffset: UInt64
    }

    private struct Eocd64 {
        var diskNumber: UInt32
        var diskWithCentralDirectory: UInt32
        var numberOfFilesOnThisDisk: UInt64
        var numberOfFiles: UInt64
        var centralDirectoryOffset: UInt64
    }

    private static func findCentralDirectory(_ bytes: [UInt8], endExclusive: Int) throws -> Eocd {
        var parsingError: ZipError? = nil
        // Backwards scan for the EOCD signature over [0, endExclusive).
        var candidate = min(endExclusive, bytes.count) - 4
        while candidate >= 0 {
            defer { candidate -= 1 }
            guard u32(bytes, candidate) == 0x0605_4B50 else { continue }
            let eocdOffset = candidate

            // Zip32 EOCD block: 22 bytes including the signature.
            guard eocdOffset + 22 <= bytes.count else {
                if parsingError == nil {
                    parsingError = .invalidArchive("Unexpected end of zip::spec::Zip32CDEBlock")
                }
                continue
            }
            let diskNumber = u16(bytes, eocdOffset + 4)
            let diskWithCd = u16(bytes, eocdOffset + 6)
            let filesOnDisk = u16(bytes, eocdOffset + 8)
            let numberOfFiles = u16(bytes, eocdOffset + 10)
            let cdSize = u32(bytes, eocdOffset + 12)
            let cdOffset = u32(bytes, eocdOffset + 16)
            let commentLen = Int(u16(bytes, eocdOffset + 20))
            guard eocdOffset + 22 + commentLen <= bytes.count else {
                if parsingError == nil {
                    parsingError = .invalidArchive("EOCD comment exceeds file boundary")
                }
                continue
            }

            // A sentinel field means a ZIP64 locator may precede the EOCD.
            let mayBeZip64 =
                numberOfFiles == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF
            var locator: (offset: Int, diskWithCd: UInt32, eocd64Offset: UInt64, disks: UInt32)? =
                nil
            if mayBeZip64, eocdOffset >= 20, u32(bytes, eocdOffset - 20) == 0x0706_4B50 {
                locator = (
                    offset: eocdOffset - 20,
                    diskWithCd: u32(bytes, eocdOffset - 16),
                    eocd64Offset: u64(bytes, eocdOffset - 12),
                    disks: u32(bytes, eocdOffset - 4)
                )
            }

            guard let locator else {
                // Zip32 branch.
                let relativeCdOffset = UInt64(cdOffset)
                if numberOfFiles == 0 {
                    return Eocd(
                        offset: eocdOffset,
                        numberOfFilesOnThisDisk: filesOnDisk,
                        diskNumber: diskNumber,
                        diskWithCentralDirectory: diskWithCd,
                        centralDirectoryOffset: cdOffset,
                        zip64: nil,
                        archiveOffset: UInt64(eocdOffset) >= relativeCdOffset
                            ? UInt64(eocdOffset) - relativeCdOffset : 0)
                }
                // Consistency: the CD offset cannot be at/after the EOCD.
                if relativeCdOffset >= UInt64(eocdOffset) {
                    parsingError = .invalidArchive("Invalid CDFH offset in EOCD")
                    continue
                }
                // The first CDFH signature defines the archive offset
                // (prepended junk can only move it forward).
                if let cdStart = forwardFind(
                    bytes, sig: 0x0201_4B50, from: Int(relativeCdOffset), to: eocdOffset)
                {
                    return Eocd(
                        offset: eocdOffset,
                        numberOfFilesOnThisDisk: filesOnDisk,
                        diskNumber: diskNumber,
                        diskWithCentralDirectory: diskWithCd,
                        centralDirectoryOffset: cdOffset,
                        zip64: nil,
                        archiveOffset: UInt64(cdStart) - relativeCdOffset)
                }
                parsingError = .invalidArchive("No CDFH found")
                continue
            }

            // ZIP64 branch.
            if locator.eocd64Offset >= UInt64(locator.offset) {
                parsingError = .invalidArchive("Invalid EOCD64 Locator CD offset")
                continue
            }
            if locator.disks > 1 {
                parsingError = .invalidArchive("Multi-disk ZIP files are not supported")
                continue
            }
            var localError: ZipError? = nil
            var probe = Int(locator.eocd64Offset)
            while let eocd64Offset = forwardFind(
                bytes, sig: 0x0606_4B50, from: probe, to: locator.offset)
            {
                probe = eocd64Offset + 1
                let expectedLength = UInt64(locator.offset) - UInt64(eocd64Offset)
                do {
                    let eocd64 = try parseEocd64(
                        bytes, at: eocd64Offset, expectedLength: expectedLength,
                        locatorDiskWithCd: locator.diskWithCd)
                    // Consistency: the CD and its headers must fit below.
                    let headersBytes = eocd64.numberOfFiles > UInt64.max / 46
                        ? UInt64.max : eocd64.numberOfFiles * 46
                    let need = headersBytes.saturatingAdding(eocd64.centralDirectoryOffset)
                    if UInt64(eocd64Offset) < need {
                        localError = .invalidArchive("Invalid EOCD64: inconsistent number of files")
                        continue
                    }
                    return Eocd(
                        offset: eocdOffset,
                        numberOfFilesOnThisDisk: filesOnDisk,
                        diskNumber: diskNumber,
                        diskWithCentralDirectory: diskWithCd,
                        centralDirectoryOffset: cdOffset,
                        zip64: eocd64,
                        archiveOffset: UInt64(eocd64Offset) - locator.eocd64Offset)
                } catch let e as ZipError {
                    localError = e
                }
            }
            parsingError = localError ?? .invalidArchive("Could not find EOCD64")
        }
        throw parsingError ?? ZipError.invalidArchive("Could not find EOCD")
    }

    private static func parseEocd64(
        _ bytes: [UInt8], at offset: Int, expectedLength: UInt64, locatorDiskWithCd: UInt32
    ) throws -> Eocd64 {
        guard offset + 56 <= bytes.count else {
            throw ZipError.invalidArchive("Unexpected end of zip::spec::Zip64CDEBlock")
        }
        let recordSize = u64(bytes, offset + 4)
        let diskNumber = u32(bytes, offset + 16)
        let diskWithCd = u32(bytes, offset + 20)
        let filesOnDisk = u64(bytes, offset + 24)
        let numberOfFiles = u64(bytes, offset + 32)
        let cdOffset = u64(bytes, offset + 48)
        if recordSize < 40 {
            throw ZipError.invalidArchive("Low EOCD64 record size")
        }
        if recordSize.saturatingAdding(12) > expectedLength {
            throw ZipError.invalidArchive("EOCD64 extends beyond EOCD64 locator")
        }
        // The extensible data sector fills the record beyond its fixed part.
        if recordSize > 44 {
            let extensible = recordSize - 44
            if UInt64(offset) + 56 + extensible > UInt64(bytes.count) {
                throw ZipError.invalidArchive("EOCD64 extensible data sector exceeds file boundary")
            }
        }
        if diskWithCd != locatorDiskWithCd {
            throw ZipError.invalidArchive("Invalid EOCD64: inconsistency with Locator data")
        }
        if recordSize.saturatingAdding(12) != expectedLength {
            throw ZipError.invalidArchive("Invalid EOCD64: inconsistent length")
        }
        return Eocd64(
            diskNumber: diskNumber,
            diskWithCentralDirectory: diskWithCd,
            numberOfFilesOnThisDisk: filesOnDisk,
            numberOfFiles: numberOfFiles,
            centralDirectoryOffset: cdOffset)
    }

    // MARK: central directory

    private struct CentralDirectoryInfo {
        var archiveOffset: UInt64
        var directoryStart: UInt64
        var numberOfFiles: UInt64
        var diskNumber: UInt32
        var diskWithCentralDirectory: UInt32
    }

    private static func centralDirectoryInfo(_ eocd: Eocd) throws -> CentralDirectoryInfo {
        let relativeCdOffset: UInt64
        let numberOfFiles: UInt64
        let diskNumber: UInt32
        let diskWithCd: UInt32
        if let z64 = eocd.zip64 {
            if z64.numberOfFilesOnThisDisk > z64.numberOfFiles {
                throw ZipError.invalidArchive(
                    "ZIP64 footer indicates more files on this disk than in the whole archive")
            }
            relativeCdOffset = z64.centralDirectoryOffset
            numberOfFiles = z64.numberOfFiles
            diskNumber = z64.diskNumber
            diskWithCd = z64.diskWithCentralDirectory
        } else {
            relativeCdOffset = UInt64(eocd.centralDirectoryOffset)
            numberOfFiles = UInt64(eocd.numberOfFilesOnThisDisk)
            diskNumber = UInt32(eocd.diskNumber)
            diskWithCd = UInt32(eocd.diskWithCentralDirectory)
        }
        let (directoryStart, overflow) = relativeCdOffset.addingReportingOverflow(
            eocd.archiveOffset)
        if overflow {
            throw ZipError.invalidArchive("Invalid central directory size or offset")
        }
        return CentralDirectoryInfo(
            archiveOffset: eocd.archiveOffset,
            directoryStart: directoryStart,
            numberOfFiles: numberOfFiles,
            diskNumber: diskNumber,
            diskWithCentralDirectory: diskWithCd)
    }

    private static func readCentralDirectory(
        _ bytes: [UInt8], info: CentralDirectoryInfo
    ) throws -> [ZipEntry] {
        if info.diskNumber != info.diskWithCentralDirectory {
            throw ZipError.unsupportedArchive("Support for multi-disk files is not implemented")
        }
        var entries: [ZipEntry] = []
        var pos = info.directoryStart
        var i: UInt64 = 0
        // A lying file count is bounded by the buffer: each record consumes
        // at least 46 bytes, so the parse below fails before it can spin.
        while i < info.numberOfFiles {
            i += 1
            let entry = try parseCentralEntry(bytes, at: pos, archiveOffset: info.archiveOffset)
            pos = entry.nextPos
            entries.append(entry.entry)
        }
        return entries
    }

    private static func parseCentralEntry(
        _ bytes: [UInt8], at pos: UInt64, archiveOffset: UInt64
    ) throws -> (entry: ZipEntry, nextPos: UInt64) {
        guard pos <= UInt64(bytes.count), UInt64(bytes.count) - pos >= 46 else {
            throw ZipError.invalidArchive("Unexpected end of zip::types::ZipCentralEntryBlock")
        }
        let p = Int(pos)
        guard u32(bytes, p) == 0x0201_4B50 else {
            throw ZipError.invalidArchive("Invalid Central Directory header")
        }
        let flags = u16(bytes, p + 8)
        let method = u16(bytes, p + 10)
        let crc32 = u32(bytes, p + 16)
        var compressedSize = UInt64(u32(bytes, p + 20))
        var uncompressedSize = UInt64(u32(bytes, p + 24))
        let nameLen = Int(u16(bytes, p + 28))
        let extraLen = Int(u16(bytes, p + 30))
        let commentLen = Int(u16(bytes, p + 32))
        var headerStart = UInt64(u32(bytes, p + 42))

        let varStart = pos + 46
        let varLen = UInt64(nameLen) + UInt64(extraLen) + UInt64(commentLen)
        guard varStart <= UInt64(bytes.count), UInt64(bytes.count) - varStart >= varLen else {
            throw ZipError.invalidArchive("Variable-length field extends beyond file boundary")
        }
        let nameRaw = Array(bytes[Int(varStart)..<Int(varStart) + nameLen])
        let extra = bytes[Int(varStart) + nameLen..<Int(varStart) + nameLen + extraLen]

        try parseExtraField(
            extra, uncompressedSize: &uncompressedSize, compressedSize: &compressedSize,
            headerStart: &headerStart)

        let (adjusted, overflow) = headerStart.addingReportingOverflow(archiveOffset)
        if overflow {
            throw ZipError.invalidArchive("Archive header is too large")
        }
        let entry = ZipEntry(
            nameRaw: nameRaw, flags: flags, method: method, crc32: crc32,
            compressedSize: compressedSize, uncompressedSize: uncompressedSize,
            headerStart: adjusted)
        return (entry, varStart + varLen)
    }

    /// Walk the entry's extra field for the ZIP64 extended-information field
    /// (0x0001), which overrides the 32-bit sentinel sizes and offset. Other
    /// fields are skipped by their declared length.
    // PARITY: the Rust reader also decodes NTFS/timestamp/Unicode-name/AES
    // fields and validates their contents; only their malformed-content
    // errors (never hit by the corpus) and Unicode name overrides differ.
    private static func parseExtraField(
        _ extra: ArraySlice<UInt8>,
        uncompressedSize: inout UInt64,
        compressedSize: inout UInt64,
        headerStart: inout UInt64
    ) throws {
        let knownFields: Set<UInt16> = [0x0001, 0x000A, 0x5455, 0x6375, 0x7075, 0x9901, 0xA11E]
        var pos = extra.startIndex
        let end = extra.endIndex
        while pos < end {
            guard end - pos >= 2 else { return }
            let kind = UInt16(extra[pos]) | UInt16(extra[pos + 1]) << 8
            pos += 2
            guard end - pos >= 2 else {
                if knownFields.contains(kind) {
                    throw ZipError.invalidArchive(
                        "Extra field 0x\(hex4(kind)) header truncated")
                }
                return  // most likely padding
            }
            let len = Int(UInt16(extra[pos]) | UInt16(extra[pos + 1]) << 8)
            pos += 2
            if kind == 0x0001 {
                var consumed = 0
                // Each 64-bit field is present when the block is full-sized
                // or its 32-bit counterpart carries the sentinel.
                func take64() throws -> UInt64 {
                    guard end - pos >= 8 else {
                        throw ZipError.invalidArchive("ZIP64 extra field truncated")
                    }
                    let value = u64slice(extra, pos)
                    pos += 8
                    consumed += 8
                    return value
                }
                if len >= 24 || uncompressedSize == 0xFFFF_FFFF {
                    uncompressedSize = try take64()
                }
                if len >= 24 || compressedSize == 0xFFFF_FFFF {
                    compressedSize = try take64()
                }
                if len >= 24 || headerStart == 0xFFFF_FFFF {
                    headerStart = try take64()
                }
                guard len >= consumed else {
                    throw ZipError.invalidArchive("ZIP64 extra-data field is the wrong length")
                }
                // Leftover bytes are drained without a length check (the
                // Rust reader copies to a sink, which simply ends at EOF).
                pos = min(pos + (len - consumed), end)
            } else {
                guard end - pos >= len else {
                    throw ZipError.invalidArchive("Extra field content truncated")
                }
                pos += len
            }
        }
    }

    // MARK: byte access

    private func readU16(at index: Int) -> UInt16 { u16(bytes, index) }
    private func readU32(at index: Int) -> UInt32 { u32(bytes, index) }
}

/// First occurrence of a 4-byte little-endian signature within `[from, to)`.
private func forwardFind(_ bytes: [UInt8], sig: UInt32, from: Int, to: Int) -> Int? {
    guard from >= 0 else { return nil }
    var i = from
    let end = min(to, bytes.count)
    while i + 4 <= end {
        if u32(bytes, i) == sig {
            return i
        }
        i += 1
    }
    return nil
}

private func u16(_ bytes: [UInt8], _ i: Int) -> UInt16 {
    UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
}

private func u32(_ bytes: [UInt8], _ i: Int) -> UInt32 {
    UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16
        | UInt32(bytes[i + 3]) << 24
}

private func u64(_ bytes: [UInt8], _ i: Int) -> UInt64 {
    UInt64(u32(bytes, i)) | UInt64(u32(bytes, i + 4)) << 32
}

private func u64slice(_ bytes: ArraySlice<UInt8>, _ i: Int) -> UInt64 {
    var value: UInt64 = 0
    for k in 0..<8 {
        value |= UInt64(bytes[i + k]) << (8 * k)
    }
    return value
}

private func hex4(_ value: UInt16) -> String {
    let digits = Array("0123456789ABCDEF")
    var out = ""
    for shift in stride(from: 12, through: 0, by: -4) {
        out.append(digits[Int((value >> UInt16(shift)) & 0xF)])
    }
    return out
}

// MARK: CRC-32

/// CRC-32 (IEEE, reflected, polynomial 0xEDB88320) as ZIP entries store it.
func zipCrc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
}

private let crc32Table: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        table[i] = c
    }
    return table
}()
