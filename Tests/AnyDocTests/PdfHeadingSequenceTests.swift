import Testing

@testable import AnyDoc

/// The tests that decide when a run of similar lines is a heading level.
@Suite struct PdfHeadingSequenceTests {

    private func item(_ x: Float, _ y: Float, width: Float = 100, _ text: String = "run")
        -> PdfLayoutItem
    {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: 12, fontName: "F1")
    }

    private func line(_ items: [PdfLayoutItem], page: Int = 1) -> PdfTextLine {
        PdfTextLine(items: items, y: items.first?.y ?? 0, page: page)
    }

    // MARK: - has_displaced_baseline_peer

    @Test func aLoneRunHasNoPeer() {
        #expect(!pdfHasDisplacedBaselinePeer([line([item(20, 700)])], 0))
        #expect(!pdfHasDisplacedBaselinePeer([], 0))
        // An out-of-range index is refused rather than trapping.
        #expect(!pdfHasDisplacedBaselinePeer([line([item(20, 700)])], 5))
    }

    @Test func aWideVoidInsideTheLineIsAColumnBoundary() {
        // The peer may already have been grouped into this line, so the gaps
        // between its own runs are checked first. 24pt is the bar.
        func withGap(_ gap: Float) -> [PdfTextLine] {
            [line([item(20, 700), item(120 + gap, 700)])]
        }
        #expect(!pdfHasDisplacedBaselinePeer(withGap(23), 0))
        #expect(pdfHasDisplacedBaselinePeer(withGap(24), 0))
    }

    @Test func runsAreSortedBeforeTheirGapsAreMeasured() {
        // Given out of order, the void is still found.
        let unsorted = [line([item(200, 700), item(20, 700, width: 60)])]
        #expect(pdfHasDisplacedBaselinePeer(unsorted, 0))
    }

    @Test func aNegativeWidthIsFlooredAtZero() {
        // A bad width cannot manufacture a gap by reaching backwards: the
        // right edge is taken as the run's own x. Twenty points apart is
        // under the bar, where an unfloored -50 would have made it seventy.
        let odd = [line([item(20, 700, width: -50), item(40, 700)])]
        #expect(!pdfHasDisplacedBaselinePeer(odd, 0))
        // And the same geometry with a zero width behaves identically.
        let zero = [line([item(20, 700, width: 0), item(40, 700)])]
        #expect(!pdfHasDisplacedBaselinePeer(zero, 0))
    }

    @Test func aSeparateLineAtTheSameBaselineCounts() {
        func peerAt(_ x: Float) -> [PdfTextLine] {
            [line([item(20, 700)]), line([item(x, 700)])]
        }
        #expect(!pdfHasDisplacedBaselinePeer(peerAt(43), 0))
        #expect(pdfHasDisplacedBaselinePeer(peerAt(44), 0))
    }

    @Test func theBaselineToleranceIsTwoPoints() {
        func peerAt(_ y: Float) -> [PdfTextLine] {
            [line([item(20, 700)]), line([item(200, y)])]
        }
        #expect(pdfHasDisplacedBaselinePeer(peerAt(702), 0))
        #expect(!pdfHasDisplacedBaselinePeer(peerAt(703), 0))
    }

    @Test func aPeerOnAnotherPageDoesNotCount() {
        let split = [line([item(20, 700)], page: 1), line([item(200, 700)], page: 2)]
        #expect(!pdfHasDisplacedBaselinePeer(split, 0))
    }

    // MARK: - numbering_has_section_separation

    private func candidate(_ index: Int) -> PdfHeadingCandidate {
        PdfHeadingCandidate(
            lineIndex: index, fontSize: 12,
            style: PdfVisualStyle(font: "F1", xBucket: 0, bold: false), numbering: nil)
    }

    @Test func adjacentNumberedLinesAreAListNotSections() {
        // Genuine section headings have body content between them, so a
        // compact `1.` / `1.1.` run stays with the list formatter.
        let onePage = (0..<6).map { _ in line([], page: 1) }
        #expect(!pdfNumberingHasSectionSeparation(candidate(0), candidate(1), onePage))
        #expect(!pdfNumberingHasSectionSeparation(candidate(0), candidate(2), onePage))
        // Two intervening lines is the bar.
        #expect(pdfNumberingHasSectionSeparation(candidate(0), candidate(3), onePage))
        // And the order does not matter.
        #expect(pdfNumberingHasSectionSeparation(candidate(3), candidate(0), onePage))
    }

    @Test func aPageBoundarySettlesItOutright() {
        let across = [line([], page: 1)] + (0..<5).map { _ in line([], page: 2) }
        #expect(pdfNumberingHasSectionSeparation(candidate(0), candidate(1), across))
    }

    // MARK: - sequence_level

    private func numbered(_ depth: Int, size: Float = 12, bold: Bool = false)
        -> PdfHeadingCandidate
    {
        PdfHeadingCandidate(
            lineIndex: 0, fontSize: size,
            style: PdfVisualStyle(font: "F1", xBucket: 0, bold: bold),
            numbering: depth > 0
                ? PdfNumbering(
                    kind: .decimal, depth: depth, parts: [UInt32](repeating: 1, count: depth))
                : nil)
    }

    @Test func numberingDepthIsTheLevel() {
        #expect(pdfSequenceLevel(numbered(1), bodySize: 10, tiers: [24, 16]) == 1)
        #expect(pdfSequenceLevel(numbered(3), bodySize: 10, tiers: [24, 16]) == 3)
        // Even when the size says otherwise — numbering wins outright.
        #expect(pdfSequenceLevel(numbered(3, size: 24), bodySize: 10, tiers: [24, 16]) == 3)
    }

    @Test func theLevelIsClampedToWhatMarkdownOffers() {
        #expect(pdfSequenceLevel(numbered(7), bodySize: 10, tiers: []) == 6)
        #expect(pdfSequenceLevel(numbered(12), bodySize: 10, tiers: []) == 6)
    }

    @Test func withoutNumberingSizeDecides() {
        #expect(pdfSequenceLevel(numbered(0, size: 24), bodySize: 10, tiers: [24, 16]) == 1)
        #expect(pdfSequenceLevel(numbered(0, size: 16), bodySize: 10, tiers: [24, 16]) == 2)
    }

    @Test func aSizeThatFailsStillBecomesAHeadingByWeight() {
        // The bold fallback is the *fallback*, not a refusal — which is what
        // admits a bold section heading set at exactly body size.
        #expect(pdfSequenceLevel(numbered(0, size: 10), bodySize: 10, tiers: [24, 16]) == 3)
        #expect(pdfSequenceLevel(numbered(0, size: 10), bodySize: 10, tiers: []) == 2)
    }
}
