import Testing

@testable import AnyDoc

/// Fragment merging. The differential probe checks whole PDFs against the
/// reference; these name the individual decisions.
@Suite struct PdfMergeItemsTests {
    private func item(
        _ text: String, x: Float, y: Float = 700, size: Float = 12, width: Float? = nil
    ) -> PdfLayoutItem {
        PdfLayoutItem(
            text: text, x: x, y: y,
            width: width ?? Float(text.count) * size * 0.5,
            fontSize: size, fontName: "F1")
    }

    @Test func adjacentFragmentsJoinWithoutASpace() {
        let merged = pdfMergeTextItems([item("Hel", x: 100), item("lo", x: 118)])
        #expect(merged.count == 1)
        #expect(merged[0].text == "Hello")
    }

    /// A lowercase pair is probably mid-word, so it takes a wider gap before
    /// a space is inserted than a mixed-case pair does.
    @Test func lowercasePairsGetAWiderThreshold() {
        let lower = pdfMergeTextItems([item("ab", x: 100), item("cd", x: 113.2)])
        #expect(lower[0].text == "abcd")
        let mixed = pdfMergeTextItems([item("AB", x: 100), item("cd", x: 113.2)])
        #expect(mixed[0].text == "AB cd")
    }

    @Test func joiningPunctuationNeverTakesASpace() {
        let merged = pdfMergeTextItems([item("word", x: 100), item(".", x: 126)])
        #expect(merged[0].text == "word.")
    }

    @Test func aGapPastHalfAnEmEndsTheRun() {
        let merged = pdfMergeTextItems([item("near", x: 100), item("far", x: 135)])
        #expect(merged.count == 2)
    }

    @Test func aSizeChangeOutsideTheBandEndsTheRun() {
        let merged = pdfMergeTextItems([item("big", x: 100), item("small", x: 118, size: 8)])
        #expect(merged.count == 2)
    }

    /// The merged fragment carries the first one's flags, so absorbing a
    /// styled run into a plain neighbour would erase the styling.
    @Test func styleBoundariesBlockTheMerge() {
        var bold = item("bold", x: 118)
        bold.isBold = true
        let merged = pdfMergeTextItems([item("plain", x: 100), bold])
        #expect(merged.count == 2)
    }

    /// Display tracking spaces every glyph, so a run of single all-caps
    /// glyphs gets its own floor instead of the fixed threshold — otherwise
    /// `TRACK` comes back as five words.
    @Test func letterspacedCapsJoinIntoOneWord() {
        let glyphs = ["T", "R", "A", "C", "K"].enumerated().map { index, text in
            item(text, x: 100 + Float(index) * 9)
        }
        #expect(pdfMergeTextItems(glyphs).map(\.text) == ["TRACK"])
    }

    /// Lowercase singles keep their boundaries — the tracked-run floor is
    /// an all-caps convention, because geometry alone cannot tell spaced
    /// letters from a tracked title-case word. They still merge into one
    /// item; what differs is that the spaces survive.
    @Test func letterspacedLowercaseKeepsItsBoundaries() {
        let glyphs = ["x", "y", "z", "w"].enumerated().map { index, text in
            item(text, x: 100 + Float(index) * 9)
        }
        #expect(pdfMergeTextItems(glyphs).map(\.text) == ["x y z w"])
    }

    // MARK: scripts

    @Test func aLoweredDigitBecomesASubscript() {
        let merged = pdfMergeSubscriptItems([
            item("H", x: 100, width: 6), item("2", x: 106, y: 698, size: 6, width: 3),
        ])
        #expect(merged.map(\.text) == ["H₂"])
    }

    @Test func aRaisedDigitBecomesASuperscript() {
        let merged = pdfMergeSubscriptItems([
            item("note", x: 100, width: 24), item("3", x: 124, y: 704, size: 6, width: 3),
        ])
        #expect(merged.map(\.text) == ["note³"])
    }

    /// Only a parent ending in a letter absorbs a script, which keeps
    /// `33` + `1` apart in `33 1/3%`.
    @Test func aDigitParentDoesNotAbsorb() {
        let merged = pdfMergeSubscriptItems([
            item("33", x: 100, width: 12), item("1", x: 112, y: 704, size: 6, width: 3),
        ])
        #expect(merged.count == 2)
    }

    @Test func onlyDigitsAreAbsorbed() {
        let merged = pdfMergeSubscriptItems([
            item("H", x: 100, width: 6), item("x", x: 106, y: 698, size: 6, width: 3),
        ])
        #expect(merged.count == 2)
    }

    /// A strikeout boundary blocks the merge; an underlined parent with an
    /// unmarked digit still merges, since the rule easily misses the tiny
    /// digit's overlap window.
    @Test func decorationBoundariesGovernScriptMerging() {
        var struck = item("H", x: 100, width: 6)
        struck.isStrikeout = true
        #expect(
            pdfMergeSubscriptItems([struck, item("2", x: 106, y: 698, size: 6, width: 3)]).count
                == 2)

        var underlined = item("H", x: 100, width: 6)
        underlined.isUnderline = true
        #expect(
            pdfMergeSubscriptItems([
                underlined, item("2", x: 106, y: 698, size: 6, width: 3),
            ]).map(\.text) == ["H₂"])
    }

    /// Word spacing inflates only strings containing a space, so a run whose
    /// average glyph is implausibly wide is capped.
    @Test func inflatedAdvancesAreCappedForMerging() {
        let plain = item("ab", x: 0, width: 40)
        #expect(pdfEffectiveMergeWidth(plain) == 40, "no space, so no inflation to undo")
        let spaced = item("a b", x: 0, width: 40)
        #expect(pdfEffectiveMergeWidth(spaced) < 40)
    }
}
