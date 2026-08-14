import Testing

@testable import AnyDoc

/// The three vetoes that stop a table-of-contents entry or a display
/// equation being promoted to a heading.
@Suite struct PdfHeadingFragmentTests {

    // MARK: - is_toc_entry_line

    @Test func dotsLeadingToAPageNumberAreATocEntry() {
        #expect(pdfIsTocEntryLine("Measurement Lab worksheet ... 3"))
        #expect(pdfIsTocEntryLine("Worksheet .... 42"))
        // Three dots is the floor.
        #expect(!pdfIsTocEntryLine("Worksheet ..12"))
        #expect(pdfIsTocEntryLine("Worksheet ...12"))
    }

    @Test func thePageNumberIsOneToFourDigits() {
        #expect(pdfIsTocEntryLine("Worksheet ...1234"))
        #expect(!pdfIsTocEntryLine("Worksheet ...12345"))
        #expect(!pdfIsTocEntryLine("Worksheet ... "))
    }

    @Test func theDotsMustImmediatelyPrecedeTheNumber() {
        // Whitespace between them is allowed; anything else is not.
        #expect(pdfIsTocEntryLine("Worksheet ...   3"))
        #expect(!pdfIsTocEntryLine("Worksheet 3"))
        #expect(!pdfIsTocEntryLine("Worksheet ... a3"))
    }

    @Test func aSingleGroupOfDotsIsEnoughHere() {
        // Which is the point: `pdfHasDotLeaders` wants two groups and so
        // misses this shape entirely.
        #expect(!pdfHasDotLeaders("Worksheet ... 3"))
        #expect(pdfIsTocEntryLine("Worksheet ... 3"))
    }

    // MARK: - is_toc_marker_heading

    @Test func theContentsHeadingIsRecognised() {
        #expect(pdfIsTocMarkerHeading("Contents"))
        #expect(pdfIsTocMarkerHeading("Table of Contents"))
        // Case and surrounding space do not matter.
        #expect(pdfIsTocMarkerHeading("  TABLE OF CONTENTS  "))
        #expect(pdfIsTocMarkerHeading("contents"))
    }

    @Test func aTrailingColonIsStripped() {
        #expect(pdfIsTocMarkerHeading("Contents:"))
        #expect(pdfIsTocMarkerHeading("Contents :"))
        #expect(pdfIsTocMarkerHeading("Table of Contents:"))
    }

    @Test func anythingElseIsAnOrdinaryHeading() {
        #expect(!pdfIsTocMarkerHeading("Contents of the Book"))
        #expect(!pdfIsTocMarkerHeading("Content"))
        #expect(!pdfIsTocMarkerHeading("Contents page"))
        // Inner spacing is not normalised, so a doubled space fails.
        #expect(!pdfIsTocMarkerHeading("Table  of  Contents"))
    }

    // MARK: - is_heading_fragment

    @Test func aShortLowercaseLineIsAFragment() {
        // Mid-sentence fragments beside display maths. A real heading that
        // short starts with a capital.
        #expect(pdfIsHeadingFragment("or inversely"))
        #expect(pdfIsHeadingFragment("and therefore"))
        #expect(pdfIsHeadingFragment("inversely"))
        #expect(!pdfIsHeadingFragment("Or Inversely"))
        // Three words is past the bar whatever the case.
        #expect(!pdfIsHeadingFragment("or inversely then"))
    }

    @Test func theFirstAlphabeticCharacterDecidesTheCase() {
        // Leading digits and punctuation are skipped when looking for it.
        #expect(pdfIsHeadingFragment("3 or"))
        #expect(!pdfIsHeadingFragment("3 Or"))
        // With no letters at all there is nothing to judge.
        #expect(!pdfIsHeadingFragment("42"))
    }

    @Test func aTrailingEquationNumberAloneIsNotEnough() {
        // Real headings end with parenthesised numbers too, so the suffix
        // needs corroboration.
        #expect(!pdfIsHeadingFragment("Nicaea (325)"))
        #expect(!pdfIsHeadingFragment("Some Heading (12)"))
        #expect(!pdfIsHeadingFragment("Plain words (9)"))
    }

    @Test func punctuationBeforeTheNumberIsCorroboration() {
        #expect(pdfIsHeadingFragment("Total mass, (4)"))
        #expect(pdfIsHeadingFragment("Total mass: (4)"))
        #expect(!pdfIsHeadingFragment("Total mass (4)"))
    }

    @Test func aMathematicalOperatorAnywhereIsCorroboration() {
        #expect(pdfIsHeadingFragment("S = kB ln W, (2)"))
        #expect(pdfIsHeadingFragment("E = mc2 (5)"))
        #expect(pdfIsHeadingFragment("Rate ≤ limit (6)"))
        #expect(pdfIsHeadingFragment("Value ± error (7)"))
        #expect(pdfIsHeadingFragment("Sum ∑ terms (8)"))
    }

    @Test func anEquationNumberIsOneToThreeDigitsInBrackets() {
        #expect(!pdfIsHeadingFragment("Heading = (1234)"))
        #expect(!pdfIsHeadingFragment("Heading = ()"))
        #expect(!pdfIsHeadingFragment("Heading = (a)"))
        #expect(pdfIsHeadingFragment("Heading = (123)"))
    }

    @Test func aPageOfTotalRunningHeaderIsAFragment() {
        // `LIVSMEDELSVERKET PM 2 (10)` — recognised by the pair reading as a
        // plausible page-of-total, with no maths anywhere in the line.
        #expect(pdfIsHeadingFragment("LIVSMEDELSVERKET PM 2 (10)"))
        #expect(pdfIsHeadingFragment("PM 2 (2)"))
        // Page past the total is not that shape.
        #expect(!pdfIsHeadingFragment("PM 10 (2)"))
        // Nor is a non-numeric predecessor.
        #expect(!pdfIsHeadingFragment("PM 2x (10)"))
    }

    @Test func aLeadInNeedsBothAColonAndAnEquationNumber() {
        #expect(pdfIsHeadingFragment("Rearranging Equation (8) gives:"))
        #expect(pdfIsHeadingFragment("See (12) below:"))
        // A colon alone proves nothing — real headings end with them.
        #expect(!pdfIsHeadingFragment("Procedure:"))
        #expect(!pdfIsHeadingFragment("Steps for Using the Microscope:"))
        #expect(!pdfIsHeadingFragment("Equation 8 gives:"))
    }

    @Test func theSuffixRuleSplitsOnSpacesNotWhitespace() {
        // The reference uses `rsplit(' ')`, so a tab before the equation
        // number leaves it part of one long token and the branch is missed.
        #expect(pdfIsHeadingFragment("S = kB ln W, (2)"))
        #expect(!pdfIsHeadingFragment("S = kB ln W,\t(2)"))
    }
}
