import Testing

@testable import AnyDoc

/// Splitting a consolidated financial row back into columns.
@Suite struct PdfTableFinancialTests {
    private func item(_ text: String, width: Float, size: Float = 10) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: 100, y: 700, width: width, fontSize: size, fontName: "F1")
    }

    /// A wide item holding nothing but figures is a whole row drawn as one
    /// `Tj`, and is spread evenly across its own width.
    @Test func aWideRowOfFiguresSplits() {
        let parts = pdfTrySplitFinancialItem(item("$ 5,147,649 114,167 — 778,177", width: 400))
        let split = try! #require(parts)
        #expect(split.map(\.text) == ["$ 5,147,649", "114,167", "—", "778,177"])
        // Evenly spaced at the centre of each slice.
        #expect(split[0].x == 150)
        #expect(split[1].x == 250)
        #expect(split[0].width == 90)
    }

    /// The guess is narrow on purpose: a single word disqualifies it.
    @Test func anyWordDisqualifiesTheRow() {
        #expect(pdfTrySplitFinancialItem(item("Land $ 778,177 114,167 5,147", width: 400)) == nil)
        #expect(pdfHasAlphabeticWords("Land 1"))
        #expect(!pdfHasAlphabeticWords("$ 1,234 5,678"))
    }

    /// So does being narrow, or holding fewer than three values.
    @Test func narrowOrShortRowsAreLeftAlone() {
        #expect(pdfTrySplitFinancialItem(item("$ 1,234 5,678 9,012", width: 100)) == nil)
        #expect(pdfTrySplitFinancialItem(item("$ 1,234 5,678", width: 400)) == nil)
    }

    @Test func aDollarSignBindsToItsFigure() {
        #expect(pdfTokenizeFinancialValues("$ 1,234 5,678") == ["$ 1,234", "5,678"])
        // A dollar with nothing to bind to is not a value at all.
        #expect(pdfTokenizeFinancialValues("$ x") == nil)
        #expect(pdfTokenizeFinancialValues("1,234 total") == nil)
    }

    @Test func financialTokensAllowTheirPunctuation() {
        for token in ["1,234", "(2,340)", "-5", "+3", "99.5%", "778,177"] {
            #expect(pdfIsNumericToken(token), "\(token) should be a figure")
        }
        #expect(!pdfIsNumericToken("x1"))
        // The four dashes that mark a nil entry.
        for dash in ["—", "–", "-", "‒"] { #expect(pdfIsDashToken(dash)) }
    }

    /// Items that do not split pass through, and the map still points home.
    @Test func expansionKeepsAMapToTheOriginals() {
        let items = [
            item("Land", width: 40),
            item("$ 1,234 5,678 9,012", width: 400),
        ]
        let (expanded, map) = pdfExpandConsolidatedItems(items)
        #expect(expanded.count == 4)
        #expect(map == [0, 1, 1, 1])
    }
}
