import Testing

@testable import AnyDoc

/// The writer: analysed lines to finished Markdown.
@Suite struct PdfWriterTests {
    private func line(
        _ text: String, y: Float, page: Int = 1, size: Float = 10, x: Float = 20,
        bold: Bool = false, italic: Bool = false, font: String = "F1"
    ) -> PdfTextLine {
        var item = PdfLayoutItem(
            text: text, x: x, y: y, width: 40, fontSize: size, fontName: font)
        item.isBold = bold
        item.isItalic = italic
        return PdfTextLine(items: [item], y: y, page: page)
    }

    /// Convert, the way a caller would.
    private func markdown(
        _ lines: [PdfTextLine], options: PdfMarkdownOptions = PdfMarkdownOptions(),
        tables: [Int: [PdfPositionedMarkdown]] = [:],
        images: [Int: [PdfPositionedMarkdown]] = [:],
        bandSplitPages: Set<Int> = [], structRoles: PdfStructRoleMap? = nil
    ) -> String {
        pdfWriteMarkdown(
            pdfAnalyseDocument(lines, options: options, structRoles: structRoles),
            options: options, pageTables: tables, pageImages: images,
            bandSplitPages: bandSplitPages, structRoles: structRoles)
    }

    private func block(_ text: String, y: Float, x: Float = 20) -> PdfPositionedMarkdown {
        PdfPositionedMarkdown(y: y, x: x, markdown: text, chartOrder: nil)
    }

    @Test func anEmptyDocumentProducesAnEmptyString() {
        // Not even the newline a closing paragraph would leave.
        #expect(markdown([]) == "")
    }

    @Test func linesInOneParagraphAreJoinedWithSpaces() {
        let result = markdown([
            line("first line here", y: 700), line("second line here", y: 686),
        ])
        #expect(result == "first line here second line here\n")
    }

    @Test func aLargeGapEndsTheParagraph() {
        let result = markdown([
            line("first paragraph line here", y: 700),
            line("second paragraph line here", y: 600),
        ])
        // Both are promoted to headings by the rarity fallback once they
        // stand alone, which is the reference's behaviour on a two-line
        // document — the point here is the break between them.
        #expect(result.contains("\n\n"))
    }

    @Test func dotLeaderRowsAreKeptOnSeparateLines() {
        // A table of contents must not run together into one paragraph.
        let result = markdown([
            line("Chapter One .......... 5", y: 700),
            line("Chapter Two .......... 9", y: 686),
        ])
        #expect(result == "Chapter One .......... 5\nChapter Two .......... 9\n")
    }

    @Test func captionsStandAlone() {
        let result = markdown([
            line("Figure 1: a caption line", y: 700),
            line("body text following the caption", y: 686),
        ])
        #expect(result == "Figure 1: a caption line\n\nbody text following the caption\n")
    }

    @Test func listItemsAndTheirContinuations() {
        let result = markdown([
            line("1. numbered item here", y: 700), line("2. second numbered item", y: 686),
        ])
        #expect(result == "1. numbered item here\n2. second numbered item\n")
    }

    @Test func monospaceRunsBecomeFencedBlocks() {
        let result = markdown([
            line("let x = 1", y: 700, font: "Courier"),
            line("let y = 2", y: 686, font: "Courier"),
            line("ordinary prose after the code", y: 600),
        ])
        #expect(result.hasPrefix("```\nlet x = 1\nlet y = 2\n```\n"))
    }

    @Test func aCodeBlockIsClosedByAPageBreak() {
        let result = markdown([
            line("let x = 1", y: 700, font: "Courier"),
            line("ordinary prose on the next page", y: 700, page: 2),
        ])
        #expect(result.hasPrefix("```\nlet x = 1\n```\n"))
    }

    @Test func pageMarkersAreOptional() {
        var options = PdfMarkdownOptions()
        options.includePageNumbers = true
        let lines = [line("page one text here", y: 700), line("page two text here", y: 700, page: 2)]
        #expect(markdown(lines, options: options).hasPrefix("<!-- Page 1 -->\n\n"))
        #expect(!markdown(lines).contains("<!-- Page"))
    }

    // MARK: - struct roles

    private func tagged(_ role: PdfStructRole) -> String {
        var lines = [line("A Tagged Line Of Text", y: 760)]
        lines += (0..<3).map {
            line("body line \($0) of ordinary running prose here", y: 700 - Float($0) * 14)
        }
        var items = lines[0].items
        items[0].mcid = 0
        lines[0].items = items
        return markdown(lines, structRoles: [1: [0: role]])
    }

    @Test func taggedHeadingsCarryTheirLevel() {
        #expect(tagged(.h1).hasPrefix("# A Tagged Line Of Text\n\n"))
        #expect(tagged(.h2).hasPrefix("## A Tagged Line Of Text\n\n"))
    }

    @Test func taggedBlockRolesEachGetTheirSyntax() {
        #expect(tagged(.caption).hasPrefix("A Tagged Line Of Text\n\n"))
        #expect(tagged(.blockQuote).hasPrefix("> A Tagged Line Of Text\n"))
        #expect(tagged(.code).hasPrefix("```\nA Tagged Line Of Text\n```\n"))
    }

    @Test func aTaggedListItemAbsorbsTheLinesBelowIt() {
        // Once a list opens, following lines at a similar indent within seven
        // line heights are continuations — so an `LI` tag at the top of a
        // page pulls the body text into the bullet. The reference's
        // behaviour, and a good reason the continuation bound is worth
        // knowing about.
        #expect(tagged(.listItem).hasPrefix("- A Tagged Line Of Text body line 0"))
    }

    @Test func aTagThatNamesNoLevelLeavesTheHeuristicInCharge() {
        // `P` and `Figure` are not non-heading content, so a line tagged
        // either can still be promoted by the visual heuristic.
        #expect(tagged(.p).hasPrefix("## A Tagged Line Of Text"))
        #expect(tagged(.figure).hasPrefix("## A Tagged Line Of Text"))
    }

    // MARK: - blocks

    @Test func aTableIsEmittedWhereItSits() {
        let lines = (0..<4).map {
            line("body line \($0) of ordinary running prose here", y: 700 - Float($0) * 20)
        }
        let table = "| a | b |\n| --- | --- |"
        let result = markdown(lines, tables: [1: [block(table, y: 650)]])
        #expect(result.contains(table))
        // Between the lines above it and the lines below.
        let tableIndex = result.range(of: table)!.lowerBound
        #expect(result.range(of: "body line 0")!.lowerBound < tableIndex)
        #expect(result.range(of: "body line 3")!.lowerBound > tableIndex)
    }

    @Test func trailingBlocksAreFlushedAfterTheLastLine() {
        // A table on a page past the last text line has no line to trigger
        // it and would otherwise be dropped.
        let lines = [line("only text line here", y: 700)]
        let table = "| a | b |\n| --- | --- |"
        #expect(markdown(lines, tables: [3: [block(table, y: 650)]]).contains(table))
    }

    @Test func aBlockIsNeverEmittedTwice() {
        let lines = (0..<4).map {
            line("body line \($0) of ordinary running prose here", y: 700 - Float($0) * 20)
        }
        let table = "| a | b |\n| --- | --- |"
        let result = markdown(lines, tables: [1: [block(table, y: 650)]])
        #expect(result.components(separatedBy: "| --- | --- |").count == 2)
    }
}
