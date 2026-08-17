import Testing

@testable import AnyDoc

/// The size text is rendered at, under a transform.
@Suite struct PdfEffectiveFontSizeTests {
    @Test func anUprightMatrixReportsItsNominalSize() {
        #expect(pdfEffectiveFontSize(10, (1, 0, 0, 1, 0, 0)) == 10)
    }

    @Test func aQuarterTurnKeepsItsSize() {
        // This is the case that mattered: a 90° rotation puts the scale
        // entirely into `b` and `c` and leaves `d` at zero. Reading the
        // vertical component alone — which this port did until wave 107 —
        // reports size zero, so every rotated run was invisible to heading
        // detection and to the body-size statistics.
        #expect(pdfEffectiveFontSize(10, (0, 1, -1, 0, 400, 200)) == 10)
        #expect(pdfEffectiveFontSize(10, (0, -1, 1, 0, 0, 0)) == 10)
    }

    @Test func theLargerAxisWins() {
        // Anisotropic scaling takes the larger of the two, so text stretched
        // horizontally is measured by its width rather than its height.
        #expect(pdfEffectiveFontSize(10, (3, 0, 0, 1, 0, 0)) == 30)
        #expect(pdfEffectiveFontSize(10, (1, 0, 0, 3, 0, 0)) == 30)
    }

    @Test func uniformScalingMultiplies() {
        #expect(pdfEffectiveFontSize(10, (2, 0, 0, 2, 0, 0)) == 20)
        #expect(pdfEffectiveFontSize(12, (0.5, 0, 0, 0.5, 0, 0)) == 6)
    }

    @Test func aReflectionKeepsItsSize() {
        // A negative scale is still a scale: the magnitude is what counts.
        #expect(pdfEffectiveFontSize(10, (-1, 0, 0, -1, 0, 0)) == 10)
    }

    @Test func aDegenerateMatrixCollapsesToZero() {
        // A zero matrix draws nothing, and reports nothing rather than
        // guessing at the nominal size.
        #expect(pdfEffectiveFontSize(10, (0, 0, 0, 0, 0, 0)) == 0)
    }
}
