import Testing

@testable import AnyDoc

/// The plain line entry point, and where it disagrees with the full writer.
///
/// The two are separate implementations in the reference, not one with
/// arguments defaulted. Most of these tests assert a *difference*, because
/// that is the thing a future refactor would be tempted to collapse.
@Suite struct PdfWriterSimpleTests {
    private func line(
        _ text: String, y: Float, page: Int = 1, size: Float = 10, x: Float = 20,
        bold: Bool = false, font: String = "F1", mcid: Int? = nil
    ) -> PdfTextLine {
        var item = PdfLayoutItem(
            text: text, x: x, y: y, width: 40, fontSize: size, fontName: font)
        item.isBold = bold
        item.mcid = mcid
        return PdfTextLine(items: [item], y: y, page: page)
    }

    private func body(_ count: Int = 6) -> [PdfTextLine] {
        (0..<count).map {
            line("body line \($0) of ordinary running prose here", y: 700 - Float($0) * 14)
        }
    }

    /// The plain entry point.
    private func plain(_ lines: [PdfTextLine], options: PdfMarkdownOptions = PdfMarkdownOptions())
        -> String
    {
        pdfMarkdownFromLines(lines, options: options)
    }

    /// The full writer, for comparison.
    private func full(
        _ lines: [PdfTextLine], options: PdfMarkdownOptions = PdfMarkdownOptions(),
        structRoles: PdfStructRoleMap? = nil, bandSplitPages: Set<Int> = []
    ) -> String {
        pdfWriteMarkdown(
            pdfAnalyseDocument(lines, options: options, structRoles: structRoles),
            options: options, bandSplitPages: bandSplitPages, structRoles: structRoles)
    }

    @Test func anEmptyDocumentProducesAnEmptyString() {
        #expect(plain([]) == "")
    }

    @Test func ordinaryProseConvertsTheSameWayInBothWriters() {
        let lines = [line("first line here", y: 700), line("second line here", y: 686)]
        #expect(plain(lines) == "first line here second line here\n")
        #expect(plain(lines) == full(lines))
    }

    @Test func codeIsFencedPerLineRatherThanAccumulated() {
        // The clearest divergence: two consecutive monospace lines are one
        // block in the full writer and two here.
        let lines = [
            line("let x = 1", y: 700, font: "Courier"),
            line("let y = 2", y: 686, font: "Courier"),
        ]
        #expect(plain(lines) == "```\nlet x = 1\n```\n```\nlet y = 2\n```\n")
        #expect(full(lines) == "```\nlet x = 1\nlet y = 2\n```\n")
    }

    @Test func aBulletMarkerCanBecomeAHeadingHere() {
        // The full writer's heading gate rejects anything starting with a
        // bullet marker, so the line falls through to the list branch. This
        // writer has no such test and promotes it.
        let lines = [line("- A Bulleted Heading Line", y: 760, size: 20)] + body()
        #expect(plain(lines).hasPrefix("# - A Bulleted Heading Line\n\n"))
        #expect(full(lines).hasPrefix("- A Bulleted Heading Line"))
    }

    @Test func structureTagsAreIgnoredEntirely() {
        var tagged = line("A Tagged Line Of Text", y: 760, mcid: 0)
        tagged.items[0].mcid = 0
        let lines = [tagged] + body()
        let roles: PdfStructRoleMap = [1: [0: .blockQuote]]
        // The full writer honours the tag; this entry point has nowhere to
        // put one and falls back to the visual heuristic.
        #expect(full(lines, structRoles: roles).hasPrefix("> A Tagged Line Of Text"))
        #expect(plain(lines).hasPrefix("## A Tagged Line Of Text"))
    }

    @Test func thereIsNoBandSwitchBreak() {
        // Two lines at one baseline far apart horizontally: the full writer
        // splits them on a band-split page, this one joins them.
        let lines = [
            line("left band line here", y: 700, x: 20),
            line("right band line here", y: 700, x: 300),
        ]
        #expect(plain(lines) == "left band line here right band line here\n")
        #expect(full(lines, bandSplitPages: [1]) == "left band line here\n\nright band line here\n")
    }

    @Test func captionsAndListsBehaveAsInTheFullWriter() {
        // Not everything diverges — the text-driven branches agree.
        let caption = [
            line("Figure 1: a caption line", y: 700),
            line("body text following the caption", y: 686),
        ]
        #expect(plain(caption) == "Figure 1: a caption line\n\nbody text following the caption\n")
        #expect(plain(caption) == full(caption))

        let list = [
            line("1. numbered item here", y: 700), line("2. second numbered item", y: 686),
        ]
        #expect(plain(list) == "1. numbered item here\n2. second numbered item\n")
        #expect(plain(list) == full(list))
    }

    @Test func dotLeaderRowsStayOnSeparateLines() {
        let lines = [
            line("Chapter One .......... 5", y: 700),
            line("Chapter Two .......... 9", y: 686),
        ]
        #expect(plain(lines) == "Chapter One .......... 5\nChapter Two .......... 9\n")
    }

    @Test func pageMarkersAreOptionalHereToo() {
        var options = PdfMarkdownOptions()
        options.includePageNumbers = true
        let lines = [line("page one text here", y: 700), line("page two text here", y: 700, page: 2)]
        #expect(plain(lines, options: options).hasPrefix("<!-- Page 1 -->\n\n"))
        #expect(!plain(lines).contains("<!-- Page"))
    }

    @Test func aListDoesNotSurviveAPageBreakInEitherWriter() {
        // This writer clears the list state on a page break and the full one
        // does not — but the outcome is the same, because a page break resets
        // the baseline and the continuation test fails on the gap regardless.
        // Recorded so the difference is not mistaken for a live one.
        let lines = [
            line("- a bullet item here", y: 700),
            line("continuation on the next page", y: 700, page: 2, x: 24),
        ]
        #expect(plain(lines) == full(lines))
        #expect(plain(lines).hasPrefix("- a bullet item here\n\n"))
    }
}
