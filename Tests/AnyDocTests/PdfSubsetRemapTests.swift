// The subset-CMap remap: its gates, its renumbering, and the sticky decision.
//
// `cid-subset-remap.pdf` in the corpus covers the end-to-end path, but it
// draws one short string — far under the 240 bytes that trigger the sticky
// decision, so the state machine below is exercised nowhere else.
import Testing

@testable import AnyDoc

/// A `/ToUnicode` stream's bytes, wrapping `body` in the boilerplate every
/// CMap carries. Built and parsed rather than assembled field by field, so
/// the tests exercise the same parser the pipeline does.
private func toUnicodeCMap(_ body: String) -> PdfToUnicodeCMap {
    let text = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        1 begincodespacerange
        <0000> <FFFF>
        endcodespacerange
        \(body)
        endcmap
        end
        end
        """
    return parsePdfToUnicode(Array(text.utf8))
}

@Suite struct PdfSubsetRemapTests {
    /// Old CIDs sorted ascending and reassigned from 1, with the text they
    /// map to carried along.
    @Test func remappingRenumbersOntoSequentialCidsFromOne() {
        let cmap = toUnicodeCMap(
            """
            4 beginbfchar
            <0067> <0050>
            <0064> <0048>
            <0066> <004C>
            <0065> <0045>
            endbfchar
            """)

        let remapped = cmap.remapToSequential()
        #expect(remapped.charMap[1] == "H")
        #expect(remapped.charMap[2] == "E")
        #expect(remapped.charMap[3] == "L")
        #expect(remapped.charMap[4] == "P")
        // Nothing at 0: glyph 0 is `.notdef`.
        #expect(remapped.charMap[0] == nil)
        #expect(remapped.codeByteLength == 2)
    }

    /// A `bfchar` entry beats a range covering the same CID, which is the
    /// precedence `lookup` applies and the remap has to preserve.
    @Test func aDirectMappingOutranksARangeCoveringTheSameCid() {
        let cmap = toUnicodeCMap(
            """
            1 beginbfrange
            <0032> <0034> <0041>
            endbfrange
            1 beginbfchar
            <0033> <005A>
            endbfchar
            """)

        let remapped = cmap.remapToSequential()
        #expect(remapped.charMap[1] == "A")
        #expect(remapped.charMap[2] == "Z")
        #expect(remapped.charMap[3] == "C")
    }

    @Test func theSourceCidBoundsSpanBothCharsAndRanges() {
        let cmap = toUnicodeCMap(
            """
            1 beginbfchar
            <0064> <0048>
            endbfchar
            1 beginbfrange
            <0007> <012C> <0041>
            endbfrange
            """)
        #expect(cmap.minSourceCid == 7)
        #expect(cmap.maxSourceCid == 300)

        let empty = toUnicodeCMap("")
        #expect(empty.minSourceCid == nil)
        #expect(empty.maxSourceCid == nil)
    }

    /// The explicit table re-keys the map exactly: array index is the CID,
    /// its entry the glyph whose text that CID takes.
    @Test func anExplicitCidToGidTableReKeysTheMap() throws {
        let cmap = toUnicodeCMap(
            """
            4 beginbfchar
            <0064> <0048>
            <0065> <0045>
            <0066> <004C>
            <0067> <0050>
            endbfchar
            """)
        // CID 0 -> glyph 0 (unmapped), 1 -> 103, 2 -> 102, 3 -> 101, 4 -> 100.
        let rekeyed = try #require(cmap.rekeyedByCidToGid([0, 103, 102, 101, 100]))

        #expect(rekeyed.charMap[1] == "P")
        #expect(rekeyed.charMap[2] == "L")
        #expect(rekeyed.charMap[3] == "E")
        #expect(rekeyed.charMap[4] == "H")
        // Glyph 0 is not in the CMap, so CID 0 gets nothing rather than a
        // placeholder.
        #expect(rekeyed.charMap[0] == nil)
        #expect(rekeyed.codeByteLength == 2)
    }

    /// A table pointing at glyphs the CMap never mentions yields nothing,
    /// which is what sends the driver on to the sequential guess.
    @Test func aTableThatMatchesNothingYieldsNoCandidate() {
        let cmap = toUnicodeCMap(
            """
            1 beginbfchar
            <0064> <0048>
            endbfchar
            """)
        #expect(cmap.rekeyedByCidToGid([0, 7, 8, 9]) == nil)
    }

    /// The decision holds until 240 bytes have been sampled, then sticks.
    ///
    /// The remapped sample is English and the primary is not, so the sample
    /// decides for the remap once it is large enough — and keeps deciding
    /// that way even when a later string on its own would not.
    @Test func theDecisionIsWithheldUntilTheSampleIsLargeEnoughAndThenSticks() {
        var decisions = PdfCMapDecisions()

        // Well short of the target: no decision yet, whatever the scores.
        #expect(
            decisions.consider(7, primary: "\u{1}\u{2}", remapped: "the", byteCount: 100) == nil)
        #expect(decisions.choice(7) == nil)

        // Crossing 240 settles it.
        let settled = decisions.consider(
            7, primary: "\u{3}\u{4}", remapped: " quick brown fox jumps", byteCount: 140)
        #expect(settled == .remapped)
        #expect(decisions.choice(7) == .remapped)

        // And it stays settled: this pair alone would favour the primary.
        #expect(
            decisions.consider(7, primary: "readable words here", remapped: "\u{5}", byteCount: 8)
                == .remapped)
    }

    /// Each font decides for itself — the key is the `/ToUnicode` object
    /// number, so one font's verdict cannot leak into another's.
    @Test func decisionsAreHeldPerFont() {
        var decisions = PdfCMapDecisions()
        _ = decisions.consider(7, primary: "\u{1}", remapped: "the quick brown fox", byteCount: 300)
        #expect(decisions.choice(7) == .remapped)
        #expect(decisions.choice(9) == nil)
    }

    /// A near-tie leaves the declared mapping in place: the remapped sample
    /// must beat it by more than five.
    @Test func aNarrowWinLeavesTheDeclaredMappingInPlace() {
        var decisions = PdfCMapDecisions()
        #expect(
            decisions.consider(1, primary: "the cat", remapped: "the cat!", byteCount: 300)
                == .primary)
    }
}
