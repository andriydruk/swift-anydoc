// Lines the content stream deliberately overlays keep their stream order.
//
// The predicate is deliberately hard to satisfy — a wrong answer reorders
// ordinary text — so these pin the gates that reject rather than the one case
// that accepts.
import Testing

@testable import AnyDoc

@Suite struct PdfOverlayOrderTests {
    private func item(
        _ text: String, x: Float, size: Float = 12, mcid: Int? = 0
    ) -> PdfLayoutItem {
        var made = PdfLayoutItem(
            text: text, x: x, y: 700, width: Float(text.count) * 6, fontSize: size,
            fontName: "F1")
        made.mcid = mcid
        return made
    }

    /// The shape it exists for: a short fragment, then a longer run starting
    /// left of it and extending past, beginning lowercase with a space inside.
    private var overlaid: [PdfLayoutItem] {
        [item("Th", x: 100), item("the quick brown fox", x: 96), item("jumps over", x: 240)]
    }

    @Test func anOverlaidTaggedLineIsPreserved() {
        #expect(pdfShouldPreserveOverlappingStreamOrder(overlaid))
    }

    /// Every gate, each checked by breaking exactly one thing.
    @Test func eachGateRejectsOnItsOwn() {
        // Fewer than three items.
        #expect(!pdfShouldPreserveOverlappingStreamOrder(Array(overlaid.prefix(2))))

        // No marked content anywhere — the case `overlay-plain.pdf` pins.
        #expect(
            !pdfShouldPreserveOverlappingStreamOrder(
                overlaid.map { item($0.text, x: $0.x, mcid: nil) }))

        // A size differing by more than a quarter.
        var mixed = overlaid
        mixed[2] = item("jumps over", x: 240, size: 20)
        #expect(!pdfShouldPreserveOverlappingStreamOrder(mixed))

        // The overlay starting uppercase, so the backtrack is unexplained.
        var upper = overlaid
        upper[1] = item("The quick brown fox", x: 96)
        #expect(!pdfShouldPreserveOverlappingStreamOrder(upper))

        // No space or hyphen in the first 24 characters.
        var unbroken = overlaid
        unbroken[1] = item("thequickbrownfoxjumpsoverxx", x: 96)
        #expect(!pdfShouldPreserveOverlappingStreamOrder(unbroken))

        // Mostly mathematical symbols, which overlap on purpose.
        #expect(
            !pdfShouldPreserveOverlappingStreamOrder([
                item("^", x: 100), item("=+ [x]", x: 96), item("<>|", x: 240),
            ]))

        // No backtrack at all: strictly increasing x.
        #expect(
            !pdfShouldPreserveOverlappingStreamOrder([
                item("Th", x: 96), item("the quick brown fox", x: 130),
                item("jumps over", x: 260),
            ]))
    }

    @Test func theHelpersMatchTheirDefinitions() {
        #expect(pdfIsShortAlphaFragment("Th"))
        #expect(pdfIsShortAlphaFragment("abcd"))
        #expect(!pdfIsShortAlphaFragment("abcde"))
        #expect(!pdfIsShortAlphaFragment("a1"))
        #expect(!pdfIsShortAlphaFragment(""))

        #expect(pdfHasPhraseContinuationShape("the quick"))
        #expect(pdfHasPhraseContinuationShape("well-known"))
        #expect(!pdfHasPhraseContinuationShape("unbrokenwordwithoutanyspace"))
        // Only the first 24 characters count.
        #expect(!pdfHasPhraseContinuationShape(String(repeating: "a", count: 24) + " b"))
    }
}
