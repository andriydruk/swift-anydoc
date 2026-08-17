import Testing

@testable import AnyDoc

/// Band splitting, and the merged-band retry.
///
/// These test the wiring at the function level because no corpus document
/// reaches it: `two-column-prose.pdf` matches the reference whether banding
/// runs or not, so it proves the *output* correct without proving the band
/// layer did anything. Rather than leave that unexamined, the first test
/// below asserts the thing the corpus cannot — that the split happens at
/// all — and the rest pin what changes because of it.
@Suite struct PdfTableBandsTests {
    private func item(_ text: String, _ x: Float, _ y: Float) -> PdfLayoutItem {
        PdfLayoutItem(
            text: text, x: x, y: y, width: Float(text.count) * 5, fontSize: 10, fontName: "F1")
    }

    /// Two prose columns with aligned baselines — the layout that reads as a
    /// two-column table when a detector sees the whole page at once.
    ///
    /// Twenty rows, not nine. `pdfSplitSideBySide` wants forty runs on the
    /// page and twenty to either side before it will divide anything, and a
    /// nine-row draft of this fixture split into one band — which is how the
    /// corpus document written alongside it came to prove nothing.
    private func twoColumnPage(rows: Int = 20) -> [PdfLayoutItem] {
        (0..<rows).flatMap { row in
            [
                item("Left line \(row) here.", 72, 700 - Float(row) * 18),
                item("Right line \(row) here.", 330, 700 - Float(row) * 18),
            ]
        }
    }

    @Test func aTwoColumnPageSplitsIntoTwoBands() {
        let bands = pdfTableBands(items: twoColumnPage(), rects: [], lines: [])
        #expect(bands.count == 2)
        // Each band holds one column's worth, and its map points back at the
        // page — the part a later stage depends on to claim the right items.
        #expect(bands.allSatisfy { $0.items.count == 20 })
        #expect(bands.allSatisfy { $0.items.count == $0.indexMap.count })
        #expect(bands.first?.items.allSatisfy { $0.text.hasPrefix("Left") } == true)
        #expect(bands.last?.items.allSatisfy { $0.text.hasPrefix("Right") } == true)
    }

    @Test func aSingleColumnPageStaysWhole() {
        let items = (0..<40).map {
            item("One column of prose, line \($0).", 72, 700 - Float($0) * 18)
        }
        let bands = pdfTableBands(items: items, rects: [], lines: [])
        #expect(bands.count == 1)
        #expect(bands.first?.indexMap == Array(items.indices))
    }

    // ── the band filters ────────────────────────────────────────────

    @Test func aCellBorderTouchingTheBandIsKept() {
        // Narrow against a 200pt band, so any overlap qualifies.
        let rects = [PdfRect(x: 190, y: 100, width: 20, height: 10)]
        #expect(pdfRectsInBand(rects, low: 0, high: 200).count == 1)
        #expect(pdfRectsInBand(rects, low: 200, high: 400).count == 1)
    }

    @Test func aPageWideRuleIsKeptOnlyByTheBandItMostlySitsIn() {
        // 180pt wide against a 200pt band is ≥70% of it, so the 70%-inside
        // rule applies and the band that owns a sliver does not get it.
        let rects = [PdfRect(x: 10, y: 100, width: 180, height: 2)]
        #expect(pdfRectsInBand(rects, low: 0, high: 200).count == 1)
        #expect(pdfRectsInBand(rects, low: 185, high: 385).isEmpty)
    }

    @Test func aRectangleDrawnRightToLeftIsNormalised() {
        // A negative width is legal and producers emit it; read literally it
        // would give an empty overlap and vanish from every band.
        let rects = [PdfRect(x: 100, y: 100, width: -40, height: 10)]
        #expect(pdfRectsInBand(rects, low: 0, high: 200).count == 1)
    }

    @Test func aLineNeedsOnlyToTouchItsBand() {
        let lines = [PdfLineSegment(x1: 190, y1: 100, x2: 260, y2: 100, strokeWidth: 1)]
        #expect(pdfLinesInBand(lines, low: 0, high: 200).count == 1)
        #expect(pdfLinesInBand(lines, low: 200, high: 400).count == 1)
        #expect(pdfLinesInBand(lines, low: 300, high: 400).isEmpty)
    }

    // ── the retry ───────────────────────────────────────────────────

    /// A borderless table's columns are indistinguishable from page-layout
    /// columns, so the split hides it — and the retry is what looks again.
    ///
    /// What the retry then does is governed by `merged_retry_skips_body_font`:
    /// on a page where the column detector *did* find columns, body-size text
    /// is not allowed to found a table, because that is exactly the evidence
    /// that just proved to be page layout. So this page stays prose. The
    /// first draft of this test asserted the opposite and was wrong about the
    /// reference, not about the port.
    @Test func theMergedRetryHonoursTheBodyFontGate() {
        var items: [PdfLayoutItem] = []
        for row in 0..<20 {
            items.append(item("R\(row)A", 72, 700 - Float(row) * 18))
            items.append(item("R\(row)B", 330, 700 - Float(row) * 18))
        }
        let banded = pdfTableBands(items: items, rects: [], lines: [])

        // The premise: this page *is* split, and no band can see a
        // two-column table with only one column in front of it.
        #expect(banded.count == 2)
        for band in banded {
            #expect(pdfDetectTables(band.items, baseFontSize: 10).isEmpty)
        }

        // The gate is what decides the outcome, and it is doing the deciding
        // here rather than the candidate being unfindable.
        #expect(pdfDetectColumns(items, pageHasTable: false).count >= 2)
        #expect(!pdfDetectTables(items, baseFontSize: 10, skipBodyFont: false).isEmpty)
        #expect(pdfDetectTables(items, baseFontSize: 10, skipBodyFont: true).isEmpty)

        #expect(pdfDetectPageTables(items: items, rects: [], lines: [], baseSize: 10).tables.isEmpty)
    }
}
