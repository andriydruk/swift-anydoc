import Testing

@testable import AnyDoc

/// The isolation cluster: struct-role resolution, the overuse audit, and the
/// lines that stand alone.
@Suite struct PdfIsolatedLinesTests {
    private func line(
        _ text: String, y: Float, page: Int = 1, size: Float = 10, mcids: [Int?] = [nil]
    ) -> PdfTextLine {
        var items: [PdfLayoutItem] = []
        for (index, mcid) in mcids.enumerated() {
            var item = PdfLayoutItem(
                text: index == 0 ? text : "more", x: Float(20 + index * 60), y: y, width: 40,
                fontSize: size, fontName: "F1")
            item.mcid = mcid
            items.append(item)
        }
        return PdfTextLine(items: items, y: y, page: page)
    }

    // MARK: - resolve_line_struct_role

    @Test func containerRolesAreSkippedRatherThanReturned() {
        let roles: PdfStructRoleMap = [1: [5: .div, 6: .h2]]
        let subject = line("one", y: 700, mcids: [5, 6])
        // The `Div` on the first run does not end the search, so the `H2` on
        // the second is what the line resolves to.
        #expect(pdfResolveLineStructRole(subject, roles) == .h2)
    }

    @Test func everyContainerLeavesTheLineUnresolved() {
        let roles: PdfStructRoleMap = [1: [5: .div, 6: .span]]
        #expect(pdfResolveLineStructRole(line("one", y: 700, mcids: [5, 6]), roles) == nil)
    }

    @Test func anUntaggedRunIsSkippedWithoutEndingTheSearch() {
        let roles: PdfStructRoleMap = [1: [6: .h3]]
        #expect(pdfResolveLineStructRole(line("one", y: 700, mcids: [nil, 6]), roles) == .h3)
    }

    @Test func rolesAreReadInItemOrderNotMcidOrder() {
        let roles: PdfStructRoleMap = [1: [5: .h1, 6: .h2]]
        // The line's runs carry mcid 6 first, so `H2` wins over `H1`.
        #expect(pdfResolveLineStructRole(line("one", y: 700, mcids: [6, 5]), roles) == .h2)
    }

    @Test func aRoleOnAnotherPageDoesNotApply() {
        let roles: PdfStructRoleMap = [2: [5: .h1]]
        #expect(pdfResolveLineStructRole(line("one", y: 700, mcids: [5]), roles) == nil)
        #expect(pdfResolveLineStructRole(line("one", y: 700, page: 2, mcids: [5]), roles) == .h1)
    }

    // MARK: - detect_overused_struct_heading_levels

    private func tagged(_ count: Int, _ roles: [(Int, PdfStructRole)]) -> (
        [PdfTextLine], PdfStructRoleMap
    ) {
        var map: PdfStructRoleMap = [:]
        var start = 0
        for (repeats, role) in roles {
            for offset in 0..<repeats { map[1, default: [:]][start + offset] = role }
            start += repeats
        }
        let lines = (0..<count).map {
            line("word", y: Float(700 - $0 * 30), mcids: [$0])
        }
        return (lines, map)
    }

    @Test func anAbsentRoleMapSuppressesNothing() {
        let (lines, _) = tagged(30, [(30, .h2)])
        // Not the same as an empty map: this returns before counting at all.
        #expect(pdfDetectOverusedStructHeadingLevels(lines, nil).isEmpty)
        #expect(pdfDetectOverusedStructHeadingLevels(lines, [:]).isEmpty)
    }

    @Test func fewerThanTwentyTaggedLinesAreLeftAlone() {
        for count in [19, 20] {
            let (lines, map) = tagged(count, [(count, .h2)])
            let found = pdfDetectOverusedStructHeadingLevels(lines, map)
            #expect(found == (count == 19 ? [] : [2]), "\(count) tagged lines")
        }
    }

    @Test func theOveruseBarIsFifteenPercentExclusive() {
        // Six headings in forty tagged lines is exactly 15% and survives;
        // seven is 17.5% and does not. The reference's own comment says 25%
        // — the code says 15%, and the code is what runs.
        for headings in [6, 7] {
            let (lines, map) = tagged(40, [(headings, .h2), (40 - headings, .p)])
            let found = pdfDetectOverusedStructHeadingLevels(lines, map)
            #expect(found == (headings == 6 ? [] : [2]), "\(headings) of 40")
        }
    }

    @Test func aGenericHeadingCountsTowardLevelOne() {
        // Four `H` and four `H1` are eight lines at level 1 — over the bar
        // that neither reaches alone.
        let (lines, map) = tagged(40, [(4, .h), (4, .h1), (32, .p)])
        #expect(pdfDetectOverusedStructHeadingLevels(lines, map) == [1])
    }

    @Test func untaggedLinesDoNotCountTowardTheTotal() {
        let (lines, map) = tagged(19, [(19, .h2)])
        let padded = lines + (0..<30).map { line("word", y: Float(100 - $0 * 10)) }
        // Thirty untagged lines do not lift nineteen tagged ones over the
        // floor, so nothing is suppressed.
        #expect(pdfDetectOverusedStructHeadingLevels(padded, map).isEmpty)
    }

    // MARK: - find_isolated_lines

    private func isolated(_ lines: [PdfTextLine], base: Float = 10, threshold: Float = 20)
        -> Set<Int>
    {
        pdfFindIsolatedLines(lines, baseSize: base, paraThreshold: threshold)
    }

    @Test func theLengthFloorIsBytesNotCharacters() {
        // `éé` is two characters but four bytes and clears the bar; `a b` is
        // three of each and does not. A port measuring `String.count` would
        // disagree on the first.
        #expect(isolated([line("éé", y: 700)]) == [0])
        #expect(isolated([line("a b", y: 700)]) == [])
        #expect(isolated([line("abc", y: 700)]) == [])
        #expect(isolated([line("abcd", y: 700)]) == [0])
    }

    @Test func theWordCountWindowIsOneToSix() {
        #expect(isolated([line("one two three four five six", y: 700)]) == [0])
        #expect(isolated([line("one two three four five six seven", y: 700)]) == [])
    }

    @Test func theSizeFloorIsNinetyFivePercentOfBody() {
        #expect(isolated([line("Acknowledgements", y: 700, size: 9.5)]) == [0])
        #expect(isolated([line("Acknowledgements", y: 700, size: 9.4)]) == [])
    }

    @Test func onlyThreeTrailingCharactersMarkWrappedProse() {
        // A hyphen, a comma or a semicolon ends a line mid-flight. A full
        // stop, a colon and a question mark do not — a heading may carry any
        // of those.
        for tail in ["-", ",", ";"] {
            #expect(isolated([line("Some heading" + tail, y: 700)]) == [], "\(tail)")
        }
        for tail in [".", ":", "?", ")", ""] {
            #expect(isolated([line("Some heading" + tail, y: 700)]) == [0], "\(tail)")
        }
    }

    @Test func continuationWordsAreComparedCaseInsensitively() {
        for last in ["the", "The", "THE", "not", "and", "is", "their"] {
            #expect(isolated([line("A short " + last, y: 700)]) == [], "\(last)")
        }
        // Only whole words — `thes` is not `the`.
        for last in ["heading", "thes"] {
            #expect(isolated([line("A short " + last, y: 700)]) == [0], "\(last)")
        }
    }

    @Test func theParagraphGapIsStrictlyGreater() {
        for gap in [Float(20), 21] {
            let lines = [
                line("First line here", y: 700),
                line("Middle Heading", y: 700 - gap),
                line("Third line here", y: 700 - gap * 2),
            ]
            #expect(isolated(lines) == (gap == 20 ? [] : [0, 1, 2]), "gap \(gap)")
        }
    }

    @Test func aPageChangeBreaksInBothDirections() {
        let lines = [
            line("First line here", y: 700),
            line("Middle Heading", y: 695, page: 2),
            line("Third line here", y: 690, page: 3),
        ]
        // Five points apart, but on different pages — every line is isolated.
        #expect(isolated(lines) == [0, 1, 2])
    }

    @Test func theGapIsAbsoluteSoAnUpwardStepBreaksToo() {
        let lines = [
            line("First line here", y: 700),
            line("Middle Heading", y: 760),
            line("Third line here", y: 600),
        ]
        #expect(isolated(lines) == [0, 1, 2])
    }

    // MARK: - the density guard

    private func scattered(_ count: Int, page: Int = 1, start: Float = 1000) -> [PdfTextLine] {
        (0..<count).map {
            line("Heading Number \($0)", y: start - Float($0) * 100, page: page)
        }
    }

    private func block(_ count: Int, page: Int = 1, start: Float = 200) -> [PdfTextLine] {
        (0..<count).map {
            line("block line \($0) of prose", y: start - Float($0) * 5, page: page)
        }
    }

    @Test func sparsePagesAreExemptFromTheDensityGuard() {
        // Nine isolated lines on a nine-line page are all kept; a tenth
        // brings the page over the floor and loses every one of them.
        #expect(isolated(scattered(9)).count == 9)
        #expect(isolated(scattered(10)).isEmpty)
    }

    @Test func aQuarterOfThePageIsAllowed() {
        #expect(isolated(scattered(3) + block(9)) == [0, 1, 2])
        #expect(isolated(scattered(4) + block(8)).isEmpty)
    }

    @Test func theGuardAppliesPerPageNotPerDocument() {
        let lines =
            scattered(11, page: 1) + scattered(2, page: 2, start: 900)
            + block(9, page: 2, start: 300)
        // Page one is over the bar and loses everything; page two keeps both
        // of its isolated lines.
        #expect(isolated(lines) == [11, 12])
    }

    @Test func anAppendixHeadingIsRejectedByTheListItemGate() {
        // `B.3 Prompt Engineering` is the reference's *own* documented
        // example of a line this function exists to find — and its
        // `is_list_item` gate reads the leading `B.` as a lettered list
        // marker and throws it out. Reproduced deliberately.
        #expect(pdfIsListItem("B.3 Prompt Engineering"))
        #expect(isolated([line("B.3 Prompt Engineering", y: 700)]).isEmpty)
        #expect(isolated([line("Acknowledgements", y: 700)]) == [0])
    }
}
