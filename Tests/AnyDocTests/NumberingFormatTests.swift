// Ported from src/shared/numbering.rs tests.
import Testing
@testable import AnyDoc

@Suite struct NumberingFormatTests {
    @Test func percentPatternsTokenize() {
        #expect(
            parsePercentPattern("%1.%2)") == [
                .level(0),
                .literal("."),
                .level(1),
                .literal(")"),
            ])
        #expect(
            parsePercentPattern("Ch. %3:") == [
                .literal("Ch. "),
                .level(2),
                .literal(":"),
            ])
        // `%0` and a trailing `%` are literal.
        #expect(parsePercentPattern("%0%") == [.literal("%0%")])
    }

    @Test func defaultPatternYieldsNoLabel() {
        let pattern = NumberPattern(text: parsePercentPattern("%1."), legal: false)
        let label = compositeLabel(
            pattern, ownMarker: .decimal, ownValue: 3, levelMarker: { _ in .decimal },
            levelValue: { _ in 3 })
        #expect(label == nil)
    }

    @Test func compositePatternRendersParentValues() {
        let pattern = NumberPattern(text: parsePercentPattern("%1-%2)"), legal: false)
        let values: [UInt64] = [2, 5]
        let label = compositeLabel(
            pattern, ownMarker: .lowerAlpha, ownValue: 5,
            levelMarker: { l in l == 0 ? .decimal : .lowerAlpha },
            levelValue: { l in values[min(l, 1)] })
        #expect(label == "2-e)")
    }

    @Test func legalNumberingForcesDecimalReferences() {
        let pattern = NumberPattern(text: parsePercentPattern("%1.%2"), legal: true)
        let label = compositeLabel(
            pattern, ownMarker: .lowerRoman, ownValue: 4,
            levelMarker: { _ in .lowerRoman },
            levelValue: { l in l == 0 ? 2 : 4 })
        #expect(label == "2.4")
    }
}
