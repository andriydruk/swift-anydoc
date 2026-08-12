import Testing

@testable import AnyDoc

/// Bare-struct-name repair and line ordering, pinned without the oracle.
@Suite struct PdfStructNamesTests {
    private let root = "/StructTreeRoot"

    private func fixed(_ text: String) -> String {
        String(decoding: pdfFixBareStructNames(Array(text.utf8)), as: UTF8.self)
    }

    @Test func aBareNameGetsItsSlash() {
        #expect(fixed(root + " /S Code") == root + " /S /Code")
    }

    @Test func theByteAfterARepairedNameIsDeleted() {
        // An upstream bug, reproduced deliberately: the output buffer's length
        // doubles as the input cursor, and each repair writes one byte more
        // than it reads, so the cursor runs permanently ahead. Verified
        // against the reference binary.
        #expect(fixed(root + " /S Code>") == root + " /S /Code")
        #expect(fixed(root + " /S Code\nNEXT") == root + " /S /CodeNEXT")
        // And it compounds: every repair loses its own following byte.
        #expect(
            fixed(root + " /S Code /S Table /S P") == root + " /S /Code/S /Table/S /P")
    }

    @Test func aCorrectNameIsLeftAlone() {
        let text = root + " /S /Code"
        #expect(fixed(text) == text)
    }

    @Test func withoutAStructTreeNothingIsTouched() {
        // The quick check bails before any scanning, so even a genuine fault
        // survives when the document has no structure tree at all.
        let text = "no struct tree here /S Code"
        #expect(fixed(text) == text)
    }

    @Test func aLongerNameIsNotSwallowedByItsPrefix() {
        // `H` is listed before `H1`, but the delimiter check rejects it — the
        // `1` is not a delimiter — so the longer name is reached.
        #expect(fixed(root + " /S H1") == root + " /S /H1")
        #expect(fixed(root + " /S LI") == root + " /S /LI")
        #expect(fixed(root + " /S LBody") == root + " /S /LBody")
    }

    @Test func aWordThatMerelyStartsWithANameIsNotRepaired() {
        let text = root + " /S Codex"
        #expect(fixed(text) == text)
    }

    @Test func unknownWordsAreNotRepaired() {
        // Patching any bare word would corrupt dictionaries where `S` means
        // something else.
        let text = root + " /S Unknown"
        #expect(fixed(text) == text)
    }

    @Test func everyDelimiterEndsAName() {
        // Each of these terminates the name, so each is repaired — and each
        // delimiter is then eaten by the cursor bug above, which is why the
        // expected output has no trailing delimiter.
        for delimiter in [">", "/", "\n", "\r", " "] {
            #expect(fixed(root + " /S Code" + delimiter + "x") == root + " /S /Codex")
        }
        // A name running to the end of the buffer counts too, and there is no
        // following byte for the bug to take.
        #expect(fixed(root + " /S Code") == root + " /S /Code")
    }

    @Test func correctAndBareNamesCanMix() {
        // The correct one is untouched, so nothing precedes it to shift; the
        // bare one loses the byte after it, but here that is the end.
        #expect(fixed(root + " /S /Code /S Table") == root + " /S /Code /S /Table")
    }

    @Test func truncatedInputIsSafe() {
        for text in [root, root + " /S", root + " /S ", ""] {
            #expect(fixed(text) == text)
        }
    }

    @Test func twoSpacesAreNotThePattern() {
        // The pattern is exactly `/S `, so the second space is where the name
        // would have to start.
        let text = root + " /S  Code"
        #expect(fixed(text) == text)
    }

    // MARK: line ordering

    private func item(_ text: String, _ x: Float) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: 700, width: 20, fontSize: 10, fontName: "F1")
    }

    @Test func latinLinesRunLeftToRight() {
        var items = [item("c", 300), item("a", 100), item("b", 200)]
        pdfSortLineItems(&items)
        #expect(items.map(\.text) == ["a", "b", "c"])
    }

    @Test func arabicLinesRunRightToLeft() {
        let arabic = "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}"
        var items = [item(arabic, 100), item(arabic, 300), item(arabic, 200)]
        pdfSortLineItems(&items)
        #expect(items.map(\.x) == [300, 200, 100])
    }

    @Test func directionIsDecidedByTheWholeLine() {
        // A Latin word embedded in Arabic does not flip the line.
        let arabic = "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}"
        var items = [item("ab", 100), item(arabic, 300), item(arabic, 200)]
        pdfSortLineItems(&items)
        #expect(items.map(\.x) == [300, 200, 100])
    }

    @Test func itemsAtTheSameXKeepTheirOrder() {
        var items = [item("first", 100), item("second", 100), item("third", 100)]
        pdfSortLineItems(&items)
        #expect(items.map(\.text) == ["first", "second", "third"])
    }
}
