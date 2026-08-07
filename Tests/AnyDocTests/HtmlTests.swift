// Ported from src/shared/html.rs tests.
import Testing
@testable import AnyDoc

private struct NullCtx: HtmlCtx {
    func linkTarget(_ href: String) -> LinkTarget? {
        href.isEmpty ? nil : .external(href)
    }

    func imageSource(_ src: String) throws -> ImageSource? {
        nil
    }

    func anchorId(_ raw: String) -> AnchorId {
        raw
    }
}

private func blocksWithCss(_ html: String, _ cssText: String) throws -> [Block] {
    let tree = try parseXml(Array(html.utf8))
    let body = try #require(tree.childElements.first)
    var sheet = Stylesheet()
    sheet.add(cssText)
    return try htmlToBlocks(body, css: sheet, ctx: NullCtx())
}

private func blocks(_ html: String) throws -> [Block] {
    try blocksWithCss(html, "")
}

private func paraText(_ block: Block) throws -> String {
    guard case .paragraph(let inlines) = block else {
        Issue.record("expected paragraph: \(block)")
        return ""
    }
    return inlinesToPlainText(inlines)
}

private func firstTextStyle(_ inlines: [Inline]) -> Style? {
    for inline in inlines {
        switch inline {
        case .text(_, let style): return style
        case .link(let content, _): return firstTextStyle(content)
        default: break
        }
    }
    return nil
}

@Suite struct HtmlTests {
    @Test func whitespaceCollapsesAcrossInlineBoundaries() throws {
        // M7: a lone space inside a span must survive between words, and
        // formatting splits must not double or drop spaces.
        var out = try blocks("<body><p>foo<span> </span>bar</p></body>")
        #expect(try paraText(out[0]) == "foo bar")
        out = try blocks("<body><p>foo <span> bar</span></p></body>")
        #expect(try paraText(out[0]) == "foo bar")
        out = try blocks("<body><p>  foo\n  bar  </p></body>")
        #expect(try paraText(out[0]) == "foo bar ")
    }

    @Test func linkLabelWhitespaceJoinsTheSurroundingRun() throws {
        // `foo <a> bar</a>`: the label's leading space collapses with the
        // space already emitted before the link.
        var out = try blocks(#"<body><p>foo <a href="u"> bar</a></p></body>"#)
        guard case .paragraph(let inlines) = out[0] else {
            Issue.record("expected paragraph: \(out[0])")
            return
        }
        let link = inlines.first { inline in
            if case .link = inline { return true }
            return false
        }
        guard case .link(let content, _) = try #require(link, "no link in \(inlines)") else {
            Issue.record("no link in \(inlines)")
            return
        }
        #expect(inlinesToPlainText(content) == "bar")
        // `foo<a> bar</a>`: no space yet, so the label keeps its lead.
        out = try blocks(#"<body><p>foo<a href="u"> bar</a></p></body>"#)
        #expect(try paraText(out[0]) == "foo bar")
    }

    @Test func inlineStyleOverridesTheTagDefault() throws {
        // M7: `<b style="font-weight: normal">` renders plain.
        let out = try blocks(#"<body><p><b style="font-weight: normal">x</b></p></body>"#)
        guard case .paragraph(let inlines) = out[0] else {
            Issue.record("expected paragraph: \(out[0])")
            return
        }
        let style = try #require(firstTextStyle(inlines))
        #expect(!style.bold)
    }

    @Test func importantDeclarationsWinTheCascade() throws {
        let css = "span.x { font-weight: bold !important } span.x { font-weight: normal }"
        let out = try blocksWithCss(#"<body><p><span class="x">x</span></p></body>"#, css)
        guard case .paragraph(let inlines) = out[0] else {
            Issue.record("expected paragraph: \(out[0])")
            return
        }
        let style = try #require(firstTextStyle(inlines))
        #expect(style.bold)
    }

    @Test func headingStylingStaysOutOfItsContent() throws {
        // A heading's own CSS is how the heading looks, so it does not reach
        // the runs; emphasis a child adds beyond it still does.
        let css = "h2 { font-style: italic; font-weight: bold }"
        var out = try blocksWithCss("<body><h2>title <b>b</b></h2></body>", css)
        guard case .heading(_, _, let styledContent) = out[0] else {
            Issue.record("expected heading: \(out)")
            return
        }
        #expect(try #require(firstTextStyle(styledContent)) == .plain)

        out = try blocksWithCss("<body><h2>title <b>b</b></h2></body>", "")
        guard case .heading(_, _, let content) = out[0] else {
            Issue.record("expected heading: \(out)")
            return
        }
        #expect(try #require(firstTextStyle(content)) == .plain)
        let lastText = content.last { inline in
            if case .text = inline { return true }
            return false
        }
        guard case .text(_, let style) = try #require(lastText) else {
            Issue.record("no text run in \(content)")
            return
        }
        #expect(style.bold)
    }

    @Test func extremeOrderedListValuesDoNotOverflow() throws {
        // H2: source-controlled `start`/`value` sit anywhere in i64.
        let html = """
            <body><ol start="\(Int64.max)"><li>a</li><li>b</li>\
            <li value="\(Int64.min)">c</li><li>d</li></ol></body>
            """
        let out = try blocks(html)
        #expect(!out.isEmpty)
    }

    @Test func rowspanZeroSpansToTheEndOfTheRowGroup() throws {
        // M8: rowspan="0" covers the remaining rows of its row group only.
        let html = #"""
            <body><table>
                <tbody>
                    <tr><td rowspan="0">tall</td><td>a</td></tr>
                    <tr><td>b</td></tr>
                </tbody>
                <tbody><tr><td>c</td><td>d</td></tr></tbody>
            </table></body>
            """#
        let out = try blocks(html)
        guard case .table(let t) = out[0] else {
            Issue.record("expected table: \(out)")
            return
        }
        guard case .origin(let tall) = t.grid[0][0] else {
            Issue.record("expected origin at (0,0): \(t.grid)")
            return
        }
        #expect(tall.rowSpan == 2)
        guard case .covered(let originRow, let originCol) = t.grid[1][0] else {
            Issue.record("expected covered at (1,0): \(t.grid)")
            return
        }
        #expect(originRow == 0 && originCol == 0)
        #expect(t.grid[2][0].isOrigin, "next group must not be covered")
    }
}
