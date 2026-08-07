/// Content-based format detection.
///
/// Identifies the format from what each specification designates as the
/// container's identity, never from heuristics over document content:
///
/// - PDF: the `%PDF-` header (ISO 32000; implementations accept leading
///   junk, bounded here at 1024 bytes).
/// - RTF: the `{\rtf` group that must open every RTF file.
/// - OLE compound files: the [MS-CFB] signature, then the stream name each
///   binary Office format mandates ([MS-DOC] `WordDocument`, [MS-PPT]
///   `PowerPoint Document`, [MS-XLS] `Workbook`/`Book`).
/// - ZIP packages: the local-file-header signature, then the package's own
///   identity: the `mimetype` part (ODF/EPUB OCF), or for OPC the content
///   type of the part the package-level officeDocument relationship
///   designates as the main document (with the main part's mandated root
///   element as the authority when content types are stale or generic).
///
/// Plain-text formats (CSV) carry no signature and are never detected;
/// callers fall back to the file extension. Detection never errors: any
/// unreadable or ambiguous container yields `nil` and the caller's
/// fallback (extension, then the frontend's own error) applies.

private let oleMagic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
private let ctNs = "http://schemas.openxmlformats.org/package/2006/content-types"
private let manifestNs = "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"
private let spreadsheetNs = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

func detectFormat(from bytes: [UInt8]) -> Format? {
    if bytes.starts(with: Array("{\\rtf".utf8)) {
        return .rtf
    }
    if bytes.starts(with: oleMagic) {
        return detectOle(bytes)
    }
    if bytes.starts(with: Array("PK\u{03}\u{04}".utf8)) {
        return detectZip(bytes)
    }
    if bytesContain(bytes[..<min(bytes.count, 1024)], Array("%PDF-".utf8)) {
        return .pdf
    }
    return nil
}

/// Classify an OLE compound file by its mandated content stream. Encrypted
/// OOXML packages (`EncryptedPackage`) stay `nil`: the inner format is
/// unknowable, and the frontend reports `encrypted` precisely.
private func detectOle(_ bytes: [UInt8]) -> Format? {
    guard let ole = try? CompoundFile(bytes: bytes) else { return nil }
    // Stream-name comparison is case-insensitive, matching CFB's own
    // uppercase name comparisons; producers vary (`WORKBOOK`, `BOOK`).
    for name in ole.rootEntryNames {
        if eqIgnoreAsciiCase(name, "WordDocument") {
            return .doc
        } else if eqIgnoreAsciiCase(name, "PowerPoint Document") {
            return .ppt
        } else if eqIgnoreAsciiCase(name, "Workbook") || eqIgnoreAsciiCase(name, "Book") {
            return .excel
        }
    }
    return nil
}

private func detectZip(_ bytes: [UInt8]) -> Format? {
    guard let pkg = try? Package.open(bytes) else { return nil }

    // ODF and EPUB designate the `mimetype` part as the package identity.
    if let mime = ((try? pkg.optionalPart("mimetype")) ?? nil) {
        guard let text = validateUtf8(mime[...]) else { return nil }
        return mimetypeFormat(text.rustTrim())
    }

    // OPC: the package-level officeDocument relationship designates the
    // main part; its content type names the document kind.
    if let rels = try? readRels(pkg, "_rels/.rels"),
        let rel = rels.firstOfType(RelType.officeDocument),
        let target = try? resolvePackageReference(basePart: "", reference: rel.target)
    {
        if let types = ((try? pkg.optionalXmlPart("[Content_Types].xml")) ?? nil),
            let ct = contentTypeOf(types, part: target.path),
            let format = opcFormat(ct)
        {
            return format
        }
        // Content types can be stale or generic; the main part's mandated
        // root element (`w:document`, `p:presentation`, `workbook`) is the
        // next authority.
        if let tree = ((try? pkg.optionalXmlPart(target.path)) ?? nil),
            let format = tree.childElements.first.flatMap(rootElementFormat)
        {
            return format
        }
        // Binary main parts (`xl/workbook.bin`) and unreadable ones: the
        // conventional locations the frontends also fall back to.
        return opcFormatByPath(target.path)
    }

    // Packages with no usable rels: conventional main-part locations.
    for (part, format): (String, Format) in [
        ("word/document.xml", .docx),
        ("ppt/presentation.xml", .pptx),
        ("xl/workbook.xml", .excel),
        ("xl/workbook.bin", .excel),
    ] {
        if pkg.hasPart(part) {
            return format
        }
    }

    // ODF without its mandatory `mimetype`: the manifest's root file entry
    // carries the same media type.
    if let manifest = ((try? pkg.optionalXmlPart("META-INF/manifest.xml")) ?? nil),
        let root = manifest.descendants(manifestNs, "file-entry")
            .first(where: { $0.attr(manifestNs, "full-path") == "/" }),
        let mime = root.attr(manifestNs, "media-type")
    {
        return mimetypeFormat(mime.rustTrim())
    }

    // EPUB without its mandatory `mimetype`: the OCF container descriptor.
    if pkg.hasPart("META-INF/container.xml") {
        return .epub
    }

    return nil
}

private func mimetypeFormat(_ mime: String) -> Format? {
    // `-template` variants share the base format's parser.
    var mime = Substring(mime)
    if mime.hasSuffix("-template") {
        mime = mime.dropLast("-template".count)
    }
    switch mime {
    case "application/epub+zip": return .epub
    case "application/vnd.oasis.opendocument.text": return .odt
    case "application/vnd.oasis.opendocument.spreadsheet": return .ods
    case "application/vnd.oasis.opendocument.presentation": return .odp
    default: return nil
    }
}

/// Resolve a part's content type per OPC: an `Override` for the exact part
/// name wins, else the `Default` for its extension.
private func contentTypeOf(_ types: XmlElement, part: String) -> String? {
    let partName = "/\(part)"
    if let ct = types.descendants(ctNs, "Override")
        .first(where: { e in e.attrAny("PartName").map { eqIgnoreAsciiCase($0, partName) } ?? false })?
        .attrAny("ContentType")
    {
        return ct
    }
    guard let dot = part.lastIndex(of: ".") else { return nil }
    let ext = part[part.index(after: dot)...]
    return types.descendants(ctNs, "Default")
        .first(where: { e in e.attrAny("Extension").map { eqIgnoreAsciiCase($0, ext) } ?? false })?
        .attrAny("ContentType")
}

/// Map a main-part content type onto its parser. The family segment covers
/// every variant (document, template, macro-enabled, slideshow); `ms-excel`
/// covers the binary `.xlsb` main part.
private func opcFormat(_ contentType: String) -> Format? {
    let ct = contentType.utf8.map(asciiLower)
    if bytesContain(ct[...], Array("wordprocessingml".utf8)) {
        return .docx
    } else if bytesContain(ct[...], Array("presentationml".utf8)) {
        return .pptx
    } else if bytesContain(ct[...], Array("spreadsheetml".utf8))
        || bytesContain(ct[...], Array("ms-excel".utf8))
    {
        return .excel
    }
    return nil
}

/// Each OOXML main part has a mandated root element; its namespace (already
/// normalized from Strict to Transitional at parse time) names the format.
private func rootElementFormat(_ root: XmlElement) -> Format? {
    switch root.ns {
    case Ns.w: return .docx
    case Ns.p: return .pptx
    case spreadsheetNs: return .excel
    default: return nil
    }
}

private func opcFormatByPath(_ part: String) -> Format? {
    if part.hasPrefix("word/") {
        return .docx
    } else if part.hasPrefix("ppt/") {
        return .pptx
    } else if part.hasPrefix("xl/") {
        return .excel
    }
    return nil
}

/// Rust `windows(n).any(|w| w == needle)`: byte-level substring search.
private func bytesContain(_ haystack: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    let end = haystack.endIndex - needle.count
    var i = haystack.startIndex
    while i <= end {
        var match = true
        for (k, b) in needle.enumerated() where haystack[i + k] != b {
            match = false
            break
        }
        if match {
            return true
        }
        i += 1
    }
    return false
}
