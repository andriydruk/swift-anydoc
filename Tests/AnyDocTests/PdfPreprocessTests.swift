import Testing

@testable import AnyDoc

/// Line preprocessing: wrapped headings, drop caps, and the text-comparison
/// helpers the running-header remover will use.
@Suite struct PdfPreprocessTests {
    private let tiers: [Float] = [14, 12]

    private func line(
        _ text: String, y: Float, size: Float = 10, page: Int = 1, bold: Bool = false,
        mcid: Int? = nil, x: Float = 20
    ) -> PdfTextLine {
        var item = PdfLayoutItem(
            text: text, x: x, y: y, width: 40, fontSize: size, fontName: "F1")
        item.isBold = bold
        item.mcid = mcid
        return PdfTextLine(items: [item], y: y, page: page)
    }

    private func merged(
        _ lines: [PdfTextLine], base: Float = 10, roles: PdfStructRoleMap? = nil
    ) -> [String] {
        pdfMergeHeadingLines(lines, baseSize: base, tiers: tiers, structRoles: roles)
            .map(pdfLineText)
    }

    // MARK: - effective_heading_level

    @Test func aStructTagOutranksTheFontHeuristic() {
        let roles: PdfStructRoleMap = [1: [5: .h2]]
        // Set at title size, but tagged H2 — the tag wins.
        #expect(
            pdfEffectiveHeadingLevel(
                line("Heading", y: 700, size: 20, mcid: 5), baseSize: 10, tiers: tiers,
                structRoles: roles) == 2)
    }

    @Test func aRoleNamingNoLevelFallsThroughToTheFont() {
        // Unlike `pdfResolveLineStructRole`, this does not stop at a role it
        // cannot use — `P` is ignored and the size decides.
        let roles: PdfStructRoleMap = [1: [5: .p]]
        let tagged = pdfEffectiveHeadingLevel(
            line("Heading", y: 700, size: 14, mcid: 5), baseSize: 10, tiers: tiers,
            structRoles: roles)
        let untagged = pdfEffectiveHeadingLevel(
            line("Heading", y: 700, size: 14), baseSize: 10, tiers: tiers, structRoles: nil)
        #expect(tagged == untagged)
    }

    @Test func aLineWithNoItemsReadsTheBaseSize() {
        let empty = PdfTextLine(items: [], y: 700)
        // Body size, so no heading — an empty line is not a title.
        #expect(
            pdfEffectiveHeadingLevel(empty, baseSize: 10, tiers: tiers, structRoles: nil) == nil)
    }

    // MARK: - merge_heading_lines

    @Test func wrappedHeadingFragmentsJoinWithASpace() {
        let result = merged([
            line("About Glenair the", y: 700, size: 14),
            line("Interconnect Company", y: 690, size: 14),
        ])
        #expect(result == ["About Glenair the Interconnect Company"])
    }

    @Test func theHeadingGapIsUnderTwiceTheFontSize() {
        for (gap, expected) in [(Float(27), 1), (28, 2)] {
            let result = merged([
                line("About Glenair the", y: 700, size: 14),
                line("Interconnect Company", y: 700 - gap, size: 14),
            ])
            #expect(result.count == expected, "gap \(gap)")
        }
    }

    @Test func onlySameLevelSamePageDownwardPairsMerge() {
        // Equal baselines, an upward step, a page change and a level change
        // each keep the lines apart.
        #expect(merged([line("A", y: 700, size: 14), line("B", y: 700, size: 14)]).count == 2)
        #expect(merged([line("A", y: 700, size: 14), line("B", y: 710, size: 14)]).count == 2)
        #expect(
            merged([line("A", y: 700, size: 14), line("B", y: 690, size: 14, page: 2)]).count == 2)
        #expect(merged([line("A", y: 700, size: 14), line("B", y: 690, size: 12)]).count == 2)
    }

    @Test func theCombinedHeadingStopsAtTwentyWords() {
        let ten = (0..<10).map { "w\($0)" }.joined(separator: " ")
        for (count, expected) in [(10, 1), (11, 2)] {
            let second = (0..<count).map { "v\($0)" }.joined(separator: " ")
            let result = merged([
                line(ten, y: 700, size: 14), line(second, y: 690, size: 14),
            ])
            #expect(result.count == expected, "\(10 + count) words")
        }
    }

    @Test func threeFragmentsCollapseIntoOne() {
        let result = merged([
            line("One Two", y: 700, size: 14), line("Three Four", y: 690, size: 14),
            line("Five Six", y: 680, size: 14),
        ])
        #expect(result == ["One Two Three Four Five Six"])
    }

    // MARK: - the bold-wrap merge

    private func boldPair(
        previous: String = "of wood pellets and cost", current: String = "structure in Japan",
        gap: Float = 10, previousBold: Bool = true, currentBold: Bool = true
    ) -> [PdfTextLine] {
        [
            line(previous, y: 700, bold: previousBold),
            line(current, y: 700 - gap, bold: currentBold),
        ]
    }

    @Test func aBoldBodySizeWrapMergesDespiteReachingNoTier() {
        #expect(merged(boldPair()) == ["of wood pellets and cost structure in Japan"])
    }

    @Test func theBoldWrapGapIsUnderOnePointSixFonts() {
        #expect(merged(boldPair(gap: 15)).count == 1)
        #expect(merged(boldPair(gap: 16)).count == 2)
    }

    @Test func theContinuationMustStartLowercase() {
        #expect(merged(boldPair(current: "Structure in Japan")).count == 2)
    }

    @Test func terminalPunctuationEndsTheHeading() {
        for tail in [".", ":", ";", "!", "?"] {
            #expect(
                merged(boldPair(previous: "of wood pellets and cost" + tail)).count == 2, "\(tail)")
        }
        // A comma or a bracket is not terminal, so the wrap still merges.
        for tail in [",", ")"] {
            #expect(
                merged(boldPair(previous: "of wood pellets and cost" + tail)).count == 1, "\(tail)")
        }
    }

    @Test func bothLinesMustBeFullyBold() {
        #expect(merged(boldPair(previousBold: false)).count == 2)
        #expect(merged(boldPair(currentBold: false)).count == 2)
        // One plain run anywhere on the line disqualifies it.
        var mixed = line("of wood pellets", y: 700, bold: true)
        mixed.items.append(
            PdfLayoutItem(text: "and cost", x: 90, y: 700, width: 40, fontSize: 10, fontName: "F1"))
        #expect(merged([mixed, line("structure in Japan", y: 690, bold: true)]).count == 2)
    }

    @Test func aTieredHeadingDoesNotAbsorbBoldBodyText() {
        // The bold-wrap path needs *both* lines tier-less, so a real heading
        // followed by bold body text stays two lines — the levels differ, so
        // the ordinary path does not fire either.
        let mixed = merged([
            line("A Real Heading", y: 700, size: 14, bold: true),
            line("continues lowercase", y: 690, size: 10, bold: true),
        ])
        #expect(mixed.count == 2)
        // Set the second line at the heading's own size and it merges — but
        // by the ordinary same-level path, not this one.
        let sameSize = merged([
            line("A Real Heading", y: 700, size: 14, bold: true),
            line("continues lowercase", y: 690, size: 14, bold: true),
        ])
        #expect(sameSize.count == 1)
    }

    // MARK: - merge_drop_caps

    private func body() -> [PdfTextLine] {
        [
            line("Chapter One", y: 700),
            line("nce upon a time there", y: 690),
            line("was a document", y: 680),
        ]
    }

    private func dropped(_ lines: [PdfTextLine], base: Float = 10) -> [String] {
        pdfMergeDropCaps(lines, baseSize: base).map(pdfLineText)
    }

    @Test func aDropCapPrependsToTheParagraphItOpens() {
        let result = dropped(body() + [line("O", y: 690, size: 30, x: 10)])
        #expect(result == ["Chapter One", "Once upon a time there", "was a document"])
    }

    @Test func theDropCapSizeFloorIsTwoAndAHalfTimesBody() {
        #expect(dropped(body() + [line("O", y: 690, size: 25, x: 10)]).count == 3)
        // Below the floor it is an ordinary line and stays in the output.
        #expect(dropped(body() + [line("O", y: 690, size: 24, x: 10)]).count == 4)
    }

    @Test func theDropCapLengthLimitIsTwoBytes() {
        // `O`, `O ` and `Oh` all qualify; `Ohh` does not.
        for text in ["O", "O ", "Oh"] {
            #expect(dropped(body() + [line(text, y: 690, size: 30, x: 10)]).count == 3, "\(text)")
        }
        #expect(dropped(body() + [line("Ohh", y: 690, size: 30, x: 10)]).count == 4)
        // Bytes, not characters — a two-byte `É` is a single character and
        // still fits.
        #expect(dropped(body() + [line("É", y: 690, size: 30, x: 10)]).count == 3)
    }

    @Test func theCapMustBeUppercase() {
        for text in ["o", "1"] {
            #expect(dropped(body() + [line(text, y: 690, size: 30, x: 10)]).count == 4, "\(text)")
        }
    }

    @Test func aDropCapWithNoHomeIsSilentlyDiscarded() {
        // No lowercase-starting line to attach to — the cap line is dropped
        // anyway and the character is lost. Reproduced deliberately.
        let result = dropped([line("Chapter One", y: 700), line("O", y: 690, size: 30, x: 10)])
        #expect(result == ["Chapter One"])
        // The same happens when the only candidate is on another page.
        let across = dropped(body() + [line("O", y: 690, size: 30, page: 2, x: 10)])
        #expect(across == ["Chapter One", "nce upon a time there", "was a document"])
    }

    @Test func theFirstLineAlwaysCountsAsAParagraphStart() {
        let result = dropped([
            line("already lowercase here", y: 700), line("and continues lowercase", y: 690),
            line("O", y: 680, size: 30, x: 10),
        ])
        #expect(result.first == "Oalready lowercase here")
    }

    // MARK: - the comparison helpers

    @Test func comparisonStripsDigitsFromBothEnds() {
        #expect(pdfNormalizeForComparison("Chapter 3 — Page 5") == "Chapter 3 — Page")
        #expect(pdfNormalizeForComparison("  spaced   out  text ") == "spaced out text")
        #expect(pdfNormalizeForComparison("123 leading") == "leading")
        // Both ends, so a line of digits vanishes entirely.
        #expect(pdfNormalizeForComparison("42") == "")
        #expect(pdfNormalizeForComparison("1a2") == "a")
        // Only the ends: an interior number survives.
        #expect(pdfNormalizeForComparison("Page 5 of 10") == "Page 5 of")
    }

    @Test func structuralLinesNeedAMarkerOrANumberedPrefix() {
        for text in ["# Heading", "- bullet", "* star", "• dot", "1. numbered", "2) paren", "1. "] {
            #expect(pdfIsStructuralLine(text), "\(text)")
        }
        // A digit alone is not enough — the line needs `. ` or `) ` too — and
        // lettered lists are not covered here at all.
        for text in ["1.no space", "12 plain", "a. letter", "plain text", "", "3"] {
            #expect(!pdfIsStructuralLine(text), "\(text)")
        }
    }

    @Test func aDecorativeSeparatorIsAnyRepeatedCharacter() {
        #expect(pdfIsDecorativeSeparator("----------"))
        #expect(pdfIsDecorativeSeparator("**********"))
        // Vacuously true for one character, and — since the check is not
        // limited to punctuation — true for a run of letters as well.
        #expect(pdfIsDecorativeSeparator("="))
        #expect(pdfIsDecorativeSeparator("aaa"))
        #expect(!pdfIsDecorativeSeparator(""))
        #expect(!pdfIsDecorativeSeparator("-a-"))
        #expect(!pdfIsDecorativeSeparator("ab"))
    }
}
