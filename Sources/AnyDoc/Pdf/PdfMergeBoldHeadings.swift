/// Bold runs short enough to be one heading, ported from `convert.rs`:
/// `merge_wrapped_bold_heading_groups` and `count_table_columns`.
///
/// Wave 84 found the bold runs *too long* to be headings and suppressed
/// them. This is the same scan reaching the opposite verdict: a run of two
/// or three bold lines totalling fifteen words or fewer is one heading that
/// happened to wrap, and the lines are merged so the writer emits a single
/// `##` rather than a stack of them.
///
/// Between them the two functions partition every body-size bold run — merge
/// at two or three short lines, suppress at three or more long ones, leave
/// alone in the gap between. The overlap at three lines is resolved by word
/// count, and a single bold line is neither.
///
/// This one **renumbers the lines**, so any index set computed against the
/// input — `pdfFindIsolatedLines`, `pdfFindWrappedBoldParagraphLines` — is
/// stale afterwards and must be recomputed.

/// Merge short wrapped bold runs into single lines.
func pdfMergeWrappedBoldHeadingGroups(
    _ lines: [PdfTextLine], baseSize: Float, paraThreshold: Float
) -> [PdfTextLine] {
    var out: [PdfTextLine] = []
    out.reserveCapacity(lines.count)

    var index = 0
    while index < lines.count {
        guard pdfIsBodySizeAllBoldLine(lines[index], bodySize: baseSize) else {
            out.append(lines[index])
            index += 1
            continue
        }

        // The same run scan as `pdfFindWrappedBoldParagraphLines`: extend
        // while the next line is bold at body size and reads as a wrap.
        let start = index
        var end = index
        var wordCount = pdfLineText(lines[index]).rustSplitWhitespace().count
        while end + 1 < lines.count,
            pdfIsBodySizeAllBoldLine(lines[end + 1], bodySize: baseSize),
            pdfIsWrappedSameStyleLine(lines[end], lines[end + 1], paragraphThreshold: paraThreshold)
        {
            end += 1
            wordCount += pdfLineText(lines[end]).rustSplitWhitespace().count
        }
        let lineCount = end - start + 1

        // Isolation is judged **column-locally**. On an interleaved
        // multi-column page the neighbouring entries in the array belong to
        // the other column, so this ignores array order entirely and asks
        // instead whether any line anywhere on the page sits within the
        // paragraph gap *and* overlaps the group horizontally.
        var groupX0 = Float.infinity
        var groupX1 = -Float.infinity
        for line in lines[start...end] {
            for item in line.items {
                groupX0 = min(groupX0, item.x)
                groupX1 = max(groupX1, item.x + item.width)
            }
        }
        // Strict on both sides, so edge-to-edge columns do not overlap. A
        // line with no items keeps the infinities and can never overlap
        // anything, which is what stops an empty line blocking a merge.
        func overlapsX(_ line: PdfTextLine) -> Bool {
            var x0 = Float.infinity
            var x1 = -Float.infinity
            for item in line.items {
                x0 = min(x0, item.x)
                x1 = max(x1, item.x + item.width)
            }
            return x0 < groupX1 && x1 > groupX0
        }

        let page = lines[start].page
        let breakBefore = !lines.contains { line in
            line.page == page && line.y > lines[start].y
                && line.y - lines[start].y <= paraThreshold && overlapsX(line)
        }
        let breakAfter = !lines.contains { line in
            line.page == page && line.y < lines[end].y
                && lines[end].y - line.y <= paraThreshold && overlapsX(line)
        }

        // A section number is evidence enough on its own — `9.5. Method`
        // wrapping onto a second line is a heading whatever sits around it.
        // This is the `convert.rs` spelling, which needs two components, so
        // `1. Something` does not qualify and stays an ordered list item.
        let numbered = pdfStartsWithSectionNumberAndTitle(pdfLineText(lines[start]))

        if (2...3).contains(lineCount) && wordCount <= 15
            && ((breakBefore && breakAfter) || numbered)
        {
            // The merged line keeps the first line's baseline and page, and
            // the items are appended in line order rather than re-sorted.
            var merged = lines[start]
            for line in lines[(start + 1)...end] { merged.items.append(contentsOf: line.items) }
            out.append(merged)
        } else {
            out.append(contentsOf: lines[start...end])
        }
        index = end + 1
    }
    return out
}

/// How many columns a rendered Markdown table has.
///
/// Read from the **separator row alone** — the second line — so a table
/// whose header and separator disagree reports the separator's width. A
/// second line without `---` in it means this is not a table at all.
func pdfCountTableColumns(_ tableMarkdown: String) -> Int {
    let rows = tableMarkdown.rustLines()
    guard rows.count > 1, rows[1].contains("---") else { return 0 }
    let pipes = rows[1].filter { $0 == "|" }.count
    return pipes >= 2 ? pipes - 1 : 0
}
