/// Anchor resolution: maps every internal anchor id to the fragment it will
/// have in the rendered Markdown. Heading-coincident anchors reuse the
/// heading's GFM auto-generated slug; an anchor a link targets gets a
/// sanitized, stable HTML id rendered as `<a id="..."></a>` at its position.
///
/// Anchors nothing links to render nothing: producers mark up far more
/// positions than they reference, and an unreachable target is only noise.

struct AnchorMap {
    private var resolved: [String: Resolved] = [:]

    private struct Resolved {
        var fragment: String
        /// True when the anchor needs an explicit `<a id>` emitted at its
        /// position (false for heading-coincident anchors — the heading's own
        /// slug carries them).
        var emitHtml: Bool
    }

    /// The `#fragment` a link to `id` should use, if the target exists.
    func fragment(_ id: String) -> String? {
        resolved[id]?.fragment
    }

    /// The HTML id to emit for an `Inline.anchor` node, when one is needed.
    func htmlId(_ id: String) -> String? {
        guard let r = resolved[id], r.emitHtml else { return nil }
        return r.fragment
    }

    static func resolve(_ doc: Document) -> AnchorMap {
        var ids = UniqueIds()
        var map = AnchorMap()

        // Anchor ids some link in the document targets, notes included.
        var linked: Set<String> = []
        walkBlocks(doc.blocks) { collectLinkTargets($0, into: &linked) }
        for note in doc.notes {
            walkBlocks(note.blocks) { collectLinkTargets($0, into: &linked) }
        }

        // Pass 1: headings claim their GFM slugs in render order, binding any
        // heading-coincident anchor ids (the `anchor` field and anchor nodes
        // inside the heading content) to those slugs.
        walkBlocks(doc.blocks) { block in
            guard case .heading(_, let anchor, let content) = block else { return }
            guard let slug = ids.claim(gfmSlug(inlinesToPlainText(content))) else { return }
            func bind(_ id: String) {
                if map.resolved[id] == nil {
                    map.resolved[id] = Resolved(fragment: slug, emitHtml: false)
                }
            }
            if let id = anchor {
                bind(id)
            }
            forEachAnchor(content, bind)
        }

        // Pass 2: every remaining anchor a link targets gets a sanitized
        // HTML id.
        func assign(_ id: String) {
            if linked.contains(id), map.resolved[id] == nil,
                let html = ids.claim(sanitizeId(id))
            {
                map.resolved[id] = Resolved(fragment: html, emitHtml: true)
            }
        }
        walkBlocks(doc.blocks) { bindBlockAnchors($0, assign) }
        for note in doc.notes {
            walkBlocks(note.blocks) { bindBlockAnchors($0, assign) }
        }

        return map
    }
}

private func collectLinkTargets(_ block: Block, into out: inout Set<String>) {
    switch block {
    case .heading(_, _, let content), .paragraph(let content):
        forEachLinkTarget(content, into: &out)
    default:
        break
    }
}

private func forEachLinkTarget(_ inlines: [Inline], into out: inout Set<String>) {
    for inline in inlines {
        if case .link(let content, let target) = inline {
            if case .anchor(let id) = target {
                out.insert(id)
            }
            forEachLinkTarget(content, into: &out)
        }
    }
}

private func bindBlockAnchors(_ block: Block, _ assign: (String) -> Void) {
    switch block {
    case .heading(_, _, let content), .paragraph(let content):
        forEachAnchor(content, assign)
    default:
        break
    }
}

/// Depth-first walk over all blocks, using an explicit stack.
func walkBlocks(_ blocks: [Block], _ f: (Block) -> Void) {
    var stack: [Block] = blocks.reversed()
    while let block = stack.popLast() {
        f(block)
        switch block {
        case .list(let list):
            for item in list.items.reversed() {
                stack.append(contentsOf: item.blocks.reversed())
            }
        case .table(let table):
            for row in table.grid.reversed() {
                for slot in row.reversed() {
                    if case .origin(let cell) = slot {
                        stack.append(contentsOf: cell.blocks.reversed())
                    }
                }
            }
        case .blockQuote(let inner):
            stack.append(contentsOf: inner.reversed())
        default:
            break
        }
    }
}

private func forEachAnchor(_ inlines: [Inline], _ f: (String) -> Void) {
    for inline in inlines {
        switch inline {
        case .anchor(let id): f(id)
        case .link(let content, _): forEachAnchor(content, f)
        default: break
        }
    }
}

/// Allocates ids without repeatedly probing used numeric suffixes.
struct UniqueIds {
    private var used: Set<String> = []
    private var nextSuffix: [String: Int] = [:]

    mutating func claim(_ base: String) -> String? {
        if used.insert(base).inserted {
            if nextSuffix[base] == nil { nextSuffix[base] = 1 }
            return base
        }
        var n = nextSuffix[base] ?? 1
        while true {
            let candidate = "\(base)-\(n)"
            guard n != Int.max else { return nil }
            n += 1
            if used.insert(candidate).inserted {
                nextSuffix[base] = n
                if nextSuffix[candidate] == nil { nextSuffix[candidate] = 1 }
                return candidate
            }
        }
    }
}

/// GFM-style heading slugs: full-Unicode lowercase, spaces become hyphens,
/// and everything except word-forming characters (letters, numbers, marks,
/// connector punctuation) and hyphens drops. An empty result becomes
/// `section` so the anchor stays linkable.
func gfmSlug(_ text: String) -> String {
    var slug = String.UnicodeScalarView()
    for upper in text.rustTrim().unicodeScalars {
        for c in upper.rustLowercased.unicodeScalars {
            switch c {
            case " ": slug.append("-")
            case "-": slug.append(c)
            case let c
                where c.isRustAlphanumeric || isCombiningMark(c) || isConnectorPunctuation(c):
                slug.append(c)
            default: break
            }
        }
    }
    let out = String(slug)
    return out.isEmpty ? "section" : out
}

/// Combining-mark blocks `isRustAlphanumeric` misses (marks outside
/// `Other_Alphabetic`, such as viramas and cantillation/stress signs).
private func isCombiningMark(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x0300...0x036F, 0x0483...0x0489, 0x0900...0x0903, 0x093A...0x094F,
        0x0951...0x0957, 0x0962...0x0963, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF,
        0x20D0...0x20FF, 0xFE20...0xFE2F:
        true
    default:
        false
    }
}

/// Connector punctuation (category Pc): joins words, kept like `_`.
private func isConnectorPunctuation(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x005F, 0x203F, 0x2040, 0x2054, 0xFE33, 0xFE34, 0xFE4D...0xFE4F, 0xFF3F:
        true
    default:
        false
    }
}

/// Sanitize a source anchor id into a stable `[a-z0-9-_]` HTML id.
func sanitizeId(_ id: String) -> String {
    var out = String.UnicodeScalarView()
    out.reserveCapacity(id.unicodeScalars.count)
    var prevDash = false
    for c in id.unicodeScalars {
        let lower = ("A"..."Z").contains(c) ? Unicode.Scalar(c.value + 32)! : c
        let mapped: Unicode.Scalar
        switch lower {
        case "a"..."z", "0"..."9", "_", "-": mapped = lower
        default: mapped = "-"
        }
        if mapped == "-" && prevDash {
            continue
        }
        prevDash = mapped == "-"
        out.append(mapped)
    }
    var trimmed = Substring(String(out))
    while trimmed.first == "-" { trimmed = trimmed.dropFirst() }
    while trimmed.last == "-" { trimmed = trimmed.dropLast() }
    return trimmed.isEmpty ? "anchor" : String(trimmed)
}
