import Testing

@testable import AnyDoc

/// The ToUnicode stream parser, pinned against the reference's own
/// `ToUnicodeCMap::parse` answers.
///
/// Most of these record behaviours the wave-5 port got **wrong** and wave 97
/// fixed. They are worth keeping as prose because each one is a place where
/// a simpler design is tempting and produces different text.
@Suite struct PdfCMapScannerTests {
    private let header = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap

        """
    private let footer = """
        endcmap
        end
        end

        """

    private func cmap(_ body: String) -> PdfToUnicodeCMap {
        parsePdfToUnicode(Array((header + body + footer).utf8))
    }

    private func show(_ text: String?) -> String {
        guard let text else { return "-" }
        return text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: ".")
    }

    // MARK: - the four wave-97 fixes

    @Test func directMappingsOutrankRangesInBothOrders() {
        // The reference keeps `char_map` and `ranges` apart and consults the
        // first before the second. A port that flattens both into one
        // dictionary gets whichever was written last — which is wrong for
        // one of the two orders whatever it picks.
        let charFirst = cmap(
            "1 beginbfchar\n<01> <0041>\nendbfchar\n1 beginbfrange\n<01> <03> <0061>\nendbfrange\n")
        let rangeFirst = cmap(
            "1 beginbfrange\n<01> <03> <0061>\nendbfrange\n1 beginbfchar\n<01> <0041>\nendbfchar\n")
        for map in [charFirst, rangeFirst] {
            #expect(show(map.lookup(1)) == "0041")
            #expect(show(map.lookup(2)) == "0062")
            #expect(show(map.lookup(3)) == "0063")
        }
    }

    @Test func aOneByteDestinationIsLegal() {
        // No specification allows it; producers write it. Rejecting a
        // two-digit destination loses the character entirely.
        #expect(show(cmap("1 beginbfchar\n<01> <41>\nendbfchar\n").lookup(1)) == "0041")
        #expect(show(cmap("1 beginbfchar\n<01> <09>\nendbfchar\n").lookup(1)) == "0009")
        // Except when it is a control character other than tab or newline.
        #expect(cmap("1 beginbfchar\n<01> <00>\nendbfchar\n").isEmpty)
    }

    @Test func anUnpairedSurrogateVoidsItsWholeDestination() {
        // `D992` is a high surrogate and `C581` is not a low one, so the
        // destination is not valid UTF-16 and maps to nothing. Dropping just
        // the unpaired half and keeping the rest would invent a character.
        #expect(cmap("1 beginbfchar\n<24> <D992C581>\nendbfchar\n").isEmpty)
        #expect(cmap("1 beginbfchar\n<01> <D83C>\nendbfchar\n").isEmpty)
        // A real pair is one scalar and survives.
        #expect(show(cmap("1 beginbfchar\n<01> <D83CDF1F>\nendbfchar\n").lookup(1)) == "1F31F")
    }

    @Test func theCodeWidthComesFromTheEntriesWhenTheCodespaceDisagrees() {
        // `<0000> <FFFF>` beside one-byte entries is boilerplate, not a
        // description — so the entries win.
        let boilerplate = cmap(
            "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
                + "1 beginbfchar\n<01> <0041>\nendbfchar\n")
        #expect(boilerplate.codeByteLength == 1)
        // Two-byte entries under the same codespace keep two.
        let genuine = cmap(
            "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
                + "1 beginbfchar\n<0041> <0061>\nendbfchar\n")
        #expect(genuine.codeByteLength == 2)
        // With no codespace at all the entries decide alone.
        #expect(cmap("1 beginbfchar\n<01> <0041>\nendbfchar\n").codeByteLength == 1)
        #expect(cmap("1 beginbfchar\n<0041> <0061>\nendbfchar\n").codeByteLength == 2)
    }

    // MARK: - ranges

    @Test func aRangeBaseIncrementsWithTheCode() {
        let map = cmap("1 beginbfrange\n<01> <03> <0041>\nendbfrange\n")
        #expect(show(map.lookup(1)) == "0041")
        #expect(show(map.lookup(3)) == "0043")
        #expect(show(map.lookup(4)) == "-")
    }

    @Test func anInvertedRangeIsKeptButNeverMatches() {
        // The reference stores the range unchecked, so the CMap is *not*
        // empty — which a caller can observe — yet no code resolves.
        let map = cmap("1 beginbfrange\n<03> <01> <0041>\nendbfrange\n")
        #expect(!map.isEmpty)
        for code in UInt32(0)...4 { #expect(show(map.lookup(code)) == "-", "\(code)") }
    }

    @Test func aMultiScalarRangeBaseDropsTheRange() {
        // A ligature base maps to nothing at all rather than to `ff`, which
        // loses text the font really shows. Reproduced deliberately.
        #expect(cmap("1 beginbfrange\n<01> <03> <006600660069>\nendbfrange\n").isEmpty)
    }

    @Test func aRangeArrayFillsFromTheStartAndStopsAtTheEnd() {
        let map = cmap("1 beginbfrange\n<01> <03> [<0041> <0042> <0043>]\nendbfrange\n")
        #expect(show(map.lookup(1)) == "0041")
        #expect(show(map.lookup(3)) == "0043")
        #expect(show(map.lookup(4)) == "-")
        // Fewer entries than the range covers simply leaves the rest unmapped.
        let short = cmap("1 beginbfrange\n<01> <03> [<0041> <0042>]\nendbfrange\n")
        #expect(show(short.lookup(3)) == "-")
    }

    // MARK: - destinations

    @Test func alternativeListsCollapseAndOrdinaryRunsDoNot() {
        #expect(show(cmap("1 beginbfchar\n<01> <00200009>\nendbfchar\n").lookup(1)) == "0009")
        #expect(show(cmap("1 beginbfchar\n<01> <002D00AD>\nendbfchar\n").lookup(1)) == "002D")
        #expect(show(cmap("1 beginbfchar\n<01> <00200020>\nendbfchar\n").lookup(1)) == "0020.0020")
        #expect(
            show(cmap("1 beginbfchar\n<01> <006600660069>\nendbfchar\n").lookup(1))
                == "0066.0066.0069")
    }

    @Test func aMalformedDestinationIsSkipped() {
        // An odd digit count is rejected outright.
        #expect(cmap("1 beginbfchar\n<01> <004>\nendbfchar\n").isEmpty)
        #expect(cmap("1 beginbfchar\n<01> <>\nendbfchar\n").isEmpty)
    }

    @Test func aCMapWithNothingMappedIsEmpty() {
        #expect(cmap("").isEmpty)
        #expect(cmap("1 beginbfchar\nendbfchar\n").isEmpty)
        #expect(
            cmap("1 begincodespacerange\n<00> <FF>\nendcodespacerange\n").isEmpty)
    }
}
