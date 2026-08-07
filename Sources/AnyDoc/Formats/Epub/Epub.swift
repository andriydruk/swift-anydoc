/// EPUB: XHTML chapters in spine order, concatenated into one document with
/// chapter-scoped anchors so intra-book navigation survives.

func parseEpub(_ bytes: [UInt8]) throws -> Document {
    let pkg = try Package.open(bytes)

    let container = try pkg.requiredXmlPart("META-INF/container.xml")
    guard
        let opfPath = container.descendantsAny("rootfile").first
            .flatMap({ $0.attrAny("full-path") })
    else {
        throw ConvertError.malformedPart("META-INF/container.xml", "no rootfile entry")
    }

    let opf = try pkg.requiredXmlPart(opfPath)

    var doc = Document()
    if let title = opf.descendantsAny("title").first.map({ $0.text() }) {
        let title = title.rustTrim()
        if !title.isEmpty {
            doc.blocks.append(.heading(1, [.plain(title)]))
        }
    }

    var manifest: [String: (href: String, media: String)] = [:]
    for item in opf.descendantsAny("item") {
        if let id = item.attrAny("id"), let href = item.attrAny("href") {
            let media = item.attrAny("media-type") ?? ""
            manifest[id] = (href: href, media: media)
        }
    }

    // Every spine part in spine order: non-linear items are auxiliary but
    // still publication content, and unusable parts degrade at parse time.
    // Intra-book links target these; links to any other resource stay
    // Relative.
    let spineHrefs: [String] = opf.descendantsAny("itemref")
        .compactMap { $0.attrAny("idref") }
        .compactMap { manifest[$0]?.href }
    let spineParts = Set(
        spineHrefs.compactMap { href in
            try? resolvePackageReference(basePart: opfPath, reference: href).path
        })

    let assets = SharedAssetSink()
    var cssCache: [String: String?] = [:]
    var failed = 0
    for href in spineHrefs {
        let chapterPath: String
        do {
            chapterPath = try resolvePackageReference(basePart: opfPath, reference: href).path
        } catch {
            let detail = (error as? ConvertError)?.message ?? "\(error)"
            Log.warn("skipping chapter with unresolvable href \(rustDebugQuoted(href)): \(detail)")
            failed += 1
            continue
        }
        guard let tree = try pkg.optionalXmlPart(chapterPath) else {
            Log.warn("skipping unusable chapter \(chapterPath)")
            failed += 1
            continue
        }
        guard
            let body = tree.childElements.first(where: { $0.local == "html" })
                .flatMap({ html in html.childElements.first(where: { $0.local == "body" }) })
        else {
            Log.warn("skipping chapter \(chapterPath): no body element")
            failed += 1
            continue
        }
        let css = try chapterStylesheet(tree, chapterPath: chapterPath, pkg: pkg, cache: &cssCache)
        let ctx = ChapterCtx(
            pkg: pkg, assets: assets, chapterPath: chapterPath, spineParts: spineParts)
        // Chapter-start anchor: renders only when a link targets this chapter.
        doc.blocks.append(.paragraph([.anchor(chapterPath)]))
        doc.blocks.append(contentsOf: try htmlToBlocks(body, css: css, ctx: ctx))
    }
    if !spineHrefs.isEmpty, failed == spineHrefs.count {
        throw ConvertError.malformed("no chapter in the book could be read")
    }

    doc.assets = assets.sink.assets
    return doc
}

/// A chapter's CSS cascade: its linked stylesheets and inline `<style>`
/// blocks, in document order. Stylesheet parts are cached across chapters.
private func chapterStylesheet(
    _ tree: XmlElement,
    chapterPath: String,
    pkg: Package,
    cache: inout [String: String?]
) throws -> Stylesheet {
    var css = Stylesheet()
    var stack: [XmlElement] = tree.childElements.reversed()
    while let elem = stack.popLast() {
        switch elem.local {
        case "link":
            let rel = elem.attrAny("rel") ?? ""
            let isSheet = rel.unicodeScalars
                .split(whereSeparator: \.isRustWhitespace)
                .contains { eqIgnoreAsciiCase($0, "stylesheet") }
            if isSheet, let href = elem.attrAny("href") {
                guard
                    let target = try? resolvePackageReference(
                        basePart: chapterPath, reference: href)
                else {
                    continue
                }
                if cache.index(forKey: target.path) == nil {
                    let text = try pkg.optionalPart(target.path)
                        .map { String(decoding: $0, as: UTF8.self) }
                    // `updateValue` stores a present-but-nil entry; plain
                    // subscript assignment of nil would drop the key.
                    cache.updateValue(text, forKey: target.path)
                }
                if let entry = cache[target.path], let text = entry {
                    css.add(text)
                }
            }
        case "style":
            css.add(elem.text())
        default:
            stack.append(contentsOf: elem.childElements.reversed())
        }
    }
    return css
}

/// Rust `str::eq_ignore_ascii_case` over a scalar slice and an ASCII literal.
private func eqIgnoreAsciiCase(
    _ scalars: Substring.UnicodeScalarView.SubSequence, _ ascii: String
) -> Bool {
    // Rust folds bytes; folding scalars is identical because only ASCII
    // letters change under either fold.
    let other = Array(ascii.unicodeScalars)
    guard scalars.count == other.count else { return false }
    for (a, b) in zip(scalars, other) {
        let fa = (a >= "A" && a <= "Z") ? Unicode.Scalar(a.value + 0x20) ?? a : a
        let fb = (b >= "A" && b <= "Z") ? Unicode.Scalar(b.value + 0x20) ?? b : b
        if fa != fb {
            return false
        }
    }
    return true
}

/// Asset accumulation shared across chapter contexts (the Rust code threads
/// one `RefCell<AssetSink>` through every `ChapterCtx`).
private final class SharedAssetSink {
    var sink = AssetSink()
}

private final class ChapterCtx: HtmlCtx {
    let pkg: Package
    let assets: SharedAssetSink
    let chapterPath: String
    let spineParts: Set<String>

    init(pkg: Package, assets: SharedAssetSink, chapterPath: String, spineParts: Set<String>) {
        self.pkg = pkg
        self.assets = assets
        self.chapterPath = chapterPath
        self.spineParts = spineParts
    }

    func linkTarget(_ href: String) -> LinkTarget? {
        if href.isEmpty {
            return nil
        }
        // Rust `strip_prefix('#')` splits at the byte, even when a combining
        // mark would fuse the `#` into one grapheme cluster.
        if href.utf8.first == UInt8(ascii: "#") {
            let fragment = decodeFragment(String(decoding: Array(href.utf8.dropFirst()), as: UTF8.self))
            return .anchor(scoped(chapterPath, fragment))
        }
        if isAbsoluteUri(href) {
            return .external(href)
        }
        // Anchors only for converted spine documents; links to any other
        // package resource (images, downloads, non-linear content) keep
        // their relative form.
        if let target = try? resolvePackageReference(basePart: chapterPath, reference: href),
            spineParts.contains(target.path)
        {
            return .anchor(scoped(target.path, target.fragment))
        }
        return .relative(href)
    }

    func imageSource(_ src: String) throws -> ImageSource? {
        if src.isEmpty {
            return nil
        }
        if isAbsoluteUri(src) {
            return .external(src)
        }
        guard let target = try? resolvePackageReference(basePart: chapterPath, reference: src)
        else {
            return nil
        }
        guard let bytes = try pkg.optionalPart(target.path) else {
            return nil
        }
        let media = mediaTypeFor(target.path)
        let id = try assets.sink.add(mediaType: media, originPart: target.path, bytes: bytes)
        return .asset(id)
    }

    func anchorId(_ raw: String) -> AnchorId {
        scoped(chapterPath, raw)
    }
}

/// Chapter-scoped anchor id: the chapter path itself targets the chapter
/// start; `path#fragment` targets an element inside it.
private func scoped(_ chapterPath: String, _ fragment: String?) -> AnchorId {
    if let f = fragment, !f.isEmpty {
        return "\(chapterPath)#\(f)"
    }
    return chapterPath
}
