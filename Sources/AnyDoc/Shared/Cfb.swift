/// Minimal MS-CFB (OLE2 Compound File Binary) reader: directory listing and
/// stream reads. Serves OLE detection, embedded-object metadata (docx), and
/// the legacy doc/ppt/xls containers.
///
/// Mirrors the `cfb` crate (0.14.0) opened with permissive validation — the
/// mode anydoc uses — including its `io::Error` message texts: frontends embed
/// them verbatim ("not an OLE2 compound file: {e}"), and the truncated-doc
/// golden pins one of them byte-for-byte.
///
/// - `init` validates the CFB header (signature D0 CF 11 E0 A1 B1 1A E1,
///   version 3/4 sector shifts 9/12, mini cutoff 4096), the FAT/DIFAT, the
///   directory tree, and the mini-FAT, and throws `ConvertError.malformed`
///   otherwise.
/// - Stream name matching follows the cfb crate: shortlex over UTF-16 units,
///   compared case-insensitively (CFB names are case-insensitive per MS-CFB's
///   upper-case comparison rule).
/// - Bounded: the FAT proves every sector is pointed to at most once, so
///   chain walks terminate; directory walks carry a visited set; every loop
///   is capped by counts derived from the file size. Crafted files throw,
///   never spin.
struct CompoundFile {
    private let bytes: [UInt8]
    private let sectorLen: Int
    private let numSectors: UInt32
    private let fat: [UInt32]
    private let miniFat: [UInt32]
    private let entries: [CfbDirEntry]

    init(bytes: [UInt8]) throws {
        do {
            self = try CompoundFile.parse(bytes)
        } catch let e as CfbError {
            throw ConvertError.malformed(e.message)
        }
    }

    private init(
        bytes: [UInt8], sectorLen: Int, numSectors: UInt32, fat: [UInt32], miniFat: [UInt32],
        entries: [CfbDirEntry]
    ) {
        self.bytes = bytes
        self.sectorLen = sectorLen
        self.numSectors = numSectors
        self.fat = fat
        self.miniFat = miniFat
        self.entries = entries
    }

    /// Names of the directory entries directly under the root storage, in the
    /// cfb crate's `read_root_storage` order: an in-order traversal of the
    /// sibling tree, which is CFB name order (shortlex, case-insensitive).
    var rootEntryNames: [String] {
        var out: [String] = []
        var stack: [UInt32] = []
        var current = entries.first?.child ?? cfbNoStream
        // The tree is loop-free after validation; the cap is belt and braces.
        var steps = 0
        let maxSteps = entries.count * 2 + 4
        while current != cfbNoStream || !stack.isEmpty {
            steps += 1
            if steps > maxSteps { break }
            if current != cfbNoStream {
                guard Int(current) < entries.count else { break }
                stack.append(current)
                current = entries[Int(current)].left
            } else if let top = stack.popLast() {
                out.append(entries[Int(top)].name)
                current = entries[Int(top)].right
            }
        }
        return out
    }

    /// True when a stream or storage with this name exists directly under
    /// root (case-insensitive per MS-CFB).
    func hasRootEntry(_ name: String) -> Bool {
        lookup([name]) != nil
    }

    /// The full bytes of a stream at the given path from root, or `nil` when
    /// absent, not a stream, or unreadable. Path components are
    /// storage/stream names.
    func readStream(_ path: [String]) -> [UInt8]? {
        ((try? readStream(path, limit: .max)) ?? nil)
    }

    /// The cfb crate's `open_stream(path)` + `take(limit)` + `read_to_end`:
    /// `nil` when no stream object exists at `path` (the crate's
    /// NotFound/"Not a stream" errors, which callers map to a missing part);
    /// throws `CfbError` when the stream exists but its sector chain or the
    /// underlying bytes are unreadable.
    func readStream(_ path: [String], limit: UInt64) throws -> [UInt8]? {
        guard let id = lookup(path), Int(id) < entries.count else { return nil }
        let entry = entries[Int(id)]
        guard entry.objType == .stream else { return nil }
        let needed64 = min(entry.streamLen, limit)
        guard let needed = Int(exactly: needed64) else {
            throw CfbError("failed to fill whole buffer")
        }
        if needed == 0 { return [] }
        var out: [UInt8] = []
        // Mini vs regular is decided by the declared stream length alone,
        // exactly as the crate does.
        if entry.streamLen < UInt64(cfbMiniStreamCutoff) {
            let miniIds = try miniChainSectors(start: entry.startSector)
            let rootStart = entries.first?.startSector ?? cfbEndOfChain
            let rootChain = try chainSectors(start: rootStart)
            for mini in miniIds {
                let byteOffset = Int(mini) * cfbMiniSectorLen
                let sectorIndex = byteOffset / sectorLen
                let offsetInSector = byteOffset % sectorLen
                guard sectorIndex < rootChain.count else {
                    throw CfbError("invalid sector id")
                }
                let data = sectorData(rootChain[sectorIndex])
                let piece = data.dropFirst(offsetInSector).prefix(cfbMiniSectorLen)
                let take = min(cfbMiniSectorLen, needed - out.count)
                guard piece.count >= take else {
                    throw CfbError("failed to fill whole buffer")
                }
                out.append(contentsOf: piece.prefix(take))
                if out.count >= needed { return out }
            }
        } else {
            let chain = try chainSectors(start: entry.startSector)
            for sid in chain {
                let data = sectorData(sid)
                let take = min(sectorLen, needed - out.count)
                guard data.count >= take else {
                    throw CfbError("failed to fill whole buffer")
                }
                out.append(contentsOf: data.prefix(take))
                if out.count >= needed { return out }
            }
        }
        throw CfbError("failed to fill whole buffer")
    }

    /// The crate's `stream_id_for_name_chain`: descend the sibling tree by
    /// CFB name comparison from the root, one path component at a time.
    private func lookup(_ names: [String]) -> UInt32? {
        var streamId: UInt32 = 0
        guard !entries.isEmpty else { return nil }
        for name in names {
            var current = entries[Int(streamId)].child
            // The validated tree is finite and loop-free; cap defensively.
            var steps = 0
            while true {
                steps += 1
                if steps > entries.count + 1 { return nil }
                if current == cfbNoStream { return nil }
                guard Int(current) < entries.count else { return nil }
                let e = entries[Int(current)]
                let order = cfbCompareNames(name, e.name)
                if order == 0 {
                    streamId = current
                    break
                }
                current = order < 0 ? e.left : e.right
            }
        }
        return streamId
    }

    private func sectorData(_ id: UInt32) -> ArraySlice<UInt8> {
        let start = (Int(id) + 1) * sectorLen
        guard start < bytes.count else { return bytes[bytes.count...] }
        return bytes[start..<min(start + sectorLen, bytes.count)]
    }

    /// The crate's `Allocator::next`.
    private func fatNext(_ sectorId: UInt32) throws -> UInt32 {
        try CompoundFile.fatNext(sectorId, fat: fat)
    }

    private static func fatNext(_ sectorId: UInt32, fat: [UInt32]) throws -> UInt32 {
        let index = Int(sectorId)
        guard index < fat.count else {
            throw CfbError("Found reference to sector \(sectorId), but FAT has only \(fat.count) entries")
        }
        let nextId = fat[index]
        if nextId != cfbEndOfChain, nextId > cfbMaxRegularSector || Int(nextId) >= fat.count {
            throw CfbError("next_id (\(nextId)) is invalid")
        }
        return nextId
    }

    /// The crate's `MiniAllocator::next_mini_sector`.
    private func miniFatNext(_ sectorId: UInt32) throws -> UInt32 {
        let index = Int(sectorId)
        guard index < miniFat.count else {
            throw CfbError(
                "Found reference to mini sector \(sectorId), but MiniFAT has only \(miniFat.count) entries")
        }
        let nextId = miniFat[index]
        if nextId != cfbEndOfChain, nextId > cfbMaxRegularSector || Int(nextId) >= miniFat.count {
            throw CfbError("next_id (\(nextId)) is invalid")
        }
        return nextId
    }

    /// The crate's `Chain::new`: walk a FAT chain eagerly, failing on any
    /// invalid link or a cycle back to the first sector. FAT validation
    /// already proved no sector is pointed to twice, so every other cycle
    /// shape is impossible.
    private func chainSectors(start: UInt32) throws -> [UInt32] {
        var sectorIds: [UInt32] = []
        var current = start
        while current != cfbEndOfChain {
            sectorIds.append(current)
            current = try fatNext(current)
            if current == start {
                throw CfbError("Chain contained duplicate sector id \(current)")
            }
            if sectorIds.count > fat.count {
                throw CfbError("Chain contained duplicate sector id \(current)")
            }
        }
        return sectorIds
    }

    /// The crate's `MiniChain::new`.
    private func miniChainSectors(start: UInt32) throws -> [UInt32] {
        var sectorIds: [UInt32] = []
        var current = start
        while current != cfbEndOfChain {
            sectorIds.append(current)
            current = try miniFatNext(current)
            if current == start {
                throw CfbError("Minichain contained duplicate sector id \(current)")
            }
            if sectorIds.count > miniFat.count {
                throw CfbError("Minichain contained duplicate sector id \(current)")
            }
        }
        return sectorIds
    }

    // MARK: - Opening

    private static func parse(_ bytes: [UInt8]) throws -> CompoundFile {
        if bytes.count < 512 {
            throw CfbError("Invalid CFB file (\(bytes.count) bytes is too small)")
        }
        var header = ByteReader(bytes[...])
        let magic = try header.take(8)
        if !magic.elementsEqual(cfbMagic) {
            let listed = magic.map { String($0, radix: 16) }.joined(separator: ", ")
            throw CfbError("Invalid CFB file (wrong magic number): [\(listed)]")
        }
        try header.skip(16)  // reserved (CLSID)
        _ = try header.u16()  // minor version
        let versionNumber = try header.u16()
        let byteOrderMark = try header.u16()
        if byteOrderMark != 0xFFFE {
            throw CfbError(
                "Invalid CFB byte order mark (expected 0xFFFE, found 0x\(hex(byteOrderMark, width: 4)))")
        }
        guard versionNumber == 3 || versionNumber == 4 else {
            throw CfbError("CFB version \(versionNumber) is not supported")
        }
        let expectedShift: UInt16 = versionNumber == 3 ? 9 : 12
        let sectorShift = try header.u16()
        if sectorShift != expectedShift {
            throw CfbError(
                "Incorrect sector shift for CFB version \(versionNumber) (expected \(expectedShift), found \(sectorShift))")
        }
        let sectorLen = 1 << Int(expectedShift)
        let miniSectorShift = try header.u16()
        if miniSectorShift != 6 {
            throw CfbError("Incorrect mini sector shift (expected 6, found \(miniSectorShift))")
        }
        try header.skip(6)  // reserved
        _ = try header.u32()  // num dir sectors (V3: forced zero; V4 strict only)
        let numFatSectors = try header.u32()
        let firstDirSector = try header.u32()
        _ = try header.u32()  // transaction signature
        let miniStreamCutoff = try header.u32()
        if miniStreamCutoff != 4096 {
            throw CfbError("Incorrect mini stream cutoff (expected 4096, found \(miniStreamCutoff))")
        }
        let firstMiniFatSector = try header.u32()
        _ = try header.u32()  // num mini-FAT sectors (strict only)
        var firstDifatSector = try header.u32()
        _ = try header.u32()  // num DIFAT sectors (strict only)
        // Some CFB implementations use FREE_SECTOR to indicate END_OF_CHAIN.
        if firstDifatSector == cfbFreeSector { firstDifatSector = cfbEndOfChain }
        var difat: [UInt32] = []
        for _ in 0..<109 {
            let next = try header.u32()
            if next == cfbFreeSector { break }
            if next > cfbMaxRegularSector {
                throw CfbError("Initial DIFAT array refers to invalid sector index 0x\(hex(next, width: 8))")
            }
            difat.append(next)
        }

        let fileLen = UInt64(bytes.count)
        if fileLen > (UInt64(cfbMaxRegularSector) + 1) * UInt64(sectorLen) {
            throw CfbError("Invalid CFB file (\(fileLen) bytes is too large)")
        }
        if fileLen < UInt64(sectorLen) {
            throw CfbError("Invalid CFB file (length of \(fileLen) < sector length of \(sectorLen))")
        }
        let numSectors = UInt32((fileLen + UInt64(sectorLen) - 1) / UInt64(sectorLen) - 1)

        func sector(_ id: UInt32) -> ArraySlice<UInt8> {
            let start = (Int(id) + 1) * sectorLen
            guard start < bytes.count else { return bytes[bytes.count...] }
            return bytes[start..<min(start + sectorLen, bytes.count)]
        }

        // Read in DIFAT.
        var difatSectorIds: [UInt32] = []
        var seenDifatSectors: Set<UInt32> = []
        var currentDifatSector = firstDifatSector
        while currentDifatSector != cfbEndOfChain && currentDifatSector != cfbFreeSector {
            if currentDifatSector > cfbMaxRegularSector {
                throw CfbError("DIFAT chain includes invalid sector index \(currentDifatSector)")
            }
            if currentDifatSector >= numSectors {
                throw CfbError(
                    "DIFAT chain includes sector index \(currentDifatSector), but sector count is only \(numSectors)")
            }
            if !seenDifatSectors.insert(currentDifatSector).inserted {
                throw CfbError("DIFAT chain includes duplicate sector index \(currentDifatSector)")
            }
            difatSectorIds.append(currentDifatSector)
            var reader = ByteReader(sector(currentDifatSector))
            for _ in 0..<(sectorLen / 4 - 1) {
                let next = try reader.u32()
                if next != cfbFreeSector && next > cfbMaxRegularSector {
                    throw CfbError("DIFAT refers to invalid sector index \(next)")
                }
                difat.append(next)
            }
            currentDifatSector = try reader.u32()
        }
        // The DIFAT should be padded with FREE_SECTOR, but DIFAT sectors may
        // instead be incorrectly zero padded. In case num_fat_sectors is not
        // reliable, only remove zeroes, and never from the header DIFAT.
        while difat.count > 109, difat.count > Int(numFatSectors), difat.last == 0 {
            difat.removeLast()
        }
        while difat.last == cfbFreeSector {
            difat.removeLast()
        }

        // Read in FAT.
        var fat: [UInt32] = []
        for sectorIndex in difat {
            if sectorIndex >= numSectors {
                throw CfbError("DIFAT refers to sector \(sectorIndex), but sector count is only \(numSectors)")
            }
            var reader = ByteReader(sector(sectorIndex))
            for _ in 0..<(sectorLen / 4) {
                fat.append(try reader.u32())
            }
        }
        // The last FAT sector must be padded with FREE_SECTOR, but some
        // implementations pad with zeros (or other special values); strip
        // only entries beyond the number of sectors in the file.
        while fat.count > Int(numSectors),
            fat.last == 0 || fat.last == cfbDifatSector || fat.last == cfbFatSector
                || fat.last == cfbFreeSector
        {
            fat.removeLast()
        }
        while fat.count > Int(numSectors), fat.last == cfbFreeSector {
            fat.removeLast()
        }
        while fat.count < Int(numSectors) {
            fat.append(cfbFreeSector)
        }

        // The crate's Allocator validation.
        if fat.count > Int(numSectors) {
            throw CfbError("Malformed FAT (FAT has \(fat.count) entries, but file has only \(numSectors) sectors)")
        }
        for difatSector in difatSectorIds {
            guard Int(difatSector) < fat.count else {
                throw CfbError(
                    "Malformed FAT (FAT has \(fat.count) entries, but DIFAT lists \(difatSector) as a DIFAT sector)")
            }
            fat[Int(difatSector)] = cfbDifatSector
        }
        for fatSector in difat {
            guard Int(fatSector) < fat.count else {
                throw CfbError(
                    "Malformed FAT (FAT has \(fat.count) entries, but DIFAT lists \(fatSector) as a FAT sector)")
            }
            fat[Int(fatSector)] = cfbFatSector
        }
        var pointees: Set<UInt32> = []
        for (fromSector, toSector) in fat.enumerated() {
            if toSector <= cfbMaxRegularSector {
                if Int(toSector) >= fat.count {
                    throw CfbError(
                        "Malformed FAT (FAT has \(fat.count) entries, but sector \(fromSector) points to \(toSector))")
                }
                if !pointees.insert(toSector).inserted {
                    throw CfbError("Malformed FAT (sector \(toSector) pointed to twice)")
                }
            } else if toSector == cfbInvalidSector {
                throw CfbError("Malformed FAT (0x\(hex(toSector, width: 8)) is not a valid FAT entry)")
            }
        }

        // Read in directory.
        var dirEntries: [CfbDirEntry] = []
        var seenDirSectors: Set<UInt32> = []
        var currentDirSector = firstDirSector
        while currentDirSector != cfbEndOfChain {
            if currentDirSector > cfbMaxRegularSector {
                throw CfbError("Directory chain includes invalid sector index \(currentDirSector)")
            }
            if currentDirSector >= numSectors {
                throw CfbError(
                    "Directory chain includes sector index \(currentDirSector), but sector count is only \(numSectors)")
            }
            if !seenDirSectors.insert(currentDirSector).inserted {
                throw CfbError("Directory chain includes duplicate sector index \(currentDirSector)")
            }
            var reader = ByteReader(sector(currentDirSector))
            for _ in 0..<(sectorLen / 128) {
                dirEntries.append(try parseDirEntry(&reader, v3: versionNumber == 3))
            }
            currentDirSector = try fatNext(currentDirSector, fat: fat)
        }

        // The crate's Directory validation.
        guard let root = dirEntries.first else {
            throw CfbError("Malformed directory (root entry is missing)")
        }
        if root.streamLen % UInt64(cfbMiniSectorLen) != 0 {
            throw CfbError(
                "Malformed directory (root stream len is \(root.streamLen), but should be multiple of \(cfbMiniSectorLen))")
        }
        var visited: Set<UInt32> = []
        var stack: [UInt32] = [0]
        while let streamId = stack.popLast() {
            if !visited.insert(streamId).inserted {
                throw CfbError("Malformed directory (loop in tree)")
            }
            let dirEntry = dirEntries[Int(streamId)]
            if streamId == 0 {
                if dirEntry.objType != .root {
                    throw CfbError("Malformed directory (root entry has object type \(dirEntry.objType.debugName))")
                }
            } else if dirEntry.objType != .storage && dirEntry.objType != .stream {
                throw CfbError("Malformed directory (non-root entry with object type \(dirEntry.objType.debugName))")
            }
            if dirEntry.left != cfbNoStream {
                guard Int(dirEntry.left) < dirEntries.count else {
                    throw CfbError(
                        "Malformed directory (left sibling index is \(dirEntry.left), but directory entry count is \(dirEntries.count))")
                }
                let entry = dirEntries[Int(dirEntry.left)]
                if cfbCompareNames(entry.name, dirEntry.name) >= 0 {
                    throw CfbError(
                        "Malformed directory (name ordering, \(rustDebugString(dirEntry.name)) vs \(rustDebugString(entry.name)))")
                }
                stack.append(dirEntry.left)
            }
            if dirEntry.right != cfbNoStream {
                guard Int(dirEntry.right) < dirEntries.count else {
                    throw CfbError(
                        "Malformed directory (right sibling index is \(dirEntry.right), but directory entry count is \(dirEntries.count))")
                }
                let entry = dirEntries[Int(dirEntry.right)]
                if cfbCompareNames(dirEntry.name, entry.name) >= 0 {
                    throw CfbError(
                        "Malformed directory (name ordering, \(rustDebugString(dirEntry.name)) vs \(rustDebugString(entry.name)))")
                }
                stack.append(dirEntry.right)
            }
            if dirEntry.child != cfbNoStream {
                guard Int(dirEntry.child) < dirEntries.count else {
                    throw CfbError(
                        "Malformed directory (child index is \(dirEntry.child), but directory entry count is \(dirEntries.count))")
                }
                stack.append(dirEntry.child)
            }
        }

        // Read in MiniFAT.
        var miniFat: [UInt32] = []
        do {
            var chain: [UInt32] = []
            var current = firstMiniFatSector
            while current != cfbEndOfChain {
                chain.append(current)
                current = try fatNext(current, fat: fat)
                if current == firstMiniFatSector || chain.count > fat.count {
                    throw CfbError("Chain contained duplicate sector id \(current)")
                }
            }
            for sid in chain {
                var reader = ByteReader(sector(sid))
                for _ in 0..<(sectorLen / 4) {
                    miniFat.append(try reader.u32())
                }
            }
            while miniFat.last == cfbFreeSector {
                miniFat.removeLast()
            }
        }

        // The crate's MiniAllocator validation.
        let rootStreamMiniSectors = root.streamLen / UInt64(cfbMiniSectorLen)
        if rootStreamMiniSectors < UInt64(miniFat.count) {
            miniFat.removeLast(miniFat.count - Int(rootStreamMiniSectors))
        }
        var miniPointees: Set<UInt32> = []
        for (fromMiniSector, toMiniSector) in miniFat.enumerated() {
            if toMiniSector <= cfbMaxRegularSector {
                if Int(toMiniSector) >= miniFat.count {
                    throw CfbError(
                        "Malformed MiniFAT (MiniFAT has \(miniFat.count) entries, but mini sector \(fromMiniSector) points to \(toMiniSector))")
                }
                if !miniPointees.insert(toMiniSector).inserted {
                    throw CfbError("Malformed MiniFAT (mini sector \(toMiniSector) pointed to twice)")
                }
            }
        }

        return CompoundFile(
            bytes: bytes, sectorLen: sectorLen, numSectors: numSectors, fat: fat, miniFat: miniFat,
            entries: dirEntries)
    }

    /// The crate's `DirEntry::read_from` under permissive validation, field
    /// by field in the same order so multi-error entries surface the same
    /// message.
    private static func parseDirEntry(_ reader: inout ByteReader, v3: Bool) throws -> CfbDirEntry {
        var nameUnits: [UInt16] = []
        nameUnits.reserveCapacity(32)
        for _ in 0..<32 {
            nameUnits.append(try reader.u16())
        }
        let nameLenBytes = try reader.u16()
        if nameLenBytes > 64 {
            throw CfbError("Malformed directory entry (name length too large: \(nameLenBytes))")
        }
        if nameLenBytes % 2 != 0 {
            throw CfbError("Malformed directory entry (odd name length: \(nameLenBytes))")
        }
        let nameLenChars = nameLenBytes > 0 ? Int(nameLenBytes / 2 - 1) : 0
        guard var name = strictUtf16(Array(nameUnits[0..<nameLenChars])) else {
            throw CfbError("Malformed directory entry (name not valid UTF-16)")
        }
        let objTypeByte = try reader.u8()
        guard let objType = CfbObjType(byte: objTypeByte) else {
            throw CfbError("Malformed directory entry (invalid object type: \(objTypeByte))")
        }
        if objType == .root {
            // Permissive: ignore the actual name and treat it as mandated.
            name = "Root Entry"
        } else {
            for c: Unicode.Scalar in ["/", "\\", ":", "!"] where name.unicodeScalars.contains(c) {
                throw CfbError("Object name cannot contain \(c) character")
            }
        }
        let colorByte = try reader.u8()
        if colorByte > 1 {
            throw CfbError("Malformed directory entry (invalid color: \(colorByte))")
        }
        let left = try reader.u32()
        if left != cfbNoStream && left > cfbMaxRegularStreamId {
            throw CfbError("Malformed directory entry (invalid left sibling: \(left))")
        }
        let right = try reader.u32()
        if right != cfbNoStream && right > cfbMaxRegularStreamId {
            throw CfbError("Malformed directory entry (invalid right sibling: \(right))")
        }
        let child = try reader.u32()
        if child != cfbNoStream {
            if objType == .stream {
                throw CfbError("Malformed directory entry (non-empty stream child: \(child))")
            }
            if child > cfbMaxRegularStreamId {
                throw CfbError("Malformed directory entry (invalid child: \(child))")
            }
        }
        try reader.skip(16)  // CLSID (permissive: ignored for streams)
        try reader.skip(4)  // state bits
        try reader.skip(16)  // creation + modified time (permissive: ignored)
        var startSector = try reader.u32()
        var streamLen = try reader.u64()
        if v3 { streamLen &= 0xFFFF_FFFF }
        if objType == .storage {
            // Permissive: garbage start/len on storages is treated as zero.
            startSector = 0
            streamLen = 0
        }
        return CfbDirEntry(
            name: name, objType: objType, left: left, right: right, child: child,
            startSector: startSector, streamLen: streamLen)
    }
}

/// A CFB-layer failure carrying the `cfb` crate's `io::Error` message text,
/// so callers can embed it verbatim in their own errors.
struct CfbError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

struct CfbDirEntry {
    var name: String
    var objType: CfbObjType
    var left: UInt32
    var right: UInt32
    var child: UInt32
    var startSector: UInt32
    var streamLen: UInt64
}

enum CfbObjType {
    case unallocated
    case storage
    case stream
    case root

    init?(byte: UInt8) {
        switch byte {
        case 0: self = .unallocated
        case 1: self = .storage
        case 2: self = .stream
        case 5: self = .root
        default: return nil
        }
    }

    /// The Rust `ObjType` `{:?}` name, used in error messages.
    var debugName: String {
        switch self {
        case .unallocated: "Unallocated"
        case .storage: "Storage"
        case .stream: "Stream"
        case .root: "Root"
        }
    }
}

private let cfbMagic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
private let cfbMaxRegularSector: UInt32 = 0xFFFF_FFFA
private let cfbInvalidSector: UInt32 = 0xFFFF_FFFB
private let cfbDifatSector: UInt32 = 0xFFFF_FFFC
private let cfbFatSector: UInt32 = 0xFFFF_FFFD
private let cfbEndOfChain: UInt32 = 0xFFFF_FFFE
private let cfbFreeSector: UInt32 = 0xFFFF_FFFF
private let cfbNoStream: UInt32 = 0xFFFF_FFFF
private let cfbMaxRegularStreamId: UInt32 = 0xFFFF_FFFA
private let cfbMiniSectorLen = 64
private let cfbMiniStreamCutoff = 4096

/// Sequential little-endian reader over a byte slice. A short read yields the
/// exact message Rust's `read_exact` produces, which flows into error output.
private struct ByteReader {
    let data: ArraySlice<UInt8>
    var pos: Int

    init(_ data: ArraySlice<UInt8>) {
        self.data = data
        self.pos = data.startIndex
    }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard data.endIndex - pos >= n else {
            throw CfbError("failed to fill whole buffer")
        }
        let out = data[pos..<pos + n]
        pos += n
        return out
    }

    mutating func skip(_ n: Int) throws {
        _ = try take(n)
    }

    mutating func u8() throws -> UInt8 {
        let b = try take(1)
        return b[b.startIndex]
    }

    mutating func u16() throws -> UInt16 {
        let b = try take(2)
        let i = b.startIndex
        return UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let b = try take(4)
        let i = b.startIndex
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    mutating func u64() throws -> UInt64 {
        let lo = try u32()
        let hi = try u32()
        return UInt64(lo) | UInt64(hi) << 32
    }
}

/// The crate's `compare_names`: CFB name ordering is case-insensitive
/// shortlex over UTF-16 units. Returns a negative/zero/positive value like a
/// three-way comparison.
func cfbCompareNames(_ name1: String, _ name2: String) -> Int {
    if name1.utf8.allSatisfy({ $0 < 0x80 }), name2.utf8.allSatisfy({ $0 < 0x80 }) {
        if name1.utf8.count != name2.utf8.count {
            return name1.utf8.count < name2.utf8.count ? -1 : 1
        }
        for (l, r) in zip(name1.utf8, name2.utf8) {
            let lu = asciiUppercase(l)
            let ru = asciiUppercase(r)
            if lu != ru { return lu < ru ? -1 : 1 }
        }
        return 0
    }
    let count1 = name1.utf16.count
    let count2 = name2.utf16.count
    if count1 != count2 {
        return count1 < count2 ? -1 : 1
    }
    // PARITY: the crate maps each char through icu simple uppercase with an
    // exceptions table; the stdlib exposes only full mappings, so scalars
    // whose full uppercase is multi-scalar keep their own value here.
    for (l, r) in zip(name1.unicodeScalars, name2.unicodeScalars) {
        let lu = simpleUppercase(l)
        let ru = simpleUppercase(r)
        if lu != ru { return lu < ru ? -1 : 1 }
    }
    if name1.unicodeScalars.count != name2.unicodeScalars.count {
        return name1.unicodeScalars.count < name2.unicodeScalars.count ? -1 : 1
    }
    return 0
}

private func asciiUppercase(_ b: UInt8) -> UInt8 {
    b >= 0x61 && b <= 0x7A ? b - 0x20 : b
}

private func simpleUppercase(_ c: Unicode.Scalar) -> UInt32 {
    let mapped = c.properties.uppercaseMapping
    let scalars = mapped.unicodeScalars
    if scalars.count == 1, let first = scalars.first {
        return first.value
    }
    return c.value
}

/// Strict UTF-16 decoding: `nil` on any unpaired surrogate, matching Rust's
/// `String::from_utf16`.
private func strictUtf16(_ units: [UInt16]) -> String? {
    var out = String.UnicodeScalarView()
    out.reserveCapacity(units.count)
    var i = 0
    while i < units.count {
        let unit = units[i]
        if unit < 0xD800 || unit > 0xDFFF {
            guard let scalar = Unicode.Scalar(UInt32(unit)) else { return nil }
            out.append(scalar)
            i += 1
        } else if unit < 0xDC00, i + 1 < units.count, (0xDC00...0xDFFF).contains(units[i + 1]) {
            let value = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(units[i + 1] - 0xDC00)
            guard let scalar = Unicode.Scalar(value) else { return nil }
            out.append(scalar)
            i += 2
        } else {
            return nil
        }
    }
    return String(out)
}

/// Uppercase hex with fixed width, matching Rust's `{:0NX}`.
private func hex(_ v: some BinaryInteger, width: Int) -> String {
    var s = String(v, radix: 16, uppercase: true)
    while s.count < width { s = "0" + s }
    return s
}
