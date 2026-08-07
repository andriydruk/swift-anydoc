/// ZIP archive access with decompression limits.

/// A ZIP-based document package (OOXML, ODF, EPUB).
final class Package {
    private var zip: ZipArchive
    var totalRead: UInt64 = 0
    /// Decompressed parts by normalized name: repeated references are served
    /// from the cache instead of re-decompressing and re-charging the
    /// total-bytes budget (which would falsely trip on valid documents that
    /// reference one part many times). Bounded by `maxTotalBytes`. Buffers
    /// are copy-on-write, so a cache hit never copies the bytes.
    private var cache: [String: [UInt8]] = [:]

    private init(zip: ZipArchive) {
        self.zip = zip
    }

    static func open(_ bytes: [UInt8]) throws -> Package {
        let zip: ZipArchive
        do {
            zip = try ZipArchive(bytes)
        } catch let e as ZipError {
            throw ConvertError.malformed("not a readable zip archive: \(e.description)")
        }
        if zip.entryCount > Limits.maxEntryCount {
            throw ConvertError.resourceLimit(
                limit: "max_entry_count",
                detail: "archive contains \(zip.entryCount) entries")
        }
        return Package(zip: zip)
    }

    /// Read a part's bytes. `nil` means the part is absent (a valid state
    /// for optional parts); a thrown error means it exists but cannot be
    /// read. Callers apply the unified policy: skip + log when useful output
    /// remains, propagate when the part is the primary content.
    func part(_ name: String) throws -> [UInt8]? {
        // OPC part URIs may carry a leading slash; entries never do.
        let name = trimLeadingSlashes(name)
        if let bytes = cache[name] {
            return bytes
        }
        let file: ZipEntryReader
        do {
            file = try zip.openEntry(name)
        } catch ZipError.fileNotFound {
            return nil
        } catch let e as ZipError {
            throw ConvertError.malformed(
                part: name, detail: "unreadable archive entry: \(e.description)")
        }
        if file.size > Limits.maxEntryBytes {
            throw ConvertError.resourceLimit(
                limit: "max_entry_bytes",
                detail: "\(name) declares \(file.size) decompressed bytes")
        }
        // The declared size can lie; read through a hard-capped reader. The
        // cap is whichever budget has less room: the per-entry limit or what
        // remains of the whole-archive total.
        let remainingTotal = Limits.maxTotalBytes >= totalRead
            ? Limits.maxTotalBytes - totalRead : 0
        let cap = min(Limits.maxEntryBytes, remainingTotal)
        let bytes: [UInt8]
        do {
            bytes = try file.read(upTo: cap + 1)
        } catch let e as ZipEntryReadError {
            throw ConvertError.malformed(
                part: name, detail: "corrupt archive entry: \(e.message)")
        }
        let read = UInt64(bytes.count)
        if read > cap {
            throw remainingTotal < Limits.maxEntryBytes
                ? ConvertError.resourceLimit(
                    limit: "max_total_bytes",
                    detail: "\(name) exceeds the archive's remaining decompression budget")
                : ConvertError.resourceLimit(
                    limit: "max_entry_bytes",
                    detail: "\(name) exceeds the decompression cap")
        }
        totalRead += read
        cache[name] = bytes
        return bytes
    }

    /// True when a part exists, without reading (or budget-charging) it.
    func hasPart(_ name: String) -> Bool {
        zip.indexForName(trimLeadingSlashes(name)) != nil
    }

    /// Read a part that must exist for any meaningful output.
    func requiredPart(_ name: String) throws -> [UInt8] {
        guard let bytes = try part(name) else {
            throw ConvertError.missingPart(part: name)
        }
        return bytes
    }

    /// Read an optional part under the unified recovery policy: absent is a
    /// valid state (`nil`, silent); an unreadable part is skipped with a log
    /// (`nil`); fatal resource-limit errors always propagate.
    func optionalPart(_ name: String) throws -> [UInt8]? {
        do {
            return try part(name)
        } catch let e as ConvertError where !e.isFatal {
            Log.warn("skipping unreadable part \(name): \(e.message)")
            return nil
        }
    }

    /// Read and parse an optional XML part under the unified recovery policy:
    /// absent -> `nil`; unreadable or corrupt -> skipped with a log; fatal
    /// resource-limit errors always propagate.
    func optionalXmlPart(_ name: String) throws -> XmlElement? {
        guard let bytes = try optionalPart(name) else {
            return nil
        }
        do {
            return try parseXml(bytes)
        } catch let e as ConvertError where !e.isFatal {
            Log.warn("skipping corrupt part \(name): \(e.message)")
            return nil
        }
    }

    /// Read and parse an XML part that must exist and parse for any
    /// meaningful output.
    func requiredXmlPart(_ name: String) throws -> XmlElement {
        let bytes = try requiredPart(name)
        return try parseXml(bytes)
    }
}

private func trimLeadingSlashes(_ name: String) -> String {
    var view = Substring(name)
    while view.first == "/" {
        view = view.dropFirst()
    }
    return String(view)
}

/// A zip-open failure on OOXML input may actually be an OLE compound file:
/// an encrypted package, or a legacy binary document with the wrong
/// extension.
func probeOle(_ bytes: [UInt8]) -> ConvertError? {
    let oleMagic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    guard bytes.starts(with: oleMagic) else {
        return nil
    }
    if let file = try? CompoundFile(bytes: bytes),
        file.hasRootEntry("EncryptionInfo") || file.hasRootEntry("EncryptedPackage")
    {
        return .encrypted
    }
    return .malformed(
        "OLE compound document where an OOXML package was expected (legacy binary format?)")
}
