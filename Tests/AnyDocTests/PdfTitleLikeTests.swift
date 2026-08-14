import Testing

@testable import AnyDoc

/// Whether a line reads as a title, and what disqualifies it.
@Suite struct PdfTitleLikeTests {

    private func title(_ text: String, numbered: Bool = false, bold: Bool = false) -> Bool {
        pdfTitleLike(text, numbered: numbered, bold: bold)
    }

    // MARK: - title_like

    @Test func aCapitalisedShortLineIsATitle() {
        #expect(title("The Quick Brown Fox"))
        #expect(title("Introduction"))
    }

    @Test func sentencePunctuationDisqualifies() {
        // The clearest sign a line is prose rather than a heading.
        #expect(!title("Ends with period."))
        #expect(!title("Ends with comma,"))
        #expect(!title("Ends with semicolon;"))
        // A colon does not — real headings end with them constantly.
        #expect(title("Ends With Colon:"))
    }

    @Test func theLengthBoundsAreInclusive() {
        // Capitalised throughout, since a one-or-two-word lowercase line is
        // caught by wave 73's fragment rule before the length is reached.
        #expect(!title("Abc"))
        #expect(title("Abcd"))
        #expect(title(String(repeating: "X", count: 140)))
        #expect(!title(String(repeating: "X", count: 141)))
        // One to twelve words.
        #expect(title("A B C D E F G H I J K L"))
        #expect(!title("A B C D E F G H I J K L M"))
        #expect(!title(""))
    }

    @Test func aLineWithNoLettersIsNotATitle() {
        #expect(!title("1234"))
        #expect(!title("!!!!"))
    }

    @Test func theWave73VetoesApplyHere() {
        // Bullets, captions, contents entries and equation fragments are all
        // refused whatever their capitalisation.
        #expect(!title("• dot item"))
        #expect(!title("Figure 1: A caption here"))
        #expect(!title("Section ... 42"))
        #expect(!title("S = kB ln W, (2)"))
    }

    @Test func mostWordsMustBeCapitalised() {
        // Measured over the words carrying letters, by their first letter.
        #expect(!title("a lowercase heading"))
        #expect(title("Mixed Case Heading Here"))
        // Half is enough, since the comparison is inclusive.
        #expect(title("Two Capitalised of four"))
    }

    @Test func beingNumberedOrBoldStandsInForCapitalisation() {
        #expect(!title("a lowercase heading"))
        #expect(title("a lowercase heading", bold: true))
        #expect(title("a lowercase heading", numbered: true))
    }

    @Test func aNumberedLineIsLetThroughTheListVeto() {
        // Telling a section run from an ordinary ordered list is the
        // sequence logic's job, not this predicate's — so `1.` passes when
        // it is known to be numbered and is refused when it is not.
        #expect(title("1. Numbered Heading", numbered: true))
        #expect(!title("- bullet item", numbered: true))
    }

    // MARK: - complete_sidebar_label

    @Test func anOrdinaryLabelIsComplete() {
        #expect(pdfCompleteSidebarLabel("Complete Label"))
        #expect(pdfCompleteSidebarLabel("one"))
    }

    @Test func aTrailingHyphenMeansItContinues() {
        #expect(!pdfCompleteSidebarLabel("Wrapped label-"))
    }

    @Test func aDanglingPrepositionMeansItContinues() {
        #expect(!pdfCompleteSidebarLabel("ends with the"))
        #expect(!pdfCompleteSidebarLabel("ends with of"))
        // Case-insensitively, since the comparison lowercases first.
        #expect(!pdfCompleteSidebarLabel("ends with THE"))
        // But only whole words — `android` is not `and`.
        #expect(pdfCompleteSidebarLabel("label with android"))
    }

    @Test func aMarginReferenceIsNavigationNotAHeading() {
        // One letter and a number: `G 02`.
        #expect(!pdfCompleteSidebarLabel("G 02"))
        #expect(!pdfCompleteSidebarLabel("G 2"))
        // Two letters, or a non-numeric second word, is an ordinary label.
        #expect(pdfCompleteSidebarLabel("GG 02"))
        #expect(pdfCompleteSidebarLabel("G 0a"))
        // And the shape needs exactly two words.
        #expect(pdfCompleteSidebarLabel("G"))
    }
}
