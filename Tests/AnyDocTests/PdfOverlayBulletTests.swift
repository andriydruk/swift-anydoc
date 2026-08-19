// The two branches of the preserved-line merge that the overlay fixture does
// not reach.
//
// A bullet on a preserved line is allowed a wider gap — 1.2 times the font
// size rather than 0.5 — because the text it introduces was drawn separately;
// and it always takes a space, whatever the gap says.
import Testing

@testable import AnyDoc

@Suite struct PdfOverlayBulletTests {
    private func item(_ text: String, x: Float, width: Float, mcid: Int? = 0) -> PdfLayoutItem {
        var made = PdfLayoutItem(
            text: text, x: x, y: 700, width: width, fontSize: 12, fontName: "F1")
        made.mcid = mcid
        return made
    }

    /// A bullet, a short fragment, and an overlay that backtracks over it.
    /// The line qualifies as preserved, so the bullet's 14pt gap is inside
    /// the widened 14.4pt limit and the merge takes it.
    @Test func aBulletOnAPreservedLineMergesAndTakesASpace() {
        let items = [
            item("\u{2022}", x: 72, width: 0),
            item("Th", x: 82, width: 12),
            item("the quick brown fox", x: 78, width: 114),
        ]
        #expect(pdfShouldPreserveOverlappingStreamOrder(items))

        // The bullet's 10pt gap is outside the ordinary 6pt limit and inside
        // the widened 14.4pt one, so the whole line fuses into one item —
        // and the bullet keeps its space.
        let merged = pdfMergeTextItems(items)
        #expect(merged.count == 1)
        #expect(merged[0].text == "\u{2022} Ththe quick brown fox")
    }

    /// Without marked content the same geometry is not preserved, the bullet
    /// keeps the narrow 6pt limit, and the 14pt gap breaks the merge.
    @Test func anUntaggedBulletKeepsTheNarrowLimit() {
        let items = [
            item("\u{2022}", x: 72, width: 0, mcid: nil),
            item("Th", x: 82, width: 12, mcid: nil),
            item("the quick brown fox", x: 78, width: 114, mcid: nil),
        ]
        #expect(!pdfShouldPreserveOverlappingStreamOrder(items))
        // Sorted by x instead, so the overlay leads and the short fragment
        // trails — the opposite arrangement to the preserved line above.
        let merged = pdfMergeTextItems(items)
        #expect(merged[0].text.hasPrefix("\u{2022} the quick"))
        #expect(!merged[0].text.contains("Ththe"))
    }
}
