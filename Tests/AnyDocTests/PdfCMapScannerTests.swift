import Testing

@testable import AnyDoc

/// The ToUnicode stream scanner, checked against the reference's own
/// `ToUnicodeCMap::parse` answers.
@Suite struct PdfCMapScannerTests {
    private func parse(_ stream: String) -> PdfToUnicodeCMap {
        parsePdfToUnicode(Array(stream.utf8))
    }

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

    private func cmap(_ body: String) -> PdfToUnicodeCMap { parse(header + body + footer) }

    private func show(_ text: String?) -> String {
        guard let text else { return "-" }
        return text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: ".")
    }

    @Test func aWhitespaceListCollapsesInTheScannerToo() {
        // The reference answers 0009 for both, because its destination
        // conversion normalises a malformed alternatives list.
        #expect(show(cmap("1 beginbfchar\n<01> <00200009>\nendbfchar\n").lookup(1)) == "0009")
        #expect(show(cmap("1 beginbfchar\n<01> <00090020>\nendbfchar\n").lookup(1)) == "0009")
    }

    @Test func aHyphenListCollapsesInTheScannerToo() {
        #expect(show(cmap("1 beginbfchar\n<01> <002D00AD>\nendbfchar\n").lookup(1)) == "002D")
        #expect(show(cmap("1 beginbfchar\n<01> <00AD2010>\nendbfchar\n").lookup(1)) == "002D")
    }

    @Test func ordinaryRunsAreNotCollapsed() {
        #expect(show(cmap("1 beginbfchar\n<01> <00200020>\nendbfchar\n").lookup(1)) == "0020.0020")
        #expect(
            show(cmap("1 beginbfchar\n<01> <006600660069>\nendbfchar\n").lookup(1))
                == "0066.0066.0069")
    }

    @Test func surrogatePairsAndUnpairedHalves() {
        #expect(show(cmap("1 beginbfchar\n<01> <D83CDF1F>\nendbfchar\n").lookup(1)) == "1F31F")
        // An unpaired half maps to nothing at all in the reference.
        let broken = cmap("1 beginbfchar\n<01> <D83C>\n<02> <0041>\nendbfchar\n")
        #expect(show(broken.lookup(1)) == "-")
        #expect(show(broken.lookup(2)) == "0041")
    }
}
