/// Nested-list assembly with numbering identity.
///
/// Frontends resolve each list paragraph to a `ListEntry` carrying its
/// indent level, its list identity (`ListKey`), and its computed effective
/// number. Assembly splits runs whenever the identity or marker kind changes
/// at a level, or an ordered sequence is non-contiguous (a restart), so the
/// renderer's `start + index` numbering reproduces the source exactly.

/// Identity of a resolved list at one level: which list instance the entry
/// belongs to and what marker its level uses.
struct ListKey: Equatable {
    /// Stable per-instance id (DOCX `numId`, RTF `\lsN`, DOC list identity
    /// `lsid`, a counter for HTML/ODF lists).
    var instance: UInt64
    var marker: MarkerKind
}

/// One flat, fully resolved list paragraph (plus any blocks attached to the
/// same item, like text-box content anchored in it).
struct ListEntry {
    var level: Int
    var key: ListKey
    /// Effective item number at this entry (ignored for bullets).
    var number: UInt64
    /// Literal marker text when the source number text is not reproducible
    /// from the marker kind and number alone (composite number text).
    var label: String?
    var blocks: [Block]
}

/// Pop the accumulated run of list paragraphs into list blocks; one block
/// per identity segment.
func flushList(_ blocks: inout [Block], _ run: inout [ListEntry]) {
    let entries = run
    run = []
    if entries.isEmpty {
        return
    }
    blocks.append(contentsOf: buildLists(entries))
}

/// Fold a flat run into nested lists, splitting at identity/marker changes
/// and ordered-sequence discontinuities.
func buildLists(_ entries: [ListEntry]) -> [Block] {
    guard let minLvl = entries.lazy.map(\.level).min() else {
        return []
    }
    var out: [Block] = []
    var current: (list: List, key: ListKey, last: UInt64)?  // list, key, last number

    func flushCurrent() {
        if let (list, _, _) = current, !list.items.isEmpty {
            out.append(.list(list))
        }
        current = nil
    }

    var i = 0
    while i < entries.count {
        let level = entries[i].level
        let key = entries[i].key
        let number = entries[i].number
        if level <= minLvl {
            let entry = entries[i]
            i += 1
            let split: Bool
            if let (_, curKey, lastNumber) = current {
                let next = lastNumber.addingReportingOverflow(1)
                split =
                    curKey != key
                    || (key.marker.ordered && (next.overflow || next.partialValue != number))
            } else {
                split = true
            }
            if split {
                flushCurrent()
                let list = List(
                    marker: key.marker,
                    start: key.marker.ordered ? number : 1,
                    items: [])
                current = (list, key, number)
            }
            if var cur = current {
                cur.list.items.append(
                    ListItem(blocks: entry.blocks, checked: nil, markerLabel: entry.label))
                cur.last = number
                current = cur
            }
        } else {
            var sub: [ListEntry] = []
            while i < entries.count, entries[i].level > minLvl {
                sub.append(entries[i])
                i += 1
            }
            let sublists = buildLists(sub)
            if sublists.isEmpty {
                continue
            }
            if current == nil {
                // Sub-level content with no parent item yet: host it in an
                // anonymous item so nesting is preserved.
                let key = ListKey(instance: .max, marker: .bullet)
                current = (List(marker: .bullet, start: 1, items: []), key, 0)
            }
            if var cur = current {
                if cur.list.items.isEmpty {
                    cur.list.items.append(ListItem())
                }
                cur.list.items[cur.list.items.count - 1].blocks.append(contentsOf: sublists)
                current = cur
            }
        }
    }
    flushCurrent()
    return out
}
